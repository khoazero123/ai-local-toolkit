#!/usr/bin/env bash
# Shared hook runtime for Cursor/Codex on Linux/macOS (bash + curl + jq).

set -euo pipefail

HOOK_ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[1]:-${BASH_SOURCE[0]}}")" && pwd)"
HOOK_JSON=""
HOOK_CONFIG=""
HOOK_SOURCE="cursor"
HOOK_WEBHOOK_URL=""
HOOK_TAIL_LENGTH=1000
HOOK_MAX_LOOPS=10
HOOK_CONTINUE_MESSAGE="Tiếp tục"
HOOK_KEYWORDS=()

hook_require_commands() {
  local cmd
  for cmd in curl jq; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
      echo "Required command not found: $cmd" >&2
      exit 1
    fi
  done
}

hook_log_line() {
  local file="$1"
  local message="$2"
  printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$message" >>"$HOOK_ROOT_DIR/$file"
}

hook_iso_now() {
  date -u '+%Y-%m-%dT%H:%M:%SZ'
}

hook_safe_id() {
  printf '%s' "$1" | tr -c '[:alnum:]_-' '_'
}

hook_state_dir() {
  mkdir -p "$HOOK_ROOT_DIR/state"
  printf '%s' "$HOOK_ROOT_DIR/state"
}

extract_first_json_object() {
  local text="${1:-}"
  if [[ -z "$text" ]]; then
    text="$(cat)"
  fi

  text="${text//$'\ufeff'/}"
  text="${text//$'\r'/}"
  text="${text#"${text%%[![:space:]]*}"}"

  local i len="${#text}" ch depth=0 in_string=0 escape=0 start=-1
  for ((i = 0; i < len; i++)); do
    ch="${text:i:1}"
    if ((in_string)); then
      if ((escape)); then
        escape=0
        continue
      fi
      if [[ "$ch" == '\\' ]]; then
        escape=1
        continue
      fi
      if [[ "$ch" == '"' ]]; then
        in_string=0
      fi
      continue
    fi

    if [[ "$ch" == '"' ]]; then
      in_string=1
      continue
    fi
    if [[ "$ch" == '{' ]]; then
      if ((depth == 0)); then
        start=$i
      fi
      depth=$((depth + 1))
    elif [[ "$ch" == '}' ]]; then
      depth=$((depth - 1))
      if ((depth == 0 && start >= 0)); then
        printf '%s' "${text:start:i - start + 1}"
        return 0
      fi
    fi
  done

  return 1
}

hook_read_stdin_json() {
  local raw extracted
  raw="$(cat)"
  extracted="$(extract_first_json_object "$raw" || true)"
  if [[ -z "$extracted" ]]; then
    return 1
  fi
  HOOK_JSON="$extracted"
}

hook_json_field() {
  jq -r "$1 // empty" <<<"$HOOK_JSON"
}

hook_load_config() {
  local config_file="$HOOK_ROOT_DIR/hook-config.json"
  if [[ ! -f "$config_file" ]]; then
    echo "Missing hook-config.json at $config_file" >&2
    exit 1
  fi

  HOOK_CONFIG="$(<"$config_file")"
  HOOK_SOURCE="$(jq -r '.source // "cursor"' <<<"$HOOK_CONFIG")"
  HOOK_WEBHOOK_URL="$(jq -r '.webhook_url // ""' <<<"$HOOK_CONFIG")"
  HOOK_TAIL_LENGTH="$(jq -r '.tail_length // 1000' <<<"$HOOK_CONFIG")"
  HOOK_MAX_LOOPS="$(jq -r '.max_continue_loops // 10' <<<"$HOOK_CONFIG")"
  HOOK_CONTINUE_FLAG_MAX_AGE="$(jq -r '.continue_flag_max_age_seconds // 120' <<<"$HOOK_CONFIG")"
  HOOK_CONTINUE_MESSAGE="$(jq -r '.continue_message // "Tiếp tục"' <<<"$HOOK_CONFIG")"
  HOOK_KEYWORDS=()
  while IFS= read -r keyword; do
    [[ -n "$keyword" ]] && HOOK_KEYWORDS+=("$keyword")
  done < <(jq -r '.keywords[]? // empty' <<<"$HOOK_CONFIG")
}

hook_webhook_enabled() {
  [[ -n "${HOOK_WEBHOOK_URL//[[:space:]]/}" ]]
}

hook_send_webhook() {
  local body="$1"
  if ! hook_webhook_enabled; then
    return 0
  fi

  curl -fsS -X POST "$HOOK_WEBHOOK_URL" \
    -H 'Content-Type: application/json; charset=utf-8' \
    --data-binary "$body" \
    --max-time 12 \
    >/dev/null
}

hook_tail_text() {
  local text="$1"
  local tail_length="${2:-$HOOK_TAIL_LENGTH}"
  local len=${#text}
  if ((len <= tail_length)); then
    printf '%s' "$text"
  else
    printf '%s' "${text: -tail_length}"
  fi
}

hook_contains_keyword() {
  local text="$1"
  local sample keyword

  [[ -n "$text" ]] || return 1
  sample="$(hook_tail_text "$text")"
  shopt -s nocasematch
  for keyword in "${HOOK_KEYWORDS[@]}"; do
    [[ -z "$keyword" ]] && continue
    if [[ "$sample" == *"$keyword"* ]]; then
      return 0
    fi
  done
  return 1
}

hook_write_stdout_json() {
  printf '%s' "$1"
}

hook_parse_iso_utc_to_epoch() {
  local iso="$1"
  local epoch=""

  if epoch="$(date -u -d "$iso" +%s 2>/dev/null)"; then
    printf '%s' "$epoch"
    return 0
  fi

  if epoch="$(date -u -j -f "%Y-%m-%dT%H:%M:%SZ" "$iso" +%s 2>/dev/null)"; then
    printf '%s' "$epoch"
    return 0
  fi

  return 1
}

hook_continue_flag_active() {
  local flag_json="$1"
  local flag_generation="$2"
  local stop_generation="$3"

  if [[ -n "$flag_generation" && -n "$stop_generation" && "$flag_generation" == "$stop_generation" ]]; then
    return 0
  fi

  local created_at max_age now_ts created_ts age
  created_at="$(jq -r '.created_at // ""' <<<"$flag_json")"
  if [[ -z "$created_at" ]]; then
    return 0
  fi

  if [[ ! "$HOOK_CONTINUE_FLAG_MAX_AGE" =~ ^[0-9]+$ ]]; then
    HOOK_CONTINUE_FLAG_MAX_AGE=120
  fi
  max_age="$HOOK_CONTINUE_FLAG_MAX_AGE"

  created_ts="$(hook_parse_iso_utc_to_epoch "$created_at" || true)"
  if [[ -z "$created_ts" ]]; then
    return 0
  fi

  now_ts="$(date -u +%s)"
  age=$((now_ts - created_ts))
  ((age < 0)) && age=0
  ((age <= max_age))
}
