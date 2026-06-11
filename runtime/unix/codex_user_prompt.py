#!/usr/bin/env python3
# -*- coding: utf-8 -*-
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from hook_common import iso_now, load_config, log_line, read_stdin_json, send_webhook, webhook_enabled


def main() -> int:
    config = load_config()
    data = read_stdin_json()
    if not data:
        return 0

    prompt = str(data.get("prompt") or data.get("text") or "").strip()
    if not prompt or not webhook_enabled(config):
        return 0

    session_id = str(data.get("session_id") or "")
    try:
        send_webhook(
            config,
            {
                "source": "codex",
                "direction": "user_prompt",
                "event": data.get("hook_event_name"),
                "session_id": session_id,
                "turn_id": data.get("turn_id"),
                "model": data.get("model"),
                "text": prompt,
                "cwd": data.get("cwd"),
                "transcript_path": data.get("transcript_path"),
                "timestamp": iso_now(),
            },
        )
        log_line("codex-hooks.log", f"Prompt webhook sent session_id={session_id}")
    except Exception as exc:  # noqa: BLE001
        log_line("codex-hooks.log", f"Prompt webhook error session_id={session_id}: {exc}")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
