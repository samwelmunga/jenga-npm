#!/usr/bin/env bash
# E90_S03_T01: read-only usage-coverage counter for the board's task files.
#
# Usage: task-usage-coverage.sh [--list] [--out <file>] [--board-tasks-dir <dir>]
#
# Prints JSON on stdout and a short human summary on stderr:
#   total               number of task files (*.md) in the tasks directory
#   measured            tasks with a numeric usage_total_tokens (an explicit 0 counts as measured)
#   unmeasured          tasks with none of the usage_* raw token fields
#   unreadable          files that cannot be parsed with certainty (no frontmatter, no id, a non-numeric
#                       usage_total_tokens, or raw usage fields without usage_total_tokens)
#   possibly_incomplete subset of measured carrying usage_possibly_incomplete: true (NOT a third bucket)
#   without_cost_units  subset of measured lacking usage_cost_units
#   invariant: measured + unmeasured + unreadable = total
# --list adds "unmeasured_ids" (numerically sorted, E99 before E100). --out writes the same JSON to a file.
# The tasks directory comes from scripts/resolve-root.sh unless --board-tasks-dir is given. Never writes to the board.
# Exit codes: 0 ok, 2 usage error, 3 environment error (tasks directory missing or --out not writable).
set -u
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

LIST=0; OUT=""; DIR=""
while [ $# -gt 0 ]; do
  case "$1" in
    --list) LIST=1 ;;
    --out) [ $# -ge 2 ] || { echo "--out requires a value" >&2; exit 2; }; OUT="$2"; shift ;;
    --board-tasks-dir) [ $# -ge 2 ] || { echo "--board-tasks-dir requires a value" >&2; exit 2; }; DIR="$2"; shift ;;
    -h|--help) sed -n '2,19p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
  shift
done

if [ -z "$DIR" ]; then
  DIR="$(bash "$here/resolve-root.sh" get tasks 2>/dev/null)" || DIR=""
fi
[ -n "$DIR" ] && [ -d "$DIR" ] || { echo "tasks directory not found: ${DIR:-<unresolved>}" >&2; exit 3; }

files="$(find "$DIR" -maxdepth 1 -type f -name '*.md' | sort)"
total=0
[ -n "$files" ] && total="$(printf '%s\n' "$files" | wc -l | tr -d ' ')"

# One awk process over every file; prints "<class>\t<id>\t<incomplete 0|1>\t<lacks cost units 0|1>" per file.
result=""
if [ -n "$files" ]; then
  result="$(printf '%s\n' "$files" | tr '\n' '\0' | xargs -0 awk '
  function flush(   cls) {
    if (file == "") return
    if (!closed || id == "") cls = "unreadable"
    else if (tot_present) cls = tot_ok ? "measured" : "unreadable"
    else if (raw_any) cls = "unreadable"
    else cls = "unmeasured"
    print cls "\t" id "\t" inc "\t" nocost
  }
  FNR == 1 { flush(); file = FILENAME; infm = ($0 == "---"); closed = 0; id = ""; tot_present = 0; tot_ok = 0
             raw_any = 0; inc = 0; nocost = 1; next }
  infm && !closed {
    if ($0 == "---") { closed = 1; next }
    if (match($0, /^[A-Za-z_]+:/)) {
      k = substr($0, 1, RLENGTH - 1); v = substr($0, RLENGTH + 1)
      gsub(/^[ \t]+|[ \t\r]+$/, "", v); gsub(/^"|"$/, "", v)
      if (k == "id") id = v
      else if (k == "usage_total_tokens" && v != "") { tot_present = 1; if (v ~ /^[0-9]+$/) tot_ok = 1 }
      else if (k ~ /^usage_(input|output|cache_write|cache_read)_tokens$/ && v != "") raw_any = 1
      else if (k == "usage_possibly_incomplete" && v == "true") inc = 1
      else if (k == "usage_cost_units" && v ~ /^[0-9]+$/) nocost = 0
    }
  }
  END { flush() }
  ')"
fi

count() { printf '%s\n' "$result" | awk -F'\t' -v c="$1" '$1==c' | wc -l | tr -d ' '; }
measured="$(count measured)"; unmeasured="$(count unmeasured)"; unreadable="$(count unreadable)"
possibly="$(printf '%s\n' "$result" | awk -F'\t' '$1=="measured" && $3==1' | wc -l | tr -d ' ')"
nocost="$(printf '%s\n' "$result" | awk -F'\t' '$1=="measured" && $4==1' | wc -l | tr -d ' ')"

extra=""
if [ "$LIST" -eq 1 ]; then
  ids_json="$(printf '%s\n' "$result" | awk -F'\t' '$1=="unmeasured" {print $2}' \
    | awk '{ s = $0; gsub(/[^0-9]+/, " ", s); split(s, n, " "); printf "%06d%06d%06d\t%s\n", n[1], n[2], n[3], $0 }' \
    | sort | cut -f2 | awk 'BEGIN{printf "["} {printf "%s\"%s\"", (NR>1?",":""), $0} END{printf "]"}')"
  extra=",\"unmeasured_ids\":$ids_json"
fi

json="$(printf '{"total":%s,"measured":%s,"unmeasured":%s,"unreadable":%s,"possibly_incomplete":%s,"without_cost_units":%s,"note":"measured + unmeasured + unreadable = total; possibly_incomplete and without_cost_units are subsets of measured"%s}' \
  "$total" "$measured" "$unmeasured" "$unreadable" "$possibly" "$nocost" "$extra")"

printf '%s\n' "$json"
printf 'usage coverage: %s tasks = %s measured + %s unmeasured + %s unreadable (of the measured: %s possibly incomplete, %s without cost units)\n' \
  "$total" "$measured" "$unmeasured" "$unreadable" "$possibly" "$nocost" >&2
if [ -n "$OUT" ]; then
  { mkdir -p "$(dirname "$OUT")" && printf '%s\n' "$json" > "$OUT"; } || { echo "cannot write $OUT" >&2; exit 3; }
fi
exit 0
