#!/usr/bin/env bash
# scripts/events-append.sh — the one sanctioned way to add a record to the JSONL event log (E75_S01_T03).
#
# Usage:
#   scripts/events-append.sh [--file <path>] '<json-object>'
#   printf '%s' '<json-object>' | scripts/events-append.sh [--file <path>]
#
# Appends exactly ONE compact, ASCII-escaped line to the event log under scripts/with-lock.sh.
# Default target: "$(scripts/resolve-root.sh get logs)/events.json".
#
# Guarantees:
#   - The record must be a single JSON object; otherwise exit 3 and nothing is written.
#   - A target that exists but is not JSONL (array-shaped, or any non-empty line that is not a
#     one-line JSON object) is refused with exit 4 and left byte-identical.
#   - Never truncates or rewrites. Writes only with `>>`. A missing target is created; a last
#     line lacking its newline gets one before the new record, so records never merge.
#
# Exit codes: 0 appended, 2 usage, 3 invalid record, 4 target not JSONL, 5 no jq/python3,
#             other: with-lock.sh's own (2 = lock timeout, nothing written).
set -u

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FILE=""
RECORD=""
HAVE_RECORD=0
while [ $# -gt 0 ]; do
  case "$1" in
    --file) [ $# -ge 2 ] || { echo "events-append.sh: --file needs a path" >&2; exit 2; }; FILE="$2"; shift 2 ;;
    --) shift; if [ $# -gt 0 ]; then RECORD="$1"; HAVE_RECORD=1; shift; fi ;;
    *) if [ "$HAVE_RECORD" = 1 ]; then echo "events-append.sh: unexpected argument" >&2; exit 2; fi
       RECORD="$1"; HAVE_RECORD=1; shift ;;
  esac
done
if [ "$HAVE_RECORD" = 0 ]; then
  [ -t 0 ] && { echo "events-append.sh: usage: events-append.sh [--file <path>] '<json-object>'" >&2; exit 2; }
  RECORD="$(cat)"
fi

if [ -z "$FILE" ]; then
  LOGS="$("$SELF_DIR/resolve-root.sh" get logs 2>/dev/null)" || LOGS=""
  [ -n "$LOGS" ] || { echo "events-append.sh: cannot resolve the logs directory; pass --file" >&2; exit 2; }
  FILE="$LOGS/events.json"
fi

if command -v jq >/dev/null 2>&1; then ENGINE=jq
elif command -v python3 >/dev/null 2>&1; then ENGINE=py
else echo "events-append.sh: neither jq nor python3 is available" >&2; exit 5; fi

INNER=$(cat <<'EOS'
file="$1"; record="$2"; engine="$3"
# 1. Validate and compact the record: exactly one JSON object, one ASCII-only line.
if [ "$engine" = jq ]; then
  n=$(printf '%s' "$record" | jq -s 'length' 2>/dev/null) || n=0
  [ "$n" = 1 ] || { echo "events-append.sh: record is not a single JSON value" >&2; exit 3; }
  line=$(printf '%s' "$record" | jq -c -a -e 'if type=="object" then . else empty end' 2>/dev/null) \
    || { echo "events-append.sh: record is not a JSON object" >&2; exit 3; }
else
  line=$(printf '%s' "$record" | python3 -c '
import sys, json
try:
    v = json.loads(sys.stdin.read())
except Exception:
    sys.exit(1)
if not isinstance(v, dict):
    sys.exit(1)
print(json.dumps(v, separators=(",", ":"), ensure_ascii=True))') \
    || { echo "events-append.sh: record is not a single JSON object" >&2; exit 3; }
fi
# 2. Refuse a non-JSONL target.
if [ -s "$file" ]; then
  first=$(tr -d ' \t\r\n' < "$file" | head -c 1)
  if [ "$first" = "[" ]; then
    echo "events-append.sh: $file is array-shaped, not JSONL; run scripts/events-log-migrate.sh" >&2; exit 4
  fi
  if [ "$engine" = jq ]; then
    jq -R -n -e '[inputs | select(test("\\S")) | ((try fromjson catch null) | type == "object")] | all' < "$file" >/dev/null 2>&1
  else
    python3 -c '
import sys, json
for l in open(sys.argv[1], encoding="utf-8"):
    if l.strip():
        try:
            ok = isinstance(json.loads(l), dict)
        except Exception:
            ok = False
        if not ok:
            sys.exit(1)' "$file"
  fi || { echo "events-append.sh: $file holds a line that is not a one-line JSON object; refusing" >&2; exit 4; }
fi
# 3. Append only. Terminate an unterminated last line first.
mkdir -p "$(dirname "$file")" || exit 1
if [ -s "$file" ] && [ "$(tail -c 1 "$file" | od -An -c | tr -d ' ')" != '\n' ]; then
  printf '\n' >> "$file" || exit 1
fi
printf '%s\n' "$line" >> "$file"
EOS
)

mkdir -p "$(dirname "$FILE")" || exit 1
exec "$SELF_DIR/with-lock.sh" "$FILE" -- bash -c "$INNER" _ "$FILE" "$RECORD" "$ENGINE"
