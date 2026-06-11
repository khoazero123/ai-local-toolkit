#!/usr/bin/env python3
# -*- coding: utf-8 -*-
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from hook_common import (
    contains_keyword,
    iso_now,
    load_config,
    log_line,
    read_stdin_json,
    safe_id,
    send_webhook,
    state_dir,
    webhook_enabled,
    write_stdout_json,
)


def loop_path(session_id: str) -> Path:
    return state_dir() / f"continue-loop-{safe_id(session_id)}.txt"


def reset_loop_count(session_id: str) -> None:
    path = loop_path(session_id)
    if path.exists():
        path.unlink()


def get_loop_count(session_id: str) -> int:
    path = loop_path(session_id)
    if not path.exists():
        return 0
    value = path.read_text(encoding="utf-8").strip()
    return int(value) if value.isdigit() else 0


def increment_loop_count(session_id: str) -> int:
    n = get_loop_count(session_id) + 1
    loop_path(session_id).write_text(str(n), encoding="utf-8")
    return n


def main() -> int:
    config = load_config()
    data = read_stdin_json()
    if not data:
        return 0

    session_id = str(data.get("session_id") or "")
    turn_id = str(data.get("turn_id") or "")
    assistant_text = str(data.get("last_assistant_message") or "")

    if webhook_enabled(config) and assistant_text:
        try:
            send_webhook(
                config,
                {
                    "source": "codex",
                    "direction": "agent_response",
                    "event": data.get("hook_event_name"),
                    "session_id": session_id,
                    "turn_id": turn_id,
                    "model": data.get("model"),
                    "text": assistant_text,
                    "cwd": data.get("cwd"),
                    "transcript_path": data.get("transcript_path"),
                    "permission_mode": data.get("permission_mode"),
                    "stop_hook_active": data.get("stop_hook_active"),
                    "timestamp": iso_now(),
                },
            )
            log_line("codex-hooks.log", f"Webhook sent session_id={session_id} turn_id={turn_id}")
        except Exception as exc:
            log_line("codex-hooks.log", f"Webhook error session_id={session_id}: {exc}")

    if not contains_keyword(assistant_text, config):
        reset_loop_count(session_id)
        return 0

    max_loops = int(config.get("max_continue_loops", 10))
    if get_loop_count(session_id) >= max_loops:
        log_line("codex-hooks.log", f"Skip auto-continue loop limit session_id={session_id}")
        return 0

    n = increment_loop_count(session_id)
    message = str(config.get("continue_message") or "Tiếp tục")
    write_stdout_json({"decision": "block", "reason": message})
    log_line("codex-hooks.log", f"Auto-continue session_id={session_id} turn_id={turn_id} loop={n}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
