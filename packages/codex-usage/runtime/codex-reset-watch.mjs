#!/usr/bin/env node

import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { spawn } from "node:child_process";

const CODEX_HOME = process.env.CODEX_HOME || path.join(os.homedir(), ".codex");
const CONFIG_PATH = process.env.CODEX_RESET_WATCH_CONFIG || path.join(CODEX_HOME, "codex-reset-watch.config.json");
const STATE_PATH = process.env.CODEX_RESET_WATCH_STATE || path.join(CODEX_HOME, "codex-reset-watch-state.json");
const LOG_PATH = process.env.CODEX_RESET_WATCH_LOG || path.join(CODEX_HOME, "codex-reset-watch.log");

const DEFAULTS = {
  authPath: path.join(CODEX_HOME, "auth.json"),
  checkIntervalMs: 15 * 60 * 1000,
  codexCliPath: path.join(CODEX_HOME, ".sandbox-bin", "codex.exe"),
  prompt: "hi",
  resetDelayMs: 3 * 60 * 1000,
  resetWindow: "primary",
  sendLookbackMs: 20 * 60 * 1000,
  missedCatchUpMaxAgeMs: 24 * 60 * 60 * 1000,
  sessionIndexPath: path.join(CODEX_HOME, "session_index.jsonl"),
  threadSelection: "latest",
  threadId: null,
  usageUrl: "https://chatgpt.com/backend-api/wham/usage",
  webhookUrl: "",
  notifyOnReset: true,
  hookConfigPath: path.join(CODEX_HOME, "hooks", "hook-config.json"),
};

let pendingTimer = null;

function loadJson(file, fallback = {}) {
  try {
    if (!fs.existsSync(file)) return fallback;
    return JSON.parse(fs.readFileSync(file, "utf8"));
  } catch {
    return fallback;
  }
}

function saveJson(file, value) {
  fs.mkdirSync(path.dirname(file), { recursive: true });
  fs.writeFileSync(file, `${JSON.stringify(value, null, 2)}\n`);
}

function log(message, extra = undefined) {
  const line = `[${new Date().toISOString()}] ${message}${extra === undefined ? "" : ` ${JSON.stringify(extra)}`}`;
  console.log(line);
  fs.appendFileSync(LOG_PATH, `${line}\n`);
}

function loadConfig() {
  const config = { ...DEFAULTS, ...loadJson(CONFIG_PATH) };
  config.threadId = process.env.CODEX_RESET_THREAD_ID || config.threadId;
  config.webhookUrl = resolveWebhookUrl(config);
  return config;
}

function resolveWebhookUrl(config) {
  const explicit = process.env.CODEX_RESET_WATCH_WEBHOOK_URL || config.webhookUrl;
  if (explicit) return String(explicit).trim();

  const hookConfig = loadJson(config.hookConfigPath, {});
  const fromHooks = hookConfig?.webhook_url;
  return fromHooks ? String(fromHooks).trim() : "";
}

function detectResetOccurred(state, win, now) {
  const prevReset = state.scheduledResetAtSeconds;
  if (prevReset == null) return null;
  if (win.reset_at === prevReset) return null;

  const prevResetMs = Number(prevReset) * 1000;
  if (!Number.isFinite(prevResetMs) || now < prevResetMs) return null;
  if (state.lastNotifiedResetAt === prevReset) return null;

  return {
    completedResetAtSeconds: prevReset,
    nextResetAtSeconds: win.reset_at,
  };
}

async function sendResetWebhook(config, target, win, resetEvent) {
  const webhookUrl = resolveWebhookUrl(config);
  if (!webhookUrl || config.notifyOnReset === false) return;

  const nextResetMs = Number(win.reset_at) * 1000;
  const body = {
    source: "codex",
    direction: "token_reset",
    event: "rate_limit_reset",
    session_id: target.threadId,
    thread_id: target.threadId,
    reset_window: config.resetWindow,
    text: `Codex rate limit reset. Usage now ${win.used_percent ?? "?"}%. Next reset at ${new Date(nextResetMs).toISOString()}.`,
    completed_reset_at: new Date(Number(resetEvent.completedResetAtSeconds) * 1000).toISOString(),
    completed_reset_at_seconds: resetEvent.completedResetAtSeconds,
    next_reset_at: new Date(nextResetMs).toISOString(),
    next_reset_at_seconds: win.reset_at,
    used_percent: win.used_percent,
    window: describeWindow(win),
    timestamp: new Date().toISOString(),
  };

  const res = await fetch(webhookUrl, {
    method: "POST",
    headers: { "Content-Type": "application/json; charset=utf-8" },
    body: JSON.stringify(body),
    signal: AbortSignal.timeout(12000),
  });

  if (!res.ok) {
    const detail = (await res.text()).slice(0, 500);
    throw new Error(`Webhook failed: HTTP ${res.status} ${detail}`);
  }

  log("reset webhook sent", {
    completedResetAtSeconds: resetEvent.completedResetAtSeconds,
    nextResetAtSeconds: resetEvent.nextResetAtSeconds,
  });

  const state = loadJson(STATE_PATH, {});
  saveJson(STATE_PATH, {
    ...state,
    lastNotifiedResetAt: resetEvent.completedResetAtSeconds,
    lastNotifiedAt: new Date().toISOString(),
  });
}

async function maybeNotifyReset(config, state, win, target, now) {
  const resetEvent = detectResetOccurred(state, win, now);
  if (!resetEvent) return;

  try {
    await sendResetWebhook(config, target, win, resetEvent);
  } catch (error) {
    log("reset webhook failed", {
      message: error instanceof Error ? error.message : String(error),
      completedResetAtSeconds: resetEvent.completedResetAtSeconds,
    });
  }
}

function readSessionIndex(sessionIndexPath) {
  if (!fs.existsSync(sessionIndexPath)) return [];
  return fs
    .readFileSync(sessionIndexPath, "utf8")
    .split(/\r?\n/)
    .map((line) => line.trim())
    .filter(Boolean)
    .map((line) => {
      try {
        return JSON.parse(line);
      } catch {
        return null;
      }
    })
    .filter((item) => item?.id);
}

function resolveThreadId(config) {
  if (config.threadId) return { threadId: config.threadId, source: "config" };

  const sessions = readSessionIndex(config.sessionIndexPath);
  if (sessions.length === 0) {
    throw new Error(`No sessions found in ${config.sessionIndexPath}`);
  }

  if (config.threadSelection === "first") {
    return { threadId: sessions[0].id, source: "session_index:first" };
  }

  const withTime = sessions
    .map((session, index) => ({
      index,
      session,
      updatedAtMs: Date.parse(session.updated_at || ""),
    }))
    .filter((item) => Number.isFinite(item.updatedAtMs));

  if (withTime.length > 0) {
    withTime.sort((a, b) => b.updatedAtMs - a.updatedAtMs || b.index - a.index);
    return { threadId: withTime[0].session.id, source: "session_index:latest" };
  }

  return { threadId: sessions[0].id, source: "session_index:first-fallback" };
}

function readAuth(authPath) {
  const auth = JSON.parse(fs.readFileSync(authPath, "utf8"));
  const accessToken = auth?.tokens?.access_token;
  const accountId = process.env.CHATGPT_ACCOUNT_ID || auth?.tokens?.account_id;
  if (!accessToken) throw new Error(`No tokens.access_token found in ${authPath}`);
  return { accessToken, accountId };
}

async function fetchUsage(config) {
  const { accessToken, accountId } = readAuth(config.authPath);
  const headers = {
    Accept: "application/json",
    Authorization: `Bearer ${accessToken}`,
  };
  if (accountId) headers["ChatGPT-Account-Id"] = accountId;

  const res = await fetch(config.usageUrl, { headers });
  const text = await res.text();
  let data = null;
  try {
    data = text ? JSON.parse(text) : null;
  } catch {
    // Keep the raw text for the error below.
  }
  if (!res.ok) {
    const body = data ? JSON.stringify(data) : text.slice(0, 500);
    throw new Error(`Usage request failed: HTTP ${res.status} ${res.statusText} ${body}`);
  }
  return data;
}

function pickWindow(usage, resetWindow) {
  const rateLimit = usage?.rate_limit;
  if (!rateLimit) return null;
  if (resetWindow === "secondary") return rateLimit.secondary_window || null;
  if (resetWindow === "most_used") {
    const windows = [rateLimit.primary_window, rateLimit.secondary_window].filter(Boolean);
    return windows.reduce((best, item) => {
      if (!best) return item;
      return (item.used_percent ?? 0) > (best.used_percent ?? 0) ? item : best;
    }, null);
  }
  return rateLimit.primary_window || null;
}

function describeWindow(win) {
  return {
    limitWindowSeconds: win?.limit_window_seconds,
    resetAfterSeconds: win?.reset_after_seconds,
    resetAt: win?.reset_at,
    usedPercent: win?.used_percent,
  };
}

async function sendPrompt(config, resetAtSeconds, reason) {
  const target = resolveThreadId(config);
  if (!fs.existsSync(config.codexCliPath)) throw new Error(`Codex CLI not found: ${config.codexCliPath}`);

  const args = [
    "exec",
    "resume",
    "--skip-git-repo-check",
    "--dangerously-bypass-hook-trust",
    target.threadId,
    config.prompt,
  ];

  log("sending prompt", {
    prompt: config.prompt,
    resetAtSeconds,
    reason,
    threadId: target.threadId,
    threadSource: target.source,
  });

  await new Promise((resolve, reject) => {
    const child = spawn(config.codexCliPath, args, {
      cwd: CODEX_HOME,
      env: { ...process.env, CODEX_HOME },
      stdio: ["ignore", "pipe", "pipe"],
      windowsHide: true,
    });

    let stdout = "";
    let stderr = "";
    child.stdout.on("data", (chunk) => {
      stdout += chunk.toString();
    });
    child.stderr.on("data", (chunk) => {
      stderr += chunk.toString();
    });
    child.on("error", reject);
    child.on("close", (code) => {
      log("send process finished", {
        code,
        stderrTail: stderr.slice(-1000),
        stdoutTail: stdout.slice(-1000),
      });
      if (code === 0) resolve();
      else reject(new Error(`codex exec resume exited with code ${code}`));
    });
  });
}

function clearPendingTimer() {
  if (pendingTimer) {
    clearTimeout(pendingTimer);
    pendingTimer = null;
  }
}

function getScheduledSendAtMs(state, config) {
  const parsed = Date.parse(state.scheduledSendAt || "");
  if (Number.isFinite(parsed)) return parsed;

  const resetAtSeconds = Number(state.scheduledResetAtSeconds);
  if (!Number.isFinite(resetAtSeconds)) return null;
  return resetAtSeconds * 1000 + Number(config.resetDelayMs);
}

function findMissedSend(config, state, currentResetAtSeconds, now) {
  const scheduledReset = state.scheduledResetAtSeconds;
  if (scheduledReset == null) return null;
  if (state.lastSentResetAt === scheduledReset) return null;

  const sendAtMs = getScheduledSendAtMs(state, config);
  if (sendAtMs == null || !Number.isFinite(sendAtMs) || now < sendAtMs) return null;

  const missedByMs = now - sendAtMs;
  const lookbackMs = Number(config.sendLookbackMs);
  const windowAdvanced = Number(currentResetAtSeconds) > Number(scheduledReset);
  const maxAgeMs = Number(config.missedCatchUpMaxAgeMs);

  if (missedByMs <= lookbackMs) {
    return { resetAtSeconds: scheduledReset, reason: "missed-within-lookback" };
  }
  if (windowAdvanced) {
    return { resetAtSeconds: scheduledReset, reason: "missed-after-offline" };
  }
  if (Number.isFinite(maxAgeMs) && maxAgeMs > 0 && missedByMs <= maxAgeMs) {
    return { resetAtSeconds: scheduledReset, reason: "missed-within-max-age" };
  }

  return {
    tooOld: true,
    missedByMinutes: Math.round(missedByMs / 60000),
    scheduledResetAt: state.scheduledResetAt,
    scheduledSendAt: state.scheduledSendAt,
  };
}

async function maybeSend(config, resetAtSeconds, reason) {
  const state = loadJson(STATE_PATH, {});
  if (state.lastSentResetAt === resetAtSeconds) {
    log("skip duplicate send", { resetAtSeconds, reason });
    return;
  }
  await sendPrompt(config, resetAtSeconds, reason);
  saveJson(STATE_PATH, {
    ...state,
    lastSentAt: new Date().toISOString(),
    lastSentResetAt: resetAtSeconds,
    lastSendReason: reason,
  });
}

async function checkAndSchedule({ armTimer = true } = {}) {
  const config = loadConfig();
  const usage = await fetchUsage(config);
  const target = resolveThreadId(config);
  const win = pickWindow(usage, config.resetWindow);
  if (!win?.reset_at) throw new Error(`No reset_at found for resetWindow=${config.resetWindow}`);

  const now = Date.now();
  const resetAtMs = Number(win.reset_at) * 1000;
  const sendAtMs = resetAtMs + Number(config.resetDelayMs);
  if (!Number.isFinite(sendAtMs)) throw new Error(`Invalid reset_at: ${win.reset_at}`);

  const state = loadJson(STATE_PATH, {});
  await maybeNotifyReset(config, state, win, target, now);

  const missed = findMissedSend(config, state, win.reset_at, now);
  if (missed?.resetAtSeconds != null) {
    log("detected missed send", {
      reason: missed.reason,
      resetAtSeconds: missed.resetAtSeconds,
      scheduledSendAt: state.scheduledSendAt,
    });
    await maybeSend(config, missed.resetAtSeconds, missed.reason);
  } else if (missed?.tooOld) {
    log("missed send too old to catch up", missed);
  }

  const nextState = {
    ...loadJson(STATE_PATH, {}),
    lastCheckAt: new Date().toISOString(),
    lastObservedWindow: describeWindow(win),
    scheduledResetAt: new Date(resetAtMs).toISOString(),
    scheduledResetAtSeconds: win.reset_at,
    scheduledSendAt: new Date(sendAtMs).toISOString(),
    threadId: target.threadId,
    threadSource: target.source,
  };
  saveJson(STATE_PATH, nextState);

  clearPendingTimer();

  if (sendAtMs <= now) {
    if (now - sendAtMs <= Number(config.sendLookbackMs)) {
      await maybeSend(config, win.reset_at, "reset-window-just-passed");
    } else {
      log("send time already passed outside lookback", {
        resetAt: nextState.scheduledResetAt,
        sendAt: nextState.scheduledSendAt,
      });
    }
    return;
  }

  const delayMs = sendAtMs - now;
  if (armTimer) {
    pendingTimer = setTimeout(() => {
      maybeSend(loadConfig(), win.reset_at, "scheduled-reset-plus-delay").catch((error) => {
        log("scheduled send failed", { message: error.message });
      });
    }, delayMs);
  }

  log("scheduled prompt", {
    resetAt: nextState.scheduledResetAt,
    sendAt: nextState.scheduledSendAt,
    delayMinutes: Math.round(delayMs / 60000),
    window: describeWindow(win),
  });
}

async function runOnce({ armTimer = true } = {}) {
  try {
    await checkAndSchedule({ armTimer });
  } catch (error) {
    log("check failed", { message: error instanceof Error ? error.message : String(error) });
    process.exitCode = 1;
  }
}

async function runDaemon() {
  const config = loadConfig();
  log("watcher started", {
    checkIntervalMs: config.checkIntervalMs,
    resetDelayMs: config.resetDelayMs,
    resetWindow: config.resetWindow,
    threadSelection: config.threadSelection,
  });

  await runOnce();
  setInterval(runOnce, Number(config.checkIntervalMs));
}

if (process.argv.includes("--once")) {
  await runOnce({ armTimer: false });
} else {
  await runDaemon();
}
