#!/usr/bin/env bash
# completed-statuses.sh -- the single owner of /j-reconcile's completion-state vocabulary (E17_S10).
#
# /j-reconcile branches on "is this item completed?" in Phases 2, 3, 4 and 6. That vocabulary used to be
# a hand-typed literal in SKILL.md that omitted the script-set ladder statuses (Merged, Publicized,
# Privatized, Deployed to Stage, Deployed to Prod), so a Merged ticket was treated as incomplete and
# Phase 3 "promoted" it back to Passed. This script derives the vocabulary from the schema instead.
#
# Source of truth: the backticked status names in the `## Status Values` table of
# templates/SCRUM_BOARD_SCHEMA.md. Every status in that table is placed in exactly one class:
#
#   incomplete  pinned literal below  -- not finished (Pending, In Progress, Failed, ...)
#   completed   pinned literal below  -- finished by the tester/scrum master (Done, Passed, Passed with remarks)
#   ladder      DERIVED               -- every other status in the table: the script-set statuses that sit
#                                        *after* Passed. Completed-and-beyond: never promoted, never demoted.
#
# The open-ended class (ladder) is derived, so a status added to the schema table is picked up with no edit
# here. The two pinned classes are the stable core; they are cross-checked against the schema on every run.
#
# Usage:
#   completed-statuses.sh [--schema <path>]
#       Print one JSON object: {"completed":[...],"ladder":[...],"incomplete":[...]}
#   completed-statuses.sh [--schema <path>] --classify "<status>"
#       Print completed | ladder | incomplete | unknown. `unknown` = not in the schema (a typo, or the
#       retired "Running"); callers treat it as incomplete, exactly as before this script existed.
#
# "Completed-or-beyond" (what the skill tests) = completed + ladder.
#
# Exit codes:
#   0  ok
#   2  usage error, or the schema file could not be found
#   3  vocabulary drift: a pinned status is no longer in the schema's Status Values table
#   4  the Status Values table could not be parsed (no rows found)
#
# Bash 3.2 compatible (macOS): awk/sed only, no associative arrays, no `timeout`.

set -u

# Pinned literals. Keep these two lines as the ONLY hand-maintained status names for reconcile.
INCOMPLETE_STATUSES="Pending|In Progress|Failed|Rejected|Blocked|Backlog"
COMPLETED_STATUSES="Done|Passed|Passed with remarks"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

schema=""
classify=""
have_classify=0
while [ $# -gt 0 ]; do
  case "$1" in
    --schema)
      [ $# -ge 2 ] || { echo "completed-statuses.sh: --schema needs a path" >&2; exit 2; }
      schema="$2"; shift 2 ;;
    --classify)
      [ $# -ge 2 ] || { echo "completed-statuses.sh: --classify needs a status" >&2; exit 2; }
      classify="$2"; have_classify=1; shift 2 ;;
    -h|--help)
      sed -n '2,/^# Bash 3.2/p' "$0" | sed 's/^# \{0,1\}//'
      exit 0 ;;
    *)
      echo "completed-statuses.sh: unknown argument: $1" >&2; exit 2 ;;
  esac
done

if [ -z "$schema" ]; then
  # Relative to this script first (repo root, .claude/ and .agents/ mirrors, node_modules install),
  # then the same cwd fallbacks the agent definitions use.
  for candidate in \
    "$SCRIPT_DIR/../../../templates/SCRUM_BOARD_SCHEMA.md" \
    "templates/SCRUM_BOARD_SCHEMA.md" \
    "node_modules/@jenga-ai/agent/templates/SCRUM_BOARD_SCHEMA.md"; do
    if [ -f "$candidate" ]; then schema="$candidate"; break; fi
  done
fi

if [ -z "$schema" ] || [ ! -f "$schema" ]; then
  echo "completed-statuses.sh: cannot find templates/SCRUM_BOARD_SCHEMA.md${schema:+ (tried: $schema)}" >&2
  exit 2
fi

# Backticked first cell of every table row inside the `## Status Values` section, in table order.
all_statuses="$(awk '
  /^## Status Values[[:space:]]*$/ { in_sec = 1; next }
  in_sec && /^#/                   { exit }
  in_sec && /^\| *`/ {
    s = $0
    sub(/^\| *`/, "", s)
    sub(/`.*/, "", s)
    print s
  }
' "$schema")"

if [ -z "$all_statuses" ]; then
  echo "completed-statuses.sh: no status rows found under '## Status Values' in $schema" >&2
  exit 4
fi

in_list() { # in_list <status> <pipe-separated list>
  local needle="$1" list="$2" item old_ifs="$IFS"
  IFS='|'
  for item in $list; do
    if [ "$item" = "$needle" ]; then IFS="$old_ifs"; return 0; fi
  done
  IFS="$old_ifs"
  return 1
}

in_schema() { printf '%s\n' "$all_statuses" | grep -Fxq -- "$1"; }

# Drift guard: every pinned status must still exist in the schema table.
old_ifs="$IFS"; IFS='|'
for pinned in $INCOMPLETE_STATUSES $COMPLETED_STATUSES; do
  if ! in_schema "$pinned"; then
    IFS="$old_ifs"
    echo "completed-statuses.sh: vocabulary drift: pinned status '$pinned' is not in the Status Values table of $schema" >&2
    exit 3
  fi
done
IFS="$old_ifs"

class_of() {
  if in_list "$1" "$COMPLETED_STATUSES"; then echo completed
  elif in_list "$1" "$INCOMPLETE_STATUSES"; then echo incomplete
  elif in_schema "$1"; then echo ladder
  else echo unknown
  fi
}

if [ "$have_classify" -eq 1 ]; then
  class_of "$classify"
  exit 0
fi

completed_json=""; ladder_json=""; incomplete_json=""
append() { # append <current> <name>
  if [ -z "$1" ]; then printf '"%s"' "$2"; else printf '%s,"%s"' "$1" "$2"; fi
}
while IFS= read -r s; do
  [ -n "$s" ] || continue
  case "$(class_of "$s")" in
    completed)  completed_json="$(append "$completed_json" "$s")" ;;
    ladder)     ladder_json="$(append "$ladder_json" "$s")" ;;
    incomplete) incomplete_json="$(append "$incomplete_json" "$s")" ;;
  esac
done <<EOF
$all_statuses
EOF

printf '{"completed":[%s],"ladder":[%s],"incomplete":[%s]}\n' "$completed_json" "$ladder_json" "$incomplete_json"
