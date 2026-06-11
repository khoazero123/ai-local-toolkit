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

    conversation_id = str(data.get("conversation_id") or "")
    try:
        send_webhook(
            config,
            {
                "source": config.get("source", "cursor"),
                "direction": "user_prompt",
                "event": data.get("hook_event_name"),
                "conversation_id": conversation_id,
                "generation_id": data.get("generation_id"),
                "model": data.get("model"),
                "composer_mode": data.get("composer_mode"),
                "text": prompt,
                "session_id": data.get("session_id"),
                "workspace_roots": data.get("workspace_roots") or [],
                "transcript_path": data.get("transcript_path"),
                "timestamp": iso_now(),
            },
        )
        log_line("webhook-on-prompt.log", f"Prompt webhook sent conversation_id={conversation_id}")
    except Exception as exc:  # noqa: BLE001
        log_line("webhook-on-prompt.log", f"Webhook error: {exc}")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
