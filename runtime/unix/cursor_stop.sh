#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/hook_common.sh"

read_flag() {
  local conversation_id="$1"
  local path="$2"
  [[ -f "$path" ]] || return 1
  jq -c . <"$path"
}

main() {
  hook_require_commands
  hook_load_config
  hook_read_stdin_json || exit 0

  local conversation_id generation_id status loop_count flag_path flag_json flag_generation output
  conversation_id="$(hook_json_field '.conversation_id')"
  generation_id="$(hook_json_field '.generation_id')"
  status="$(hook_json_field '.status')"
  loop_count="$(hook_json_field '.loop_count')"

  flag_path="$(hook_state_dir)/continue-$(hook_safe_id "$conversation_id").flag"
  flag_json="$(read_flag "$conversation_id" "$flag_path" || true)"
  if [[ -z "$flag_json" ]]; then
    exit 0
  fi

  flag_generation="$(jq -r '.generation_id // ""' <<<"$flag_json")"
  if [[ "$flag_generation" != "$generation_id" ]]; then
    rm -f "$flag_path"
    hook_log_line "auto-continue.log" "Cleared stale flag conversation_id=${conversation_id} flag_generation!=${generation_id}"
    exit 0
  fi

  if [[ "$status" != "completed" ]]; then
    rm -f "$flag_path"
    hook_log_line "auto-continue.log" "Cleared flag status=${status} conversation_id=${conversation_id}"
    exit 0
  fi

  rm -f "$flag_path"
  output="$(jq -n --arg message "$HOOK_CONTINUE_MESSAGE" '{followup_message: $message}')"
  hook_write_stdout_json "$output"
  hook_log_line "auto-continue.log" "Sent followup_message conversation_id=${conversation_id} generation_id=${generation_id} loop_count=${loop_count}"
}

main "$@"
