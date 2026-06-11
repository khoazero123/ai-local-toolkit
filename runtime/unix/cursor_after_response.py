#!/usr/bin/env python3
# -*- coding: utf-8 -*-
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from hook_common import (  # noqa: E402
    contains_keyword,
    iso_now,
    load_config,
    log_line,
    read_stdin_json,
    safe_id,
    send_webhook,
    state_dir,
    webhook_enabled,
)


def main() -> int:
    config = load_config()
    data = read_stdin_json()
    if not data:
        return 0

    text = str(data.get("text") or "")
    conversation_id = str(data.get("conversation_id") or "")

    if webhook_enabled(config) and text:
        try:
            send_webhook(
                config,
                {
                    "source": config.get("source", "cursor"),
                    "direction": "agent_response",
                    "event": data.get("hook_event_name"),
                    "conversation_id": conversation_id,
                    "generation_id": data.get("generation_id"),
                    "model": data.get("model"),
                    "text": text,
                    "session_id": data.get("session_id"),
                    "workspace_roots": data.get("workspace_roots") or [],
                    "transcript_path": data.get("transcript_path"),
                    "timestamp": iso_now(),
                },
            )
            log_line("webhook-on-response.log", f"Webhook sent conversation_id={conversation_id}")
        except Exception as exc:  # noqa: BLE001
            log_line("webhook-on-response.log", f"Webhook error: {exc}")

    if contains_keyword(text, config) and conversation_id:
        flag = state_dir() / f"continue-{safe_id(conversation_id)}.flag"
        flag.write_text(
            __import__("json").dumps(
                {
                    "conversation_id": conversation_id,
                    "generation_id": data.get("generation_id"),
                    "created_at": iso_now(),
                },
                ensure_ascii=False,
            ),
            encoding="utf-8",
        )
        preview = text[:120] + ("..." if len(text) > 120 else "")
        log_line("auto-continue.log", f"Flag set conversation_id={conversation_id} preview={preview}")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
