#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/hook_common.sh"

main() {
  hook_require_commands
  hook_load_config
  hook_read_stdin_json || exit 0

  local prompt session_id body
  prompt="$(hook_json_field '.prompt // .text // ""' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
  if [[ -z "$prompt" ]] || ! hook_webhook_enabled; then
    exit 0
  fi

  session_id="$(hook_json_field '.session_id')"
  body="$(jq -n \
    --arg source "codex" \
    --arg direction "user_prompt" \
    --arg event "$(hook_json_field '.hook_event_name')" \
    --arg session_id "$session_id" \
    --arg turn_id "$(hook_json_field '.turn_id')" \
    --arg model "$(hook_json_field '.model')" \
    --arg text "$prompt" \
    --arg cwd "$(hook_json_field '.cwd')" \
    --arg transcript_path "$(hook_json_field '.transcript_path')" \
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
      timestamp: $timestamp
    }')"

  if hook_send_webhook "$body"; then
    hook_log_line "codex-hooks.log" "Prompt webhook sent session_id=${session_id}"
  else
    hook_log_line "codex-hooks.log" "Prompt webhook error session_id=${session_id}"
  fi
}

main "$@"
