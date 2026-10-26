#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# scripts/audit-status.sh - latest dependency-audit result per directory (epic E85, task E85_S01_T11)
#
# The monitoring surface /j-status shows. Read-only: it never runs an audit, never calls npm and never
# writes a file. It reads the audit_result events that scripts/audit-record.sh appends to the event log
# (path from `scripts/resolve-root.sh get logs`, honours JENGA_PROJECT_ROOT) and prints, for each distinct
# scanned_dir, only the most recent one.
#
# USAGE
#   audit-status.sh
#   audit-status.sh -h | --help
#
# OUTPUT (stdout; one line per directory, plus a rapport line for a findings result)
#   Dependency audit: no audit recorded            no audit_result event at all; when audit-config.json
#                                                  says mode off or ask (or is absent) a second line says
#                                                  audits are opt-in and names `jenga config set`
#   Dependency audit: <dir> - <status> (threshold <t>; total N: low a, moderate b, high c, critical d), <n> day(s) old
#                                                  " (stale)" is appended when the result is over 14 days old;
#                                                  the counts group is printed for clean and findings only
#     rapport: <path>                              findings only: the rapport named by the event if it still
#                                                  exists, else the newest audit-*.md rapport naming the dir
#
# The event log is JSONL; lines that are not JSON objects (a torn last line) are skipped silently.
# EXIT CODES: 0 always on a normal run (a missing or empty log is "no audit recorded"); 2 on a bad argument;
#             3 when jq is missing or a path cannot be resolved.
# Compatible with macOS bash 3.2. Uses jq.
# ---------------------------------------------------------------------------

set -u
SELF="audit-status.sh"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STALE_DAYS=14
US=$'\037'

case "${1:-}" in
  "") ;;
  -h|--help) sed -n '2,/^# -----*$/p' "$0" | sed -e '$d' -e 's/^# \{0,1\}//'; exit 0 ;;
  *) printf '%s: unknown argument: %s\n' "$SELF" "$1" >&2; exit 2 ;;
esac

command -v jq >/dev/null 2>&1 || { printf '%s: jq is required\n' "$SELF" >&2; exit 3; }
LOGS="$("$SCRIPT_DIR/resolve-root.sh" get logs 2>/dev/null)" && [ -n "$LOGS" ] \
  || { printf '%s: cannot resolve the logs directory\n' "$SELF" >&2; exit 3; }
EVENTS="$LOGS/events.json"

rows=""
[ -f "$EVENTS" ] && rows="$(jq -R -n -r --argjson stale "$STALE_DAYS" --arg us "$US" '
  [inputs | fromjson? | select(type == "object" and .event == "audit_result")]
  | group_by(.scanned_dir // "") | map(max_by(.date // ""))[]
  | (try ((now - (.date | fromdateiso8601)) / 86400 | floor) catch null) as $age
  | (.counts // {}) as $c
  | [(.scanned_dir // "(unknown directory)"), (.status // "unknown"), (.threshold // "none"),
     ($age // ""), (if $age != null and $age > $stale then "stale" else "" end),
     ($c.total // 0), ($c.low // 0), ($c.moderate // 0), ($c.high // 0), ($c.critical // 0), (.rapport // "")]
  | map(tostring) | join($us)' "$EVENTS" 2>/dev/null)"

if [ -z "$rows" ]; then
  echo "Dependency audit: no audit recorded"
  CONFIGS="$("$SCRIPT_DIR/resolve-root.sh" get configs 2>/dev/null)"
  MODE="$(jq -r '.mode // "ask"' "$CONFIGS/audit-config.json" 2>/dev/null)"
  case "${MODE:-ask}" in
    off|ask) echo "  Audits are opt-in (mode: ${MODE:-ask}). To allow them without a prompt each time: jenga config set audit-config.mode on" ;;
  esac
  exit 0
fi

RAPPORTS="$("$SCRIPT_DIR/resolve-root.sh" get rapports_problems 2>/dev/null)"
while IFS="$US" read -r dir status threshold age stale total low moderate high critical rapport; do
  line="Dependency audit: $dir - $status (threshold $threshold"
  case "$status" in clean|findings) line="$line; total $total: low $low, moderate $moderate, high $high, critical $critical" ;; esac
  line="$line)"
  if [ -n "$age" ]; then
    if [ "$age" = 1 ]; then line="$line, 1 day old"; else line="$line, $age days old"; fi
  else
    line="$line, age unknown"
  fi
  [ -n "$stale" ] && line="$line (stale)"
  echo "$line"
  if [ "$status" = findings ]; then
    if [ -n "$rapport" ] && [ -f "$rapport" ]; then
      echo "  rapport: $rapport"
    elif [ -n "$RAPPORTS" ] && [ -d "$RAPPORTS" ]; then
      found="$(ls -t "$RAPPORTS"/audit-*.md 2>/dev/null | while IFS= read -r f; do
        grep -qF "audit of \`$dir\`" "$f" 2>/dev/null && { echo "$f"; break; }; done)"
      [ -n "$found" ] && echo "  rapport: $found"
    fi
  fi
done <<EOF_ROWS
$rows
EOF_ROWS
exit 0
