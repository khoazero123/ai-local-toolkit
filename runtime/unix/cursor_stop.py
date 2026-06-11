#!/usr/bin/env python3
# -*- coding: utf-8 -*-
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from hook_common import load_config, log_line, read_stdin_json, safe_id, state_dir, write_stdout_json


def read_flag(conversation_id: str) -> dict | None:
    path = state_dir() / f"continue-{safe_id(conversation_id)}.flag"
    if not path.exists():
        return None
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except json.JSONDecodeError:
        return None


def clear_flag(conversation_id: str) -> None:
    path = state_dir() / f"continue-{safe_id(conversation_id)}.flag"
    if path.exists():
        path.unlink()


def main() -> int:
    config = load_config()
    data = read_stdin_json()
    if not data:
        return 0

    conversation_id = str(data.get("conversation_id") or "")
    generation_id = str(data.get("generation_id") or "")
    status = str(data.get("status") or "")
    loop_count = data.get("loop_count")

    flag = read_flag(conversation_id)
    if not flag:
        return 0

    flag_generation = str(flag.get("generation_id") or "")
    if flag_generation != generation_id:
        clear_flag(conversation_id)
        log_line(
            "auto-continue.log",
            f"Cleared stale flag conversation_id={conversation_id} flag_generation!={generation_id}",
        )
        return 0

    if status != "completed":
        clear_flag(conversation_id)
        log_line("auto-continue.log", f"Cleared flag status={status} conversation_id={conversation_id}")
        return 0

    clear_flag(conversation_id)
    message = str(config.get("continue_message") or "Tiếp tục")
    write_stdout_json({"followup_message": message})
    log_line(
        "auto-continue.log",
        f"Sent followup_message conversation_id={conversation_id} generation_id={generation_id} loop_count={loop_count}",
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
