# Agent Webhook + Auto Continue

Automated installer for **Cursor** and **Codex**: sends webhooks when the user or agent chats, and automatically sends a continue follow-up when keywords are detected in the last 1000 characters of the agent response.

## Quick install

### Windows (PowerShell)

```powershell
irm "https://raw.githubusercontent.com/khoazero123/agent-webhook-tracking-continues/main/install.ps1" | iex
```

### Linux / macOS

```bash
curl -fsSL "https://raw.githubusercontent.com/khoazero123/agent-webhook-tracking-continues/main/install.sh" | bash
```

Or with `wget`:

```bash
wget -qO- "https://raw.githubusercontent.com/khoazero123/agent-webhook-tracking-continues/main/install.sh" | bash
```

Append `?v=<commit>` to the URL if your shell cached an older installer script.

## Requirements

| Platform | Installer | Runtime hooks |
|----------|-----------|---------------|
| Windows | PowerShell 5.1+ | `.cmd` + `.ps1` in `runtime/windows/` |
| Linux / macOS | `bash` | `bash` scripts in `runtime/unix/` |

**Linux / macOS also needs:**

- `curl` — send webhook HTTP POST requests
- `jq` — parse and build JSON for hooks and the installer

Install `jq` if missing:

```bash
# macOS
brew install jq

# Debian / Ubuntu
sudo apt install jq
```

No Python is required on any platform.

## Installation flow

1. **Detect locale** — scans existing Cursor/Codex conversation transcripts:
   - Vietnamese diacritics found → Vietnamese defaults
   - Otherwise → English defaults

   Transcript locations:

   - Cursor: `~/.cursor/projects/*/agent-transcripts/**/*.jsonl`
   - Codex: `~/.codex/sessions/**/*.jsonl` (or `$CODEX_HOME/sessions`)

2. **Load previous settings** — if `hook-config.json` already exists under `~/.cursor/hooks/` or `~/.codex/hooks/`, the installer pre-fills values from the newest file.

3. **Prompts** (all pre-filled and editable — edit then press Enter):

   | Prompt | Notes |
   |--------|-------|
   | Webhook URL | Empty = webhooks disabled |
   | Keywords | Comma-separated list |
   | Continue prompt | Message sent when keywords match |
   | Install for Cursor? | Y/n |
   | Install for Codex? | Y/n |

4. **Default keywords** (from `config.defaults.json`, by locale):

   - Vietnamese: `tiếp tục`, `Bước tiếp`, `Việc tiếp`, `Bạn muốn`, `Bạn có muốn`
   - English: `continue`, `next step`, `what's next`, `would you like`, `do you want`

5. **Default continue prompt:** `Tiếp tục` (vi) or `Continue` (en)

## Files created

| Tool | Path |
|------|------|
| Cursor hooks | `~/.cursor/hooks/` + `~/.cursor/hooks.json` |
| Codex hooks | `~/.codex/hooks/` + `~/.codex/hooks.json` |

Each hooks directory contains:

- `hook-config.json` — webhook URL, keywords, continue message, `tail_length`, `max_continue_loops`
- Runtime scripts copied from `runtime/windows/` or `runtime/unix/`
- `state/` — auto-continue flags (created at runtime)

## Webhook payload

```json
{
  "source": "cursor",
  "direction": "user_prompt",
  "text": "...",
  "conversation_id": "...",
  "timestamp": "..."
}
```

`direction` is `user_prompt` or `agent_response`. Codex uses `session_id` / `turn_id` instead of `conversation_id`.

Webhooks are skipped when the URL in `hook-config.json` is empty.

## Auto-continue

- Scans only the **last 1000 characters** of the agent response (`tail_length` in config)
- Case-insensitive keyword match
- Vietnamese keywords require diacritics (e.g. `tiếp tục` matches; `tiep tuc` does not)
- **Cursor:** `afterAgentResponse` sets a flag; `stop` hook outputs `{ "followup_message": "<continue_message>" }` (max 10 loops)
- **Codex:** `Stop` hook returns `{ "decision": "block", "reason": "<continue_message>" }` (max 10 loops)

## Logs

| Tool | Log files |
|------|-----------|
| Cursor | `~/.cursor/hooks/webhook-on-prompt.log`, `webhook-on-response.log`, `auto-continue.log` |
| Codex | `~/.codex/hooks/codex-hooks.log` |

## Codex — trust hooks

After installing, open Codex and run:

```
/hooks
```

to trust the hooks.

## Install from a local clone

```powershell
cd path\to\agent-webhook-tracking-continues
.\install.ps1
```

```bash
cd agent-webhook-tracking-continues
bash install.sh
```

## Repository layout

```
install.ps1              # Windows installer
install.sh               # Linux/macOS installer
config.defaults.json     # Shared locale defaults
runtime/windows/         # PowerShell hook runtime
runtime/unix/            # Bash hook runtime
scripts/locale_defaults.sh   # Locale detection (Unix installer)
```

## License

MIT
