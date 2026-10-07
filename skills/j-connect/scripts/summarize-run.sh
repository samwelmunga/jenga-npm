#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# skills/j-connect/scripts/summarize-run.sh
#
# Turns run-descriptor.sh's JSON lines into the user-facing j.connect report
# (E65_S02_T03). Deterministic, jq only; no detection is re-implemented here:
# "already installed" / "already authenticated" are the runner's own `skipped`
# reasons, relayed verbatim.
#
# Usage:  summarize-run.sh [<results-file>]     (reads stdin when omitted or "-")
#
# Report (plain text, stdout):
#   [PASS|FAIL|SKIPPED|ACTION] <step> - <message>     one line per step; steps of
#                                                     a `requires` prerequisite
#                                                     are shown as <id>/<step>
#   Skipped (nothing to do):    each skipped step with its reason (omitted if none)
#   Needs your action:          each needs-user-action step, message verbatim
#   <final line>                derived ONLY from the top-level descriptor's own
#                               `verify` step:
#                                 VERIFIED: <descriptor>                  verify = pass
#                                 NOT VERIFIED: verification failed       verify = fail
#                                 NOT VERIFIED: verification did not run (stopped at <step>)
#                                                                         no verify result, or it was skipped
#                               The runner's summary `status`, and a `skipped`
#                               verify, never produce VERIFIED.
#
# Non-JSON (or non-object / unrecognised) input lines are ignored with a stderr
# notice and never appear in the report. Only the descriptor id, step, status
# and message fields the runner emitted are ever printed.
#
# Exit: 1 if any step failed; else 3 if any step is waiting on a user action;
#       else 0 only when VERIFIED; else 1. 2 on a usage error / unreadable file.
# Dependencies: jq only.
# -----------------------------------------------------------------------------
set -uo pipefail

usage_err() { echo "summarize-run: $1" >&2; echo "Usage: $(basename "$0") [<results-file>]" >&2; exit 2; }

SRC=""
while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) sed -n '/^# Usage:/,/^# Exit:/p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    -) [ -z "$SRC" ] || usage_err "unexpected argument: $1"; SRC="-"; shift ;;
    -*) usage_err "unknown option: $1" ;;
    *) [ -z "$SRC" ] || usage_err "unexpected argument: $1"; SRC="$1"; shift ;;
  esac
done
command -v jq >/dev/null 2>&1 || usage_err "jq is required but not found on PATH"
if [ -n "$SRC" ] && [ "$SRC" != "-" ]; then
  [ -f "$SRC" ] && [ -r "$SRC" ] || usage_err "results file not readable: $SRC"
fi

# Keep only lines that parse as JSON objects; notify (line number only) about the rest.
OBJS=""
n=0
read_lines() {
  local line
  while IFS= read -r line || [ -n "$line" ]; do
    n=$((n + 1))
    [ -n "$line" ] || continue
    if obj="$(printf '%s' "$line" | jq -ce 'select(type == "object")' 2>/dev/null)" && [ -n "$obj" ]; then
      OBJS="${OBJS}${obj}"$'\n'
    else
      echo "summarize-run: ignored non-JSON line $n" >&2
    fi
  done
}
if [ -z "$SRC" ] || [ "$SRC" = "-" ]; then read_lines; else read_lines < "$SRC"; fi

RESULT="$(printf '%s' "$OBJS" | jq -cs '
  def known: IN("pass", "fail", "skipped", "needs-user-action");
  def tag: if . == "pass" then "PASS" elif . == "fail" then "FAIL" elif . == "skipped" then "SKIPPED" else "ACTION" end;
  [ .[] | select((.step | type) == "string" and (.status | type) == "string" and (.status | known)) ] as $steps
  | ([ .[] | select(.summary == true) ] | first) as $sum
  | ($sum.descriptor // ($steps | last | .descriptor)) as $top
  | def nm: if (.descriptor == null) or (.descriptor == $top) then .step else "\(.descriptor)/\(.step)" end;
    def msg: (.message // "") | tostring;
    ($steps | map(select(.step == "verify" and ((.descriptor == null) or (.descriptor == $top)))) | last) as $verify
  | (($steps | map(select(.status == "fail" or .status == "needs-user-action")) | first) // ($steps | last)) as $stop
  | ($steps | any(.status == "fail")) as $anyfail
  | ($steps | any(.status == "needs-user-action")) as $anyneeds
  | ( if $verify.status == "pass" then "VERIFIED: \($top)"
      elif $verify.status == "fail" then "NOT VERIFIED: verification failed"
      else "NOT VERIFIED: verification did not run (stopped at \(if $stop == null then "start" else ($stop | nm) end))" end ) as $final
  | ( [ $steps[] | "[\(.status | tag)] \(nm) - \(msg)" ]
      + ( [ $steps[] | select(.status == "skipped") | "  - \(nm): \(msg)" ] | if length > 0 then ["", "Skipped (nothing to do):"] + . else [] end )
      + ( [ $steps[] | select(.status == "needs-user-action") | "  - \(nm): \(msg)" ] | if length > 0 then ["", "Needs your action:"] + . else [] end )
      + ["", $final] ) as $lines
  | { lines: $lines,
      code: ( if $anyfail then 1 elif $anyneeds then 3 elif ($verify.status == "pass") then 0 else 1 end ) }
')" || { echo "summarize-run: could not process input" >&2; exit 1; }

jq -r '.lines[]' <<<"$RESULT"
exit "$(jq -r '.code' <<<"$RESULT")"
