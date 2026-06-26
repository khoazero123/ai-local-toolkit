#!/usr/bin/env bash
# Detect conversation locale and resolve installer defaults (bash + jq).

set -euo pipefail

MAX_FILES=40
MAX_BYTES=512000

contains_vietnamese() {
  local text="$1"
  LC_ALL=C.UTF-8 grep -q $'[\303\200-\303\243\303\250-\303\252\303\254-\303\255\303\262-\303\265\303\271-\303\272\303\235\304\202\304\203\304\220\304\221\304\250\304\251\306\257\306\260\341\272\240-\341\273\271]' <<<"$text"
}

should_skip_text() {
  local text="$1"
  text="${text#"${text%%[![:space:]]*}"}"
  [[ -z "$text" ]] && return 0
  local lower
  lower="$(printf '%s' "$text" | tr '[:upper:]' '[:lower:]')"
  case "$lower" in
    "<environment_context>"* | "<permissions"* | "<app-context>"* | "<collaboration_mode>"* | "<skills_instructions>"* | "<plugins_instructions>"*)
      return 0
      ;;
  esac
  return 1
}

normalize_user_text() {
  local text="$1"
  if [[ "$text" =~ \<user_query\>[[:space:]]*(.*)[[:space:]]*\</user_query\> ]]; then
    text="${BASH_REMATCH[1]}"
  fi
  text="${text#"${text%%[![:space:]]*}"}"
  text="${text%"${text##*[![:space:]]}"}"
  printf '%s' "$text"
}

extract_cursor_line() {
  local line="$1"
  local role chunks=() part_text
  role="$(jq -r '.role // empty' <<<"$line" 2>/dev/null || true)"
  [[ "$role" == "user" || "$role" == "assistant" ]] || return 0
  while IFS= read -r part_text; do
    [[ -n "$part_text" ]] || continue
    should_skip_text "$part_text" && continue
    chunks+=("$(normalize_user_text "$part_text")")
  done < <(jq -r '.message.content[]? | select(.type == "text") | .text // empty' <<<"$line" 2>/dev/null || true)
  (IFS=$'\n'; printf '%s' "${chunks[*]}")
}

extract_codex_line() {
  local line="$1"
  local role chunks=() part_text
  jq -e '.type == "response_item" and (.payload.type // "") == "message"' <<<"$line" >/dev/null 2>&1 || return 0
  role="$(jq -r '.payload.role // empty' <<<"$line")"
  [[ "$role" == "user" || "$role" == "assistant" ]] || return 0
  while IFS= read -r part_text; do
    [[ -n "$part_text" ]] || continue
    should_skip_text "$part_text" && continue
    chunks+=("$(normalize_user_text "$part_text")")
  done < <(jq -r '.payload.content[]? | select(.type == "input_text" or .type == "output_text" or .type == "text") | .text // empty' <<<"$line")
  (IFS=$'\n'; printf '%s' "${chunks[*]}")
}

list_transcript_files() {
  local file mtime
  {
    if [[ -d "$HOME/.cursor/projects" ]]; then
      find "$HOME/.cursor/projects" -type f -name '*.jsonl' 2>/dev/null | grep 'agent-transcripts' || true
    fi
    if [[ -d "$HOME/.codex/sessions" ]]; then
      find "$HOME/.codex/sessions" -type f -name '*.jsonl' 2>/dev/null || true
    fi
    if [[ -n "${CODEX_HOME:-}" && -d "$CODEX_HOME/sessions" ]]; then
      find "$CODEX_HOME/sessions" -type f -name '*.jsonl' 2>/dev/null || true
    fi
  } | awk '!seen[$0]++' | while read -r file; do
    if mtime=$(stat -c '%Y %n' "$file" 2>/dev/null); then
      printf '%s\n' "$mtime"
    else
      stat -f '%m %N' "$file"
    fi
  done | sort -rn | head -n "$MAX_FILES" | awk '{ $1=""; sub(/^ /,""); print }'
}

detect_locale() {
  local file line text sampled=0
  while IFS= read -r file; do
    [[ -f "$file" ]] || continue
    while IFS= read -r line || [[ -n "$line" ]]; do
      ((sampled >= MAX_BYTES)) && break 2
      text="$(extract_cursor_line "$line")"
      [[ -z "$text" ]] && text="$(extract_codex_line "$line")"
      [[ -z "$text" ]] && continue
      sampled=$((sampled + ${#text}))
      if contains_vietnamese "$text"; then
        printf 'vi'
        return 0
      fi
    done <"$file"
  done < <(list_transcript_files)
  printf 'en'
}

resolve_defaults() {
  local locale="$1"
  local config_path="$2"
  if ! jq -e --arg locale "$locale" '.locales[$locale]' "$config_path" >/dev/null 2>&1; then
    locale="en"
  fi
  jq -n \
    --arg locale "$locale" \
    --slurpfile config "$config_path" \
    '{
      locale: $locale,
      keywords: $config[0].locales[$locale].keywords,
      continue_message: $config[0].locales[$locale].continue_message,
      tail_length: $config[0].tail_length,
      max_continue_loops: $config[0].max_continue_loops,
      continue_flag_max_age_seconds: ($config[0].continue_flag_max_age_seconds // 120)
    }'
}

main() {
  command -v jq >/dev/null 2>&1 || {
    echo "jq is required." >&2
    exit 1
  }

  local command="${1:-}"
  case "$command" in
    detect)
      detect_locale
      ;;
    resolve)
      local locale_arg="${2:-auto}"
      local config_path="${3:-config.defaults.json}"
      local locale="$locale_arg"
      if [[ "$locale_arg" == "auto" ]]; then
        locale="$(detect_locale)"
      fi
      resolve_defaults "$locale" "$config_path"
      ;;
    *)
      echo "Unknown command: $command" >&2
      exit 1
      ;;
  esac
}

main "$@"
