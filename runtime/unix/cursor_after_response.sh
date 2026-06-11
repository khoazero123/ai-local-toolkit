#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/hook_common.sh"

main() {
  hook_require_commands
  hook_load_config
  hook_read_stdin_json || exit 0

  local text conversation_id preview flag_path flag_json
  text="$(hook_json_field '.text')"
  conversation_id="$(hook_json_field '.conversation_id')"

  if hook_webhook_enabled && [[ -n "$text" ]]; then
    local body
    body="$(jq -n \
      --arg source "$HOOK_SOURCE" \
      --arg direction "agent_response" \
      --arg event "$(hook_json_field '.hook_event_name')" \
      --arg conversation_id "$conversation_id" \
      --arg generation_id "$(hook_json_field '.generation_id')" \
      --arg model "$(hook_json_field '.model')" \
      --arg text "$text" \
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
        text: $text,
        session_id: (if $session_id == "" then null else $session_id end),
        workspace_roots: $workspace_roots,
        transcript_path: (if $transcript_path == "" then null else $transcript_path end),
        timestamp: $timestamp
      }')"
    if hook_send_webhook "$body"; then
      hook_log_line "webhook-on-response.log" "Webhook sent conversation_id=${conversation_id}"
    else
      hook_log_line "webhook-on-response.log" "Webhook error"
    fi
  fi

  if hook_contains_keyword "$text" && [[ -n "$conversation_id" ]]; then
    flag_path="$(hook_state_dir)/continue-$(hook_safe_id "$conversation_id").flag"
    flag_json="$(jq -n \
      --arg conversation_id "$conversation_id" \
      --arg generation_id "$(hook_json_field '.generation_id')" \
      --arg created_at "$(hook_iso_now)" \
      '{
        conversation_id: $conversation_id,
        generation_id: $generation_id,
        created_at: $created_at
      }')"
    printf '%s' "$flag_json" >"$flag_path"
    if ((${#text} > 120)); then
      preview="${text:0:120}..."
    else
      preview="$text"
    fi
    hook_log_line "auto-continue.log" "Flag set conversation_id=${conversation_id} preview=${preview}"
  fi
}

main "$@"
