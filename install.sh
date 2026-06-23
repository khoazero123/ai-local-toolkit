#!/usr/bin/env bash
set -euo pipefail

REPO_HTTPS="https://github.com/khoazero123/ai-local-toolkit.git"
RAW_BASE="https://raw.githubusercontent.com/khoazero123/ai-local-toolkit/main"

info() { printf '\033[36m==> %s\033[0m\n' "$1"; }
ok() { printf '\033[32mOK  %s\033[0m\n' "$1"; }
warn() { printf '\033[33m!!  %s\033[0m\n' "$1"; }

get_repo_root() {
  local script_dir=""
  if [[ -n "${BASH_SOURCE[0]:-}" && -f "${BASH_SOURCE[0]}" ]]; then
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  fi

  if [[ -n "$script_dir" && -f "$script_dir/runtime/unix/hook_common.sh" ]]; then
    printf '%s' "$script_dir"
    return 0
  fi

  info "Downloading repo to a temp directory..."
  local temp_root
  temp_root="$(mktemp -d)"
  if command -v git >/dev/null 2>&1; then
    git clone --depth 1 "$REPO_HTTPS" "$temp_root/repo" >/dev/null
    printf '%s' "$temp_root/repo"
    return 0
  fi

  local zip_path="$temp_root/repo.zip"
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL "$RAW_BASE/archive/refs/heads/main.zip" -o "$zip_path"
  elif command -v wget >/dev/null 2>&1; then
    wget -qO "$zip_path" "$RAW_BASE/archive/refs/heads/main.zip"
  else
    echo "curl, wget, or git is required to download the repo." >&2
    exit 1
  fi

  unzip -q "$zip_path" -d "$temp_root"
  printf '%s' "$temp_root/ai-local-toolkit-main"
}

find_existing_hook_config() {
  local newest="" newest_mtime=0 mtime candidate
  local candidates=(
    "$HOME/.cursor/hooks/hook-config.json"
    "$HOME/.codex/hooks/hook-config.json"
  )
  if [[ -n "${CODEX_HOME:-}" ]]; then
    candidates+=("$CODEX_HOME/hooks/hook-config.json")
  fi

  for candidate in "${candidates[@]}"; do
    [[ -f "$candidate" ]] || continue
    if mtime=$(stat -c %Y "$candidate" 2>/dev/null); then
      :
    else
      mtime=$(stat -f %m "$candidate" 2>/dev/null || echo 0)
    fi
    if [[ "$mtime" -gt "$newest_mtime" ]]; then
      newest_mtime=$mtime
      newest=$candidate
    fi
  done
  printf '%s' "$newest"
}

apply_existing_hook_config() {
  local defaults_json="$1"
  local existing_path="$2"
  jq -s --argjson defaults "$defaults_json" '
    .[1] as $existing | .[0] as $defaults |
    $defaults
    | .keywords = (if (($existing.keywords // []) | length) > 0 then $existing.keywords else .keywords end)
    | .continue_message = (if (($existing.continue_message // "") | length) > 0 then $existing.continue_message else .continue_message end)
    | .tail_length = ($existing.tail_length // .tail_length)
    | .max_continue_loops = ($existing.max_continue_loops // .max_continue_loops)
    | .existing_webhook_url = ($existing.webhook_url // "")
  ' <(printf '%s' "$defaults_json") "$existing_path"
}

prompt_webhook_url() {
  local default_url="${1:-}"
  local url=""
  echo
  echo "Webhook URL (leave empty to disable webhooks):"
  if [[ -n "${BASH_VERSINFO[0]:-}" && "${BASH_VERSINFO[0]}" -ge 4 ]]; then
    IFS= read -r -e -i "$default_url" -p "Webhook URL: " url || true
  else
    read -r -p "Webhook URL [$default_url]: " url || true
    if [[ -z "$url" ]]; then
      url="$default_url"
    fi
  fi
  url="${url//$'\r'/}"
  printf '%s' "$(echo "$url" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
}

prompt_keywords() {
  local defaults="$1"
  local locale="$2"
  local input=""
  echo
  echo "Auto-continue keywords (comma-separated, edit then Enter):"
  echo "Detected locale: $locale"
  if [[ -n "${BASH_VERSINFO[0]:-}" && "${BASH_VERSINFO[0]}" -ge 4 ]]; then
    IFS= read -r -e -i "$defaults" -p "Keywords: " input || true
  else
    read -r -p "Keywords [$defaults]: " input || true
    if [[ -z "$input" ]]; then
      input="$defaults"
    fi
  fi
  input="${input//$'\r'/}"
  printf '%s' "$input"
}

prompt_continue_message() {
  local default_message="$1"
  local locale="$2"
  local input=""
  echo
  echo "Auto-continue prompt sent when keywords match (edit then Enter):"
  echo "Detected locale: $locale"
  if [[ -n "${BASH_VERSINFO[0]:-}" && "${BASH_VERSINFO[0]}" -ge 4 ]]; then
    IFS= read -r -e -i "$default_message" -p "Continue prompt: " input || true
  else
    read -r -p "Continue prompt [$default_message]: " input || true
    if [[ -z "$input" ]]; then
      input="$default_message"
    fi
  fi
  input="${input//$'\r'/}"
  if [[ -z "$input" ]]; then
    printf '%s' "$default_message"
    return 0
  fi
  printf '%s' "$(echo "$input" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
}

prompt_yes_no() {
  local question="$1"
  local default_yes="$2"
  local suffix answer
  if [[ "$default_yes" == "yes" ]]; then
    suffix="[Y/n]"
  else
    suffix="[y/N]"
  fi
  read -r -p "$question $suffix: " answer || true
  answer="${answer//$'\r'/}"
  if [[ -z "$answer" ]]; then
    [[ "$default_yes" == "yes" ]]
    return $?
  fi
  case "$(echo "$answer" | tr '[:upper:]' '[:lower:]')" in
    y|yes) return 0 ;;
    *) return 1 ;;
  esac
}

require_unix_tools() {
  local cmd
  for cmd in bash curl jq; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
      echo "$cmd is required on Linux/macOS." >&2
      exit 1
    fi
  done
}

resolve_locale_defaults() {
  local repo_root="$1"
  local defaults_file="$repo_root/config.defaults.json"
  bash "$repo_root/scripts/locale_defaults.sh" resolve auto "$defaults_file"
}

write_hook_config() {
  local target_dir="$1"
  local webhook_url="$2"
  local source="$3"
  local keywords_csv="$4"
  local tail_length="$5"
  local max_loops="$6"
  local continue_message="$7"

  jq -n \
    --arg source "$source" \
    --arg webhook_url "$webhook_url" \
    --arg continue_message "$continue_message" \
    --arg keywords_csv "$keywords_csv" \
    --argjson tail_length "$tail_length" \
    --argjson max_continue_loops "$max_loops" \
    '$keywords_csv
      | split(",")
      | map(gsub("^\\s+|\\s+$"; ""))
      | map(select(length > 0)) as $keywords
      | {
          source: $source,
          webhook_url: $webhook_url,
          keywords: $keywords,
          tail_length: $tail_length,
          continue_message: $continue_message,
          max_continue_loops: $max_continue_loops
        }' >"$target_dir/hook-config.json"
  printf '\n' >>"$target_dir/hook-config.json"
}

install_cursor_hooks() {
  local repo_root="$1"
  local webhook_url="$2"
  local keywords_csv="$3"
  local tail_length="$4"
  local max_loops="$5"
  local continue_message="$6"
  local cursor_root="$HOME/.cursor"
  local hooks_dir="$cursor_root/hooks"

  mkdir -p "$hooks_dir"
  cp "$repo_root/runtime/unix/"*.sh "$hooks_dir/"
  chmod +x "$hooks_dir/"*.sh

  write_hook_config "$hooks_dir" "$webhook_url" "cursor" "$keywords_csv" "$tail_length" "$max_loops" "$continue_message"

  cat >"$cursor_root/hooks.json" <<EOF
{
  "version": 1,
  "hooks": {
    "beforeSubmitPrompt": [
      { "command": "bash ./hooks/cursor_before_prompt.sh", "timeout": 15 }
    ],
    "afterAgentResponse": [
      { "command": "bash ./hooks/cursor_after_response.sh", "timeout": 15 }
    ],
    "stop": [
      { "command": "bash ./hooks/cursor_stop.sh", "timeout": 10, "loop_limit": $max_loops }
    ]
  }
}
EOF
  ok "Installed Cursor hooks at $hooks_dir"
}

install_codex_hooks() {
  local repo_root="$1"
  local webhook_url="$2"
  local keywords_csv="$3"
  local tail_length="$4"
  local max_loops="$5"
  local continue_message="$6"
  local codex_root="$HOME/.codex"
  local hooks_dir="$codex_root/hooks"

  mkdir -p "$hooks_dir"
  cp "$repo_root/runtime/unix/"*.sh "$hooks_dir/"
  chmod +x "$hooks_dir/"*.sh

  write_hook_config "$hooks_dir" "$webhook_url" "codex" "$keywords_csv" "$tail_length" "$max_loops" "$continue_message"

  cat >"$codex_root/hooks.json" <<EOF
{
  "hooks": {
    "UserPromptSubmit": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "bash $hooks_dir/codex_user_prompt.sh",
            "timeout": 15,
            "statusMessage": "Webhook user prompt"
          }
        ]
      }
    ],
    "Stop": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "bash $hooks_dir/codex_stop.sh",
            "timeout": 15,
            "statusMessage": "Webhook + auto continue"
          }
        ]
      }
    ]
  }
}
EOF
  ok "Installed Codex hooks at $hooks_dir"
  warn "In Codex, run /hooks to trust hooks after installing."
}

main() {
  echo
  echo "Agent Webhook + Auto Continue Installer (Unix)"
  echo "=============================================="

  local repo_root defaults_json locale default_keywords keywords_input keywords_csv
  local tail_length max_loops continue_message webhook_url existing_webhook=""
  repo_root="$(get_repo_root)"
  require_unix_tools

  info "Scanning Cursor/Codex transcripts to detect conversation language..."
  defaults_json="$(resolve_locale_defaults "$repo_root")"
  locale="$(jq -r '.locale' <<<"$defaults_json")"
  default_keywords="$(jq -r '.keywords | join(", ")' <<<"$defaults_json")"
  continue_message="$(jq -r '.continue_message' <<<"$defaults_json")"
  tail_length="$(jq -r '.tail_length' <<<"$defaults_json")"
  max_loops="$(jq -r '.max_continue_loops' <<<"$defaults_json")"
  ok "Using $locale locale defaults"

  local existing_config_path=""
  existing_config_path="$(find_existing_hook_config)"
  if [[ -n "$existing_config_path" ]]; then
    ok "Loaded previous settings from $existing_config_path"
    defaults_json="$(apply_existing_hook_config "$defaults_json" "$existing_config_path")"
    default_keywords="$(jq -r '.keywords | join(", ")' <<<"$defaults_json")"
    continue_message="$(jq -r '.continue_message' <<<"$defaults_json")"
    tail_length="$(jq -r '.tail_length' <<<"$defaults_json")"
    max_loops="$(jq -r '.max_continue_loops' <<<"$defaults_json")"
    existing_webhook="$(jq -r '.existing_webhook_url // ""' <<<"$defaults_json")"
  fi

  webhook_url="$(prompt_webhook_url "$existing_webhook")"
  keywords_input="$(prompt_keywords "$default_keywords" "$locale")"
  keywords_csv="$keywords_input"
  continue_message="$(prompt_continue_message "$continue_message" "$locale")"

  local install_cursor=no install_codex=no
  if prompt_yes_no "Install for Cursor?" yes; then install_cursor=yes; fi
  if prompt_yes_no "Install for Codex?" yes; then install_codex=yes; fi

  if [[ "$install_cursor" != "yes" && "$install_codex" != "yes" ]]; then
    warn "No tools selected. Exiting."
    exit 1
  fi

  if [[ "$install_cursor" == "yes" ]]; then
    install_cursor_hooks "$repo_root" "$webhook_url" "$keywords_csv" "$tail_length" "$max_loops" "$continue_message"
  fi

  if [[ "$install_codex" == "yes" ]]; then
    install_codex_hooks "$repo_root" "$webhook_url" "$keywords_csv" "$tail_length" "$max_loops" "$continue_message"
  fi

  echo
  ok "Installation complete. Restart Cursor/Codex to apply hooks."
  if [[ -z "$webhook_url" ]]; then
    warn "Webhooks disabled (empty URL). Auto-continue only."
  fi
}

main "$@"
