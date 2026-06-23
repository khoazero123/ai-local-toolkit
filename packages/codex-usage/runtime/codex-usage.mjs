#!/usr/bin/env node

import fs from "node:fs";
import os from "node:os";
import path from "node:path";

const DEFAULT_AUTH_PATH = path.join(os.homedir(), ".codex", "auth.json");
const DEFAULT_URL = "https://chatgpt.com/backend-api/wham/usage";

function usage() {
  console.log(`Usage:
  node codex-usage.mjs [--raw] [--url <url>] [--auth <auth.json>]

Examples:
  node codex-usage.mjs
  node codex-usage.mjs --raw
  node codex-usage.mjs --url https://chatgpt.com/backend-api/wham/usage

Environment overrides:
  CODEX_AUTH_JSON       Path to Codex auth.json
  CODEX_USAGE_URL       Full usage endpoint URL
  CHATGPT_ACCOUNT_ID    Account/workspace id header override
`);
}

function parseArgs(argv) {
  const args = {
    authPath: process.env.CODEX_AUTH_JSON || DEFAULT_AUTH_PATH,
    raw: false,
    url: process.env.CODEX_USAGE_URL || DEFAULT_URL,
  };

  for (let i = 2; i < argv.length; i += 1) {
    const arg = argv[i];
    if (arg === "--help" || arg === "-h") {
      usage();
      process.exit(0);
    }
    if (arg === "--raw") {
      args.raw = true;
      continue;
    }
    if (arg === "--auth") {
      args.authPath = argv[++i];
      continue;
    }
    if (arg === "--url") {
      args.url = argv[++i];
      continue;
    }
    throw new Error(`Unknown argument: ${arg}`);
  }

  return args;
}

function readAuth(authPath) {
  if (!fs.existsSync(authPath)) {
    throw new Error(`Codex auth file not found: ${authPath}`);
  }

  const auth = JSON.parse(fs.readFileSync(authPath, "utf8"));
  const accessToken = auth?.tokens?.access_token;
  const accountId = process.env.CHATGPT_ACCOUNT_ID || auth?.tokens?.account_id;

  if (!accessToken) {
    throw new Error(`No tokens.access_token found in ${authPath}`);
  }

  return { accessToken, accountId };
}

function pct(value) {
  if (!Number.isFinite(value)) return "-";
  return `${Math.round(value)}%`;
}

function formatReset(value) {
  if (value == null) return "-";
  const ms = Number(value) * 1000;
  if (!Number.isFinite(ms)) return "-";
  return new Date(ms).toLocaleString();
}

function summarizeWindow(label, win) {
  if (!win) return null;
  const used = win.used_percent ?? null;
  const remaining = Number.isFinite(used) ? Math.max(0, 100 - used) : null;
  const seconds = win.limit_window_seconds ?? win.reset_after_seconds ?? null;
  const hours = Number.isFinite(seconds) ? seconds / 3600 : null;
  const windowLabel = Number.isFinite(hours)
    ? hours >= 24
      ? `${Math.round(hours / 24)}d`
      : `${Math.round(hours)}h`
    : "-";

  return {
    label,
    window: windowLabel,
    used: pct(used),
    remaining: pct(remaining),
    resetAt: formatReset(win.reset_at),
  };
}

function collectRows(data) {
  const rows = [];

  if (data?.rate_limit) {
    const name = data?.rate_limit_name || data?.metered_limit_name || "codex";
    const primary = summarizeWindow(`${name} primary`, data.rate_limit.primary_window);
    const secondary = summarizeWindow(`${name} secondary`, data.rate_limit.secondary_window);
    if (primary) rows.push(primary);
    if (secondary) rows.push(secondary);
  }

  if (Array.isArray(data?.additional_rate_limits)) {
    for (const item of data.additional_rate_limits) {
      const name = item?.limit_name || item?.rate_limit_name || "additional";
      const details = item?.rate_limit || item;
      const primary = summarizeWindow(`${name} primary`, details?.primary_window);
      const secondary = summarizeWindow(`${name} secondary`, details?.secondary_window);
      if (primary) rows.push(primary);
      if (secondary) rows.push(secondary);
    }
  }

  const limits = data?.rateLimits || data?.rate_limits || [];

  for (const item of Array.isArray(limits) ? limits : []) {
    const name = item?.limitName || item?.limit_name || item?.meteredLimitName || item?.metered_limit_name || "codex";
    const details = item?.rate_limit || item;
    const primary = summarizeWindow(`${name} primary`, details?.primary_window);
    const secondary = summarizeWindow(`${name} secondary`, details?.secondary_window);
    if (primary) rows.push(primary);
    if (secondary) rows.push(secondary);
  }

  const byId = data?.rateLimitsByLimitId || data?.rate_limits_by_limit_id;
  if (byId && typeof byId === "object") {
    for (const [id, item] of Object.entries(byId)) {
      const details = item?.rate_limit || item;
      const primary = summarizeWindow(`${id} primary`, details?.primary_window);
      const secondary = summarizeWindow(`${id} secondary`, details?.secondary_window);
      if (primary) rows.push(primary);
      if (secondary) rows.push(secondary);
    }
  }

  return rows;
}

async function main() {
  const args = parseArgs(process.argv);
  const { accessToken, accountId } = readAuth(args.authPath);

  const headers = {
    Accept: "application/json",
    Authorization: `Bearer ${accessToken}`,
  };

  if (accountId) {
    headers["ChatGPT-Account-Id"] = accountId;
  }

  const res = await fetch(args.url, { headers });
  const text = await res.text();

  let data;
  try {
    data = text ? JSON.parse(text) : null;
  } catch {
    data = null;
  }

  if (!res.ok) {
    console.error(`Request failed: HTTP ${res.status} ${res.statusText}`);
    if (data) {
      console.error(JSON.stringify(data, null, 2));
    } else if (text) {
      console.error(text.slice(0, 1000));
    }
    if (res.status === 401 || res.status === 403) {
      console.error("\nAuth may be expired. Open Codex/ChatGPT again or run codex login, then retry.");
    }
    process.exit(1);
  }

  if (args.raw) {
    console.log(JSON.stringify(data, null, 2));
    return;
  }

  const rows = collectRows(data);
  if (rows.length === 0) {
    console.log(JSON.stringify(data, null, 2));
    return;
  }

  console.table(rows);

  const credits = data?.rateLimitResetCredits || data?.rate_limit_reset_credits;
  if (credits) {
    console.log("Rate limit reset credits:", JSON.stringify(credits));
  }
}

main().catch((error) => {
  console.error(error instanceof Error ? error.message : String(error));
  process.exit(1);
});
