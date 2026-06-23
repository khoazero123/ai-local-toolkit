#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/hook_common.sh"

main() {
  hook_require_commands
  hook_load_config
  hook_read_stdin_json || exit 0

  local prompt conversation_id body
  prompt="$(hook_json_field '.prompt // .text // ""' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
  if [[ -z "$prompt" ]] || ! hook_webhook_enabled; then
    exit 0
  fi

  conversation_id="$(hook_json_field '.conversation_id')"
  body="$(jq -n \
    --arg source "$HOOK_SOURCE" \
    --arg direction "user_prompt" \
    --arg event "$(hook_json_field '.hook_event_name')" \
    --arg conversation_id "$conversation_id" \
    --arg generation_id "$(hook_json_field '.generation_id')" \
    --arg model "$(hook_json_field '.model')" \
    --arg composer_mode "$(hook_json_field '.composer_mode')" \
    --arg text "$prompt" \
    --arg session_id "$(hook_json_field '.session_id')" \
    --arg transcript_path "$(hook_json_field '.transcript_path')" \
    --arg timestamp "$(hook_iso_now)" \
    --argjson workspace_roots "$(jq -c '.workspace_roots // []' <<<"$HOOK_JSON")" \
    '{
      source: $source,
      direction: $direction,
      event: (if $event == "" then null else $event end),
      conversation_id: $conversation_id,
      generation_id: (if $generation_id == "" then null else $generation_id end),
      model: (if $model == "" then null else $model end),
      composer_mode: (if $composer_mode == "" then null else $composer_mode end),
      text: $text,
      session_id: (if $session_id == "" then null else $session_id end),
      workspace_roots: $workspace_roots,
      transcript_path: (if $transcript_path == "" then null else $transcript_path end),
      timestamp: $timestamp
    }')"

  if hook_send_webhook "$body"; then
    hook_log_line "webhook-on-prompt.log" "Prompt webhook sent conversation_id=${conversation_id}"
  else
    hook_log_line "webhook-on-prompt.log" "Webhook error"
  fi
}

main "$@"
