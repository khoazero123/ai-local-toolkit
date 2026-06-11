#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Shared hook runtime for Cursor/Codex on Linux/macOS."""

from __future__ import annotations

import json
import os
import re
import sys
import urllib.error
import urllib.request
from datetime import datetime, timezone
from pathlib import Path
from typing import Any


def hooks_dir() -> Path:
    return Path(__file__).resolve().parent


def load_config() -> dict[str, Any]:
    path = hooks_dir() / "hook-config.json"
    with path.open("r", encoding="utf-8") as f:
        return json.load(f)


def read_stdin_json() -> dict[str, Any] | None:
    raw = sys.stdin.buffer.read()
    if not raw:
        return None
    if raw.startswith(b"\xef\xbb\xbf"):
        raw = raw[3:]
    text = raw.decode("utf-8").strip().lstrip("\ufeff")
    if not text or "{" not in text:
        return None
    start = text.index("{")
    depth = 0
    in_string = False
    escape = False
    for i in range(start, len(text)):
        ch = text[i]
        if in_string:
            if escape:
                escape = False
                continue
            if ch == "\\":
                escape = True
                continue
            if ch == '"':
                in_string = False
            continue
        if ch == '"':
            in_string = True
            continue
        if ch == "{":
            depth += 1
        elif ch == "}":
            depth -= 1
            if depth == 0:
                return json.loads(text[start : i + 1])
    return json.loads(text)


def log_line(filename: str, message: str) -> None:
    path = hooks_dir() / filename
    ts = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    with path.open("a", encoding="utf-8") as f:
        f.write(f"[{ts}] {message}\n")


def tail_text(text: str, tail_length: int) -> str:
    if not text:
        return ""
    if len(text) <= tail_length:
        return text
    return text[-tail_length:]


def contains_keyword(text: str, config: dict[str, Any]) -> bool:
    if not text:
        return False
    sample = tail_text(text, int(config.get("tail_length", 1000)))
    keywords = config.get("keywords") or []
    for keyword in keywords:
        if not keyword:
            continue
        if re.search(re.escape(keyword), sample, re.IGNORECASE):
            return True
    return False


def webhook_enabled(config: dict[str, Any]) -> bool:
    url = (config.get("webhook_url") or "").strip()
    return bool(url)


def send_webhook(config: dict[str, Any], payload: dict[str, Any]) -> None:
    url = (config.get("webhook_url") or "").strip()
    if not url:
        return
    body = json.dumps(payload, ensure_ascii=False).encode("utf-8")
    req = urllib.request.Request(
        url,
        data=body,
        headers={"Content-Type": "application/json; charset=utf-8"},
        method="POST",
    )
    with urllib.request.urlopen(req, timeout=12) as resp:
        resp.read()


def iso_now() -> str:
    return datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")


def state_dir() -> Path:
    path = hooks_dir() / "state"
    path.mkdir(parents=True, exist_ok=True)
    return path


def safe_id(value: str) -> str:
    return re.sub(r"[^\w\-]", "_", value or "")


def write_stdout_json(data: dict[str, Any]) -> None:
    out = json.dumps(data, ensure_ascii=False).encode("utf-8")
    sys.stdout.buffer.write(out)
    sys.stdout.buffer.flush()
