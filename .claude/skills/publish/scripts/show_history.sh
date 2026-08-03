#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/publish_common.sh"

usage() {
  cat <<'USAGE'
Usage: show_history.sh [--limit <n>] [--target <name>] [--json] [--config <path>]
USAGE
}

LIMIT_VALUE=''
TARGET_NAME=''
JSON_OUTPUT=0
CONFIG_PATH=''

while [[ $# -gt 0 ]]; do
  case "$1" in
    --limit)
      [[ $# -ge 2 ]] || { usage >&2; exit 1; }
      LIMIT_VALUE="$2"
      shift 2
      ;;
    --target)
      [[ $# -ge 2 ]] || { usage >&2; exit 1; }
      TARGET_NAME="$2"
      shift 2
      ;;
    --json)
      JSON_OUTPUT=1
      shift
      ;;
    --config)
      [[ $# -ge 2 ]] || { usage >&2; exit 1; }
      CONFIG_PATH="$2"
      shift 2
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      usage >&2
      exit 1
      ;;
  esac
done

if [[ -n "$LIMIT_VALUE" && ! "$LIMIT_VALUE" =~ ^[0-9]+$ ]]; then
  echo '--limit must be a non-negative integer.' >&2
  exit 1
fi

HISTORY_FILE="$(publish_resolve_history_file "$CONFIG_PATH")"
if [[ ! -f "$HISTORY_FILE" ]]; then
  if (( JSON_OUTPUT )); then
    printf '[]\n'
  else
    printf 'No publish history found.\n'
  fi
  exit 0
fi

FILTERED_JSON="$(jq -c \
  --arg target "$TARGET_NAME" \
  --arg limit "$LIMIT_VALUE" '
    [ .[]?
      | select(type == "object")
      | if $target == "" then . else select((.target // "") == $target) end
    ]
    | reverse
    | if $limit == "" then . else .[:($limit | tonumber)] end
  ' "$HISTORY_FILE")"

if [[ "$FILTERED_JSON" == '[]' ]]; then
  if (( JSON_OUTPUT )); then
    printf '[]\n'
  else
    printf 'No publish history found.\n'
  fi
  exit 0
fi

if (( JSON_OUTPUT )); then
  printf '%s\n' "$FILTERED_JSON" | jq .
  exit 0
fi

printf '%-10s %-20s %-20s %-10s %s\n' 'Version' 'Target' 'Date' 'State' 'Tag'
printf '%-10s %-20s %-20s %-10s %s\n' '-------' '------' '----' '-----' '---'
printf '%s\n' "$FILTERED_JSON" | jq -r '.[] | [(.version // "-"), (.target // "-"), (.timestamp // .completed_at // .started_at // "-"), (.platform_state // .state // "-"), (.git_tag // .version // "-")] | @tsv' | \
while IFS=$'\t' read -r version target date state tag; do
  printf '%-10s %-20s %-20s %-10s %s\n' "$version" "$target" "$date" "$state" "$tag"
done
