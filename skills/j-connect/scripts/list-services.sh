#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# skills/j-connect/scripts/list-services.sh
#
# Enumerates the service descriptors on disk so the j.connect picker is built
# from data, never from a hardcoded list (E65_S02_T02).
#
# Usage:  list-services.sh [--descriptors-dir <dir>]...
#
#   --descriptors-dir <dir>  repeatable. Default (when none is given) is the
#                            `descriptors/` directory next to this script,
#                            resolved from the script's own location (not the
#                            cwd), so it also works from a .claude/skills/ mirror.
#                            Real service descriptors live there as <id>.json
#                            (see project/documentation/service-descriptor.md, "Where descriptors
#                            live").
#
# Output (stdout): ONE compact JSON object:
#   {"services":[{"id","name","file","mcp","requires","unresolved_requires"}],
#    "skipped":[{"file","reason"}]}
#
#   - Every *.json in every dir is checked with validate-descriptor.sh. Invalid
#     ones are NOT listed: they go in `skipped`, and a one-line notice naming
#     the file and the validator's first error goes to stderr (validator
#     messages name field paths, never values).
#   - A descriptor whose `id` differs from its filename stem is skipped; a
#     duplicate `id` across dirs keeps the first dir's entry and skips later ones.
#   - `mcp` is register_mcp.supported. `unresolved_requires` lists `requires`
#     ids with no valid <id>.json in the scanned dirs (informational only).
#   - `services` is sorted by id so picker numbering is stable.
#   - Only id, name, file, mcp, requires are ever printed.
#
# Exit: 0 (including an empty or missing DEFAULT directory: {"services":[],"skipped":[]});
#       2 on a usage error or an explicit --descriptors-dir that does not exist.
# Dependencies: jq only.
# -----------------------------------------------------------------------------
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VALIDATE="$SCRIPT_DIR/validate-descriptor.sh"

usage_err() { echo "list-services: $1" >&2; echo "Usage: $(basename "$0") [--descriptors-dir <dir>]..." >&2; exit 2; }

DIRS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --descriptors-dir) [ $# -ge 2 ] || usage_err "--descriptors-dir needs a value"; DIRS+=("$2"); shift 2 ;;
    -h|--help)         sed -n '/^# Usage:/,/^# Exit:/p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *)                 usage_err "unexpected argument: $1" ;;
  esac
done

command -v jq >/dev/null 2>&1 || usage_err "jq is required but not found on PATH"

EXPLICIT=1
if [ "${#DIRS[@]}" -eq 0 ]; then
  EXPLICIT=0
  DIRS=("$SCRIPT_DIR/../descriptors")
fi

# Resolve every dir to an absolute path up front; an explicit missing dir is a usage error.
ABS_DIRS=()
for d in "${DIRS[@]}"; do
  if [ -d "$d" ]; then
    ABS_DIRS+=("$(cd "$d" && pwd)")
  elif [ "$EXPLICIT" -eq 1 ]; then
    usage_err "descriptors dir not found: $d"
  fi
done

SERVICES=""      # newline-separated compact JSON objects
SKIPPED=""
RESOLVED=""      # newline-separated ids that have a valid <id>.json
SEEN_IDS=" "     # ids already listed (first dir wins)
declare -A SEEN_FILE

add_skipped() { # <file> <reason>
  SKIPPED="${SKIPPED}$(jq -cn --arg f "$1" --arg r "$2" '{file:$f, reason:$r}')"$'\n'
  echo "list-services: skipped $1: $2" >&2
}

for dir in ${ABS_DIRS[@]+"${ABS_DIRS[@]}"}; do
  for f in "$dir"/*.json; do
    [ -f "$f" ] || continue
    stem="$(basename "$f" .json)"
    if ! vout="$(bash "$VALIDATE" "$f" 2>&1 >/dev/null)"; then
      first="$(printf '%s\n' "$vout" | grep -m1 '^ERROR' || printf '%s\n' "$vout" | head -n1)"
      add_skipped "$f" "failed validation: $first"
      continue
    fi
    id="$(jq -r '.id' "$f")"
    if [ "$id" != "$stem" ]; then
      add_skipped "$f" "id '$id' does not match filename stem '$stem'"
      continue
    fi
    RESOLVED="${RESOLVED}${id}"$'\n'
    case "$SEEN_IDS" in
      *" $id "*) add_skipped "$f" "duplicate id '$id': already listed from ${SEEN_FILE[$id]}"; continue ;;
    esac
    SEEN_IDS="${SEEN_IDS}${id} "
    SEEN_FILE[$id]="$f"
    SERVICES="${SERVICES}$(jq -c --arg file "$f" \
      '{id, name, file:$file, mcp:(.register_mcp.supported == true), requires:(.requires // [])}' "$f")"$'\n'
  done
done

RESOLVED_JSON="$(printf '%s' "$RESOLVED" | jq -Rcn '[inputs | select(length > 0)]')"
SKIPPED_JSON="$(printf '%s' "$SKIPPED" | jq -cs '.')"

printf '%s' "$SERVICES" | jq -cs --argjson resolved "$RESOLVED_JSON" --argjson skipped "$SKIPPED_JSON" '
  {services: (sort_by(.id) | map(. + {unresolved_requires: [.requires[] | select(. as $r | $resolved | index($r) | not)]})),
   skipped: $skipped}'
exit 0
