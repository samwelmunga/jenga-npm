#!/usr/bin/env bash
# scripts/progress-labels-json.sh - print the progress label table as JSON (epic E92, task E92_S06_T03).
#
# Usage: bash scripts/progress-labels-json.sh
# Prints {"lang":"<effective lang>","labels":{"<key>":"<text>",...}} for every key in PROGRESS_LABEL_KEYS, in key
# order. Honours JENGA_PROGRESS_LANG. Format strings keep their % placeholders raw. No model call, no jq.
# Sourced-for-test mode: `--source-only` defines json_escape and prints nothing.

_pl_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/progress-labels.sh
. "$_pl_dir/lib/progress-labels.sh"

# json_escape <text>: escape a string for use inside a JSON string literal.
json_escape() {
  local s="$1" out="" c i code
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  for ((i = 0; i < ${#s}; i++)); do
    c="${s:i:1}"
    case "$c" in
      $'\n') out+='\n' ;;
      $'\r') out+='\r' ;;
      $'\t') out+='\t' ;;
      $'\b') out+='\b' ;;
      $'\f') out+='\f' ;;
      *)
        code=$(LC_ALL=C printf '%d' "'$c" 2>/dev/null || echo 32)
        if [ "$code" -ge 0 ] && [ "$code" -lt 32 ]; then
          out+="$(printf '\\u%04x' "$code")"
        else
          out+="$c"
        fi
        ;;
    esac
  done
  printf '%s' "$out"
}

progress_labels_json() {
  local lang k first=1 text
  lang="$(progress_lang)"
  printf '{"lang":"%s","labels":{' "$(json_escape "$lang")"
  for k in $PROGRESS_LABEL_KEYS; do
    text="$(progress_label "$k" "$lang")" || text=""
    [ "$first" -eq 1 ] || printf ','
    first=0
    printf '"%s":"%s"' "$(json_escape "$k")" "$(json_escape "$text")"
  done
  printf '}}\n'
}

if [ "${1-}" != "--source-only" ]; then
  progress_labels_json
fi
