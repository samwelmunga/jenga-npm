#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# skills/j-playbook/scripts/playbook-list.sh
#
# The deterministic half of `j.playbook`'s bare and numeric invocations (E53_S06_T07). Built on
# `skills/jenga/scripts/load-playbooks.sh`'s existing full-catalog output, so the listing and the
# number-to-id resolution below share one ordering by construction: both read the same catalog
# array in the same order, and neither sorts.
#
# USAGE
#   playbook-list.sh render           print the catalog as a ranked_list, one line per playbook
#   playbook-list.sh resolve <n>      print the id of the n-th playbook of that same listing
#
# OUTPUT (render) -- the `ranked_list` object type of templates/playbook-types.json, 1-indexed:
#   <n>. <id> — <name> (<built-in|project>) · steps: <step> -> <step> -> ...
# No header, no trailing menu line. A bare-string step renders as itself; a StepObject step renders
# its `skill` or `playbook` field. An empty catalog prints nothing and exits 0.
#
# OUTPUT (resolve) -- the bare id on stdout.
#
# EXIT CODES
#   0   success
#   1   `resolve` argument is not a positive integer, or is outside 1..count (the valid range is
#       reported on stderr)
#   2   usage error, `jq` missing, or the catalog loader failed
#
# ENVIRONMENT
#   JENGA_PLAYBOOK_LOADER   path to a catalog loader to use instead of load-playbooks.sh. Test hook:
#                           it must print the same JSON array the real loader prints.
# ---------------------------------------------------------------------------

set -euo pipefail
export LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOADER="${JENGA_PLAYBOOK_LOADER:-$SCRIPT_DIR/../../jenga/scripts/load-playbooks.sh}"

usage() {
  echo 'Usage: playbook-list.sh render | playbook-list.sh resolve <n>' >&2
  exit 2
}

command -v jq >/dev/null 2>&1 || { echo "playbook-list.sh: jq is required" >&2; exit 2; }
[ $# -ge 1 ] || usage

catalog() {
  local out
  if ! out="$(bash "$LOADER")"; then
    echo "playbook-list.sh: the playbook catalog loader failed" >&2
    exit 2
  fi
  printf '%s' "$out"
}

case "$1" in
  render)
    [ $# -eq 1 ] || usage
    catalog | jq -r '
      to_entries[]
      | "\(.key + 1). \(.value.id) — \(.value.name) (\(if .value.source == "project" then "project" else "built-in" end)) · steps: \(
          .value.steps | map(if type == "string" then . else (.skill // .playbook // "?") end) | join(" -> ")
        )"'
    ;;
  resolve)
    [ $# -eq 2 ] || usage
    n="$2"
    count="$(catalog | jq 'length')"
    if ! [[ "$n" =~ ^[0-9]+$ ]] || [ "$n" -lt 1 ] || [ "$n" -gt "$count" ]; then
      if [ "$count" -eq 0 ]; then
        echo "playbook-list.sh: '$n' is not a valid playbook number; the catalog is empty" >&2
      else
        echo "playbook-list.sh: '$n' is not a valid playbook number; the valid range is 1-$count" >&2
      fi
      exit 1
    fi
    catalog | jq -r --argjson i "$((n - 1))" '.[$i].id'
    ;;
  *)
    usage
    ;;
esac
