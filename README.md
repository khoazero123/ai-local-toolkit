# AI Local Toolkit

Local automation utilities for **Cursor** and **Codex** on your machine.

Each feature has its own installer. Expand a section below to copy the install command.

---

<details>
<summary><strong>Agent Webhook + Auto Continue</strong></summary>

Sends webhooks when the user or agent chats, and automatically sends a continue follow-up when keywords are detected in the last 1000 characters of the agent response.

### Windows (PowerShell)

```powershell
irm "https://raw.githubusercontent.com/khoazero123/ai-local-toolkit/main/install.ps1" | iex
```

### Linux / macOS

```bash
curl -fsSL "https://raw.githubusercontent.com/khoazero123/ai-local-toolkit/main/install.sh" | bash
```

Or with `wget`:

```bash
wget -qO- "https://raw.githubusercontent.com/khoazero123/ai-local-toolkit/main/install.sh" | bash
```

Append `?v=<commit>` to the URL if your shell cached an older installer script.

### Install from a local clone

```powershell
cd path\to\ai-local-toolkit
.\install.ps1
```

```bash
cd ai-local-toolkit
bash install.sh
```

### Requirements

| Platform | Installer | Runtime hooks |
|----------|-----------|---------------|
| Windows | PowerShell 5.1+ | `.cmd` + `.ps1` in `runtime/windows/` |
| Linux / macOS | `bash` | `bash` scripts in `runtime/unix/` |

**Linux / macOS also needs:** `curl`, `jq`

### Codex — trust hooks

After installing, open Codex and run:

```
/hooks
```

### Files created

| Tool | Path |
|------|------|
| Cursor hooks | `~/.cursor/hooks/` + `~/.cursor/hooks.json` |
| Codex hooks | `~/.codex/hooks/` + `~/.codex/hooks.json` |

</details>

---

<details>
<summary><strong>Codex Usage + Reset Watch</strong></summary>

Check Codex rate-limit usage from the CLI and run a background watcher that sends a prompt shortly after each quota reset (no Codex desktop app required).

**What it installs into `~/.codex/`:**

- `codex-usage.mjs` — print usage table from `/backend-api/wham/usage`
- `codex-reset-watch.mjs` — PM2 daemon: poll usage, schedule prompt after reset + delay
- `ecosystem.config.cjs` — PM2 config (`windowsHide: true`)
- `codex-reset-watch-startup.ps1` — boot/logon helper
- `register-codex-reset-watch-task.ps1` — Task Scheduler registration

### Windows — one-line install

```powershell
irm "https://cdn.jsdelivr.net/gh/khoazero123/ai-local-toolkit@main/install-codex-usage.ps1" | iex
```

GitHub raw (may lag behind by a few minutes after pushes):

```powershell
irm "https://raw.githubusercontent.com/khoazero123/ai-local-toolkit/main/install-codex-usage.ps1" | iex
```

### Windows — from local clone

```powershell
cd path\to\ai-local-toolkit
.\install-codex-usage.ps1
```

The installer will:

1. Check **Node.js** — if missing, ask to install via **nvm-windows**
2. Check **PM2** — if missing, ask to install with `npm install -g pm2`
3. Copy runtime files to `~/.codex`
4. Optionally start the PM2 watcher
5. Optionally register **Task Scheduler** `CodexResetWatchPM2` (boot + logon)

### Manual commands (after install)

Check usage:

```powershell
node $env:USERPROFILE\.codex\codex-usage.mjs
```

PM2 watcher:

```powershell
pm2 start $env:USERPROFILE\.codex\ecosystem.config.cjs --only codex-reset-watch
pm2 save
pm2 status codex-reset-watch
pm2 logs codex-reset-watch
```

Register boot task (no login required — uses SYSTEM if Windows account has no password):

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File $env:USERPROFILE\.codex\register-codex-reset-watch-task.ps1
```

View watcher log:

```powershell
Get-Content $env:USERPROFILE\.codex\codex-reset-watch.log -Tail 20
```

### Config

Edit `~/.codex/codex-reset-watch.config.json`:

| Key | Default | Meaning |
|-----|---------|---------|
| `prompt` | `hi` | Message sent after reset |
| `resetDelayMs` | `180000` | Wait 3 min after reset before send |
| `checkIntervalMs` | `900000` | Re-check usage every 15 min |
| `resetWindow` | `primary` | Rate-limit window to track |
| `threadSelection` | `latest` | Resume latest Codex thread |
| `webhookUrl` | `""` | Webhook URL (empty = use `~/.codex/hooks/hook-config.json`) |
| `notifyOnReset` | `true` | POST webhook when quota window resets |

### Reset webhook payload

When the rate-limit window rolls over, watcher sends:

```json
{
  "source": "codex",
  "direction": "token_reset",
  "event": "rate_limit_reset",
  "session_id": "...",
  "text": "Codex rate limit reset. Usage now 12%. Next reset at ...",
  "completed_reset_at": "2026-06-23T06:12:03.000Z",
  "next_reset_at": "2026-06-23T11:12:03.000Z",
  "used_percent": 12,
  "timestamp": "..."
}
```

Skipped when `webhookUrl` is empty and no URL in `hooks/hook-config.json`, or `notifyOnReset` is `false`.

### Requirements

- Windows (installer is PowerShell-only for now)
- Node.js 18+ (installer can install via nvm-windows)
- PM2
- Codex signed in once (`~/.codex/auth.json` exists)
- Codex CLI at `~/.codex/.sandbox-bin/codex.exe` (created by Codex app)

### Notes

- Watcher uses `codex exec resume` — **Codex desktop app does not need to stay open**
- If the PC was off during a scheduled send, the watcher catches up on next start (`missed-after-offline`)
- Do **not** run `pm2 start codex-reset-watch.pm2.cjs` directly — use `ecosystem.config.cjs` only

</details>

---

## Repository layout

```
install.ps1                      # Agent Webhook + Auto Continue (Windows)
install.sh                       # Agent Webhook + Auto Continue (Unix)
install-codex-usage.ps1          # Codex Usage + Reset Watch (Windows)
config.defaults.json             # Webhook locale defaults
runtime/windows/                 # Webhook hook runtime (Windows)
runtime/unix/                    # Webhook hook runtime (Unix)
packages/codex-usage/runtime/    # Codex usage + reset watch scripts
scripts/locale_defaults.sh       # Locale detection (Unix installer)
```

## License

MIT
