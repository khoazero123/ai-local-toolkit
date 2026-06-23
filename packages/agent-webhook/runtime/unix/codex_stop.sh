#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/hook_common.sh"

loop_path() {
  printf '%s/continue-loop-%s.txt' "$(hook_state_dir)" "$(hook_safe_id "$1")"
}

reset_loop_count() {
  local path
  path="$(loop_path "$1")"
  [[ -f "$path" ]] && rm -f "$path"
}

get_loop_count() {
  local path value
  path="$(loop_path "$1")"
  [[ -f "$path" ]] || {
    printf '0'
    return 0
  }
  value="$(<"$path")"
  value="${value//[[:space:]]/}"
  if [[ "$value" =~ ^[0-9]+$ ]]; then
    printf '%s' "$value"
  else
    printf '0'
  fi
}

increment_loop_count() {
  local session_id="$1"
  local count path
  count=$(( $(get_loop_count "$session_id") + 1 ))
  path="$(loop_path "$session_id")"
  printf '%s' "$count" >"$path"
  printf '%s' "$count"
}

main() {
  hook_require_commands
  hook_load_config
  hook_read_stdin_json || exit 0

  local session_id turn_id assistant_text body count output
  session_id="$(hook_json_field '.session_id')"
  turn_id="$(hook_json_field '.turn_id')"
  assistant_text="$(hook_json_field '.last_assistant_message')"

  if hook_webhook_enabled && [[ -n "$assistant_text" ]]; then
    body="$(jq -n \
      --arg source "codex" \
      --arg direction "agent_response" \
      --arg event "$(hook_json_field '.hook_event_name')" \
      --arg session_id "$session_id" \
      --arg turn_id "$turn_id" \
      --arg model "$(hook_json_field '.model')" \
      --arg text "$assistant_text" \
      --arg cwd "$(hook_json_field '.cwd')" \
      --arg transcript_path "$(hook_json_field '.transcript_path')" \
      --arg permission_mode "$(hook_json_field '.permission_mode')" \
      --argjson stop_hook_active "$(jq -c '.stop_hook_active // null' <<<"$HOOK_JSON")" \
      --arg timestamp "$(hook_iso_now)" \
      '{
        source: $source,
        direction: $direction,
        event: (if $event == "" then null else $event end),
        session_id: $session_id,
        turn_id: (if $turn_id == "" then null else $turn_id end),
        model: (if $model == "" then null else $model end),
        text: $text,
        cwd: (if $cwd == "" then null else $cwd end),
        transcript_path: (if $transcript_path == "" then null else $transcript_path end),
        permission_mode: (if $permission_mode == "" then null else $permission_mode end),
        stop_hook_active: $stop_hook_active,
        timestamp: $timestamp
      }')"
    if hook_send_webhook "$body"; then
      hook_log_line "codex-hooks.log" "Webhook sent session_id=${session_id} turn_id=${turn_id}"
    else
      hook_log_line "codex-hooks.log" "Webhook error session_id=${session_id}"
    fi
  fi

  if ! hook_contains_keyword "$assistant_text"; then
    reset_loop_count "$session_id"
    exit 0
  fi

  if (( $(get_loop_count "$session_id") >= HOOK_MAX_LOOPS )); then
    hook_log_line "codex-hooks.log" "Skip auto-continue loop limit session_id=${session_id}"
    exit 0
  fi

  count="$(increment_loop_count "$session_id")"
  output="$(jq -n --arg message "$HOOK_CONTINUE_MESSAGE" '{decision: "block", reason: $message}')"
  hook_write_stdout_json "$output"
  hook_log_line "codex-hooks.log" "Auto-continue session_id=${session_id} turn_id=${turn_id} loop=${count}"
}

main "$@"
