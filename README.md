# Agent Webhook + Auto Continue

Automated installer for **Cursor** and **Codex**: sends webhooks when the user or agent chats, and automatically sends **"Tiếp tục"** when keywords are detected in the last 1000 characters of the agent response.

## Quick install

### Windows (PowerShell)

```powershell
irm https://raw.githubusercontent.com/khoazero123/agent-webhook-tracking-continues/main/install.ps1 | iex
```

### Linux / macOS

```bash
curl -fsSL https://raw.githubusercontent.com/khoazero123/agent-webhook-tracking-continues/main/install.sh | bash
```

Or with `wget`:

```bash
wget -qO- https://raw.githubusercontent.com/khoazero123/agent-webhook-tracking-continues/main/install.sh | bash
```

## Installation flow

The script will ask for:

1. **Webhook URL** — leave empty to disable webhooks
2. **Auto-continue keywords** — defaults:
   - `tiếp tục`
   - `Bước tiếp`
   - `Việc tiếp`
   - `Bạn muốn`
   - `Bạn có muốn`
3. **Cursor** — yes/no
4. **Codex** — yes/no

## Files created

| Tool | Path |
|------|------|
| Cursor hooks | `~/.cursor/hooks/` + `~/.cursor/hooks.json` |
| Codex hooks | `~/.codex/hooks/` + `~/.codex/hooks.json` |

Each hooks directory includes `hook-config.json` with the webhook URL and keywords.

## Webhook payload

```json
{
  "source": "cursor",
  "direction": "user_prompt | agent_response",
  "text": "...",
  "conversation_id": "...",
  "timestamp": "..."
}
```

Codex uses `session_id` / `turn_id` instead of `conversation_id`.

## Auto-continue

- Only scans the **last 1000 characters** of the agent response
- Case-insensitive matching
- Requires Vietnamese diacritics (e.g. `tiếp tục` matches, `tiep tuc` does not)
- Cursor: `stop` hook sends `followup_message: "Tiếp tục"` (default max 10 loops)
- Codex: `Stop` hook returns `{ "decision": "block", "reason": "Tiếp tục" }`

## Logs

- Cursor: `~/.cursor/hooks/webhook-on-prompt.log`, `webhook-on-response.log`, `auto-continue.log`
- Codex: `~/.codex/hooks/codex-hooks.log`

## Codex — trust hooks

After installing, open Codex and run:

```
/hooks
```

to trust the hooks.

## Install from a local clone

```powershell
cd E:\www\my-projects\agent-webhook-tracking-continues
.\install.ps1
```

```bash
cd agent-webhook-tracking-continues
bash install.sh
```

## Platform notes

- **Windows**: PowerShell 5.1+, hooks run via `.cmd` + `.ps1`
- **Linux/macOS**: requires `python3`, hooks run via Python
- Webhooks are disabled when the URL is empty — webhook scripts are still installed but no-op

## License

MIT
