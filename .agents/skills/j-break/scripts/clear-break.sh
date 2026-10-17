#!/usr/bin/env bash
################################################################################
# clear-break.sh — remove the break flag
#
# The only thing that ends a HARD break. `/break clear` dispatches here.
#
# Usage:
#   clear-break.sh
#
# CLEARING A BREAK THAT IS NOT SET IS A SUCCESS, NOT AN ERROR. It exits 0 either
# way and says which happened. The operator's intent — "no break should be
# standing when I am done here" — is satisfied in both cases, and a non-zero
# exit would make `/break clear` look like it failed when it had nothing to do.
# It is therefore safe to call unconditionally, including from a cleanup path.
#
# Exit codes:
#   0  no break is standing (whether or not one was removed)
#   2  usage error
#   3  the queue directory could not be resolved
#   5  a flag exists but could not be removed
#
################################################################################

set -o errexit
set -o nounset

SCRIPT_NAME="clear-break.sh"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/../../.." && pwd)"

err() { printf '%s: %s\n' "$SCRIPT_NAME" "$1" >&2; }
usage() { printf 'Usage: %s\n' "$SCRIPT_NAME" >&2; }

resolve_helper() {
  local rel="$1" candidate
  for candidate in "$REPO_ROOT/$rel" "$REPO_ROOT/node_modules/@jenga-ai/agent/$rel"; do
    if [ -f "$candidate" ]; then
      printf '%s' "$candidate"
      return 0
    fi
  done
  return 1
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    -h|--help|help) usage; exit 0 ;;
    *) err "unknown argument: $1"; usage; exit 2 ;;
  esac
done

RESOLVE_ROOT="$(resolve_helper scripts/resolve-root.sh)" || {
  err "could not locate scripts/resolve-root.sh"
  exit 3
}

QUEUE_DIR=""
if ! QUEUE_DIR="$(bash "$RESOLVE_ROOT" get queue 2>/dev/null)"; then
  err "could not resolve the queue directory"
  exit 3
fi
[ -n "$QUEUE_DIR" ] || { err "the queue directory resolved to an empty path"; exit 3; }

FLAG="$QUEUE_DIR/.break_request.json"

# A queue directory that does not exist cannot hold a flag. Not an error: the
# steady state of this file is absence.
if [ ! -e "$FLAG" ]; then
  printf 'no break was set — nothing to clear\n'
  exit 0
fi

# Report what is being removed before removing it. The mode is best-effort: a
# corrupt flag is still cleared, since clearing is exactly how an operator gets
# rid of one.
MODE="unknown"
if command -v python3 >/dev/null 2>&1; then
  MODE="$(python3 -c '
import json, sys
try:
    with open(sys.argv[1], encoding="utf-8") as fh:
        record = json.load(fh)
    mode = record.get("mode") if isinstance(record, dict) else None
    print(mode if mode in ("soft", "hard") else "unparseable")
except Exception:
    print("unparseable")
' "$FLAG" 2>/dev/null)" || MODE="unknown"
fi
[ -n "$MODE" ] || MODE="unknown"

if ! rm -f "$FLAG"; then
  err "could not remove $FLAG"
  exit 5
fi

printf 'break cleared: a %s break was standing and has been removed\n' "$MODE"
exit 0
