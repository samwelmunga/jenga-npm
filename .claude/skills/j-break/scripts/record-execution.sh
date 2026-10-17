#!/usr/bin/env bash
################################################################################
# record-execution.sh - append one terminal-status entry to the per-session
# execution ledger (E44_S09)
#
# Usage:
#   record-execution.sh ITEM_ID STATUS [--source do|do-bundle|dooo|jenga] [--session KEY]
#
#   ITEM_ID   matches ^E[0-9]+(_S[0-9]+(_T[0-9]+)?)?$
#   STATUS    one of: Passed, Passed with remarks, Failed, Merged
#   --source  where the status was written (default: do)
#   --session overrides the session key (default: scripts/checklist-marker.sh
#             session-key, the same key checkin-gate.sh and the tick store use)
#
# Appends exactly one line to <queue>/execution-ledger.jsonl:
#   {"ts":"<ISO 8601 UTC>","session_key":"<key>","item_id":"<id>","status":"<status>","source":"<source>"}
#
# The ledger lets `/break status` (render-execution-status.sh) tell work this
# session did from work that was already done before it started.
#
# APPEND-ONLY. The file is created when absent, written under
# scripts/with-lock.sh, and never truncated, rewritten or compacted. It lives
# in the queue directory, so it is gitignored (and blocklisted for the public
# mirror by the project/queue/ rule in .publicignore). Rotation is out of scope
# here and is a deferred follow-up: growth is bounded only by gitignore and by
# the renderer reading only lines for the current session key.
#
# A ledger problem must NEVER fail a task: any I/O, lock or session-key failure
# prints a warning on stderr and exits 0. Only a usage error is non-zero.
#
# Exit codes:
#   0  appended, or a ledger problem was warned about and skipped
#   2  usage error (bad or missing argument, invalid item id, non-terminal status)
################################################################################

set -o nounset

SCRIPT_NAME="record-execution.sh"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/../../.." && pwd)"

usage_err() { printf '%s: %s\n' "$SCRIPT_NAME" "$1" >&2; exit 2; }
warn() { printf '%s: warning: %s (ledger entry skipped, task unaffected)\n' "$SCRIPT_NAME" "$1" >&2; exit 0; }

resolve_helper() {
  local rel="$1" candidate
  for candidate in "$REPO_ROOT/$rel" "$REPO_ROOT/node_modules/@jenga-ai/agent/$rel"; do
    [ -f "$candidate" ] && { printf '%s' "$candidate"; return 0; }
  done
  return 1
}

case "${1:-}" in -h|--help|help) printf 'Usage: %s ITEM_ID STATUS [--source S] [--session KEY]\n' "$SCRIPT_NAME"; exit 0 ;; esac

ITEM_ID="${1:-}"; STATUS_ARG="${2:-}"
[ -n "$ITEM_ID" ] && [ -n "$STATUS_ARG" ] || usage_err "usage: $SCRIPT_NAME ITEM_ID STATUS [--source S] [--session KEY]"
shift 2
SOURCE="do"; SESSION_KEY=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --source)  [ "$#" -ge 2 ] || usage_err "--source needs a value"; SOURCE="$2"; shift 2 ;;
    --session) [ "$#" -ge 2 ] || usage_err "--session needs a value"; SESSION_KEY="$2"; shift 2 ;;
    *) usage_err "unknown argument: $1" ;;
  esac
done

printf '%s' "$ITEM_ID" | grep -Eq '^E[0-9]+(_S[0-9]+(_T[0-9]+)?)?$' || usage_err "invalid item id: $ITEM_ID"
case "$STATUS_ARG" in
  "Passed"|"Passed with remarks"|"Failed"|"Merged") ;;
  *) usage_err "status must be Passed, Passed with remarks, Failed or Merged, got: $STATUS_ARG" ;;
esac
case "$SOURCE" in
  do|do-bundle|dooo|jenga) ;;
  *) usage_err "--source must be do, do-bundle, dooo or jenga, got: $SOURCE" ;;
esac

command -v python3 >/dev/null 2>&1 || warn "python3 is not available"
RESOLVE_ROOT="$(resolve_helper scripts/resolve-root.sh)" || warn "could not locate scripts/resolve-root.sh"
QUEUE_DIR="$(bash "$RESOLVE_ROOT" get queue 2>/dev/null)" || warn "could not resolve the queue directory"
[ -n "$QUEUE_DIR" ] || warn "the queue directory resolved to an empty path"

if [ -z "$SESSION_KEY" ]; then
  MARKER="$(resolve_helper scripts/checklist-marker.sh)" || warn "could not locate scripts/checklist-marker.sh"
  SESSION_KEY="$(bash "$MARKER" session-key 2>/dev/null)" || warn "no session key could be resolved"
  [ -n "$SESSION_KEY" ] || warn "no session key could be resolved"
fi

LINE="$(python3 -c 'import json,sys,datetime
ts = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
print(json.dumps({"ts": ts, "session_key": sys.argv[1], "item_id": sys.argv[2], "status": sys.argv[3], "source": sys.argv[4]}, separators=(",", ":")))' \
  "$SESSION_KEY" "$ITEM_ID" "$STATUS_ARG" "$SOURCE" 2>/dev/null)" || warn "could not build the ledger line"
[ -n "$LINE" ] || warn "could not build the ledger line"

LEDGER="$QUEUE_DIR/execution-ledger.jsonl"
mkdir -p "$QUEUE_DIR" 2>/dev/null || warn "could not create $QUEUE_DIR"

LOCKER="$(resolve_helper scripts/with-lock.sh)" || warn "could not locate scripts/with-lock.sh"
bash "$LOCKER" "$LEDGER" -- sh -c 'printf "%s\n" "$1" >> "$2"' _ "$LINE" "$LEDGER" 2>/dev/null \
  || warn "could not append to $LEDGER"
exit 0
