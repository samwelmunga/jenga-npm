#!/usr/bin/env bash
################################################################################
# check-break.sh — the single break consumption point
#
# Every orchestration loop calls this at its task boundary: `/do` step 8, the
# story-bundle inner loop, `/dooo` before dispatching the next wave, `/jenga`
# Phase 4 after each wave. It is the ONLY place the consume-and-clear rule is
# implemented, so no orchestrator ever parses the flag itself. If you find
# yourself reading .break_request.json anywhere else, that is the bug.
#
# Usage:
#   check-break.sh [--peek]
#
#   --peek  report the flag state WITHOUT consuming a soft break. `/break
#           status` and any diagnostic needs this: reading the state must not
#           steal the break from the loop it was meant for.
#
# ---------------------------------------------------------------------------
# EXIT CODES — note that a break is 10, not 1
#   0   no break (also: a corrupt flag, see below). Print nothing.
#   10  a break is requested. The record is on stdout.
#   2   usage error
#   3   the queue directory could not be resolved
#
# 10 rather than 1 so that a calling loop running under `set -e` can tell "a
# break was requested" from "the script itself failed". Collapsing those onto 1
# would make a broken script look like a stop request, which halts the board for
# the wrong reason and looks identical to the right one.
#
# ---------------------------------------------------------------------------
# THE FAST PATH IS THE POINT
# No flag means exit 0 immediately: one existence test, no interpreter, no JSON
# parsing, no board read. That is the overwhelmingly common case — this runs at
# every task boundary of every loop, so the cost of "nothing is happening" has
# to be approximately zero. Nothing may be added above the existence test.
#
# ---------------------------------------------------------------------------
# CONSUMPTION, WHICH IS THE WHOLE DIFFERENCE BETWEEN THE TWO MODES
#   soft  consumed here: the record is emitted FIRST, then the flag is deleted.
#         One-shot — "let me look at this one thing". The next loop runs
#         normally. Emitting before deleting matters: if the delete fails, the
#         caller has still been told to halt, which is the safe order.
#   hard  left in place. Every subsequent call keeps exiting 10 until
#         clear-break.sh removes it. "Nobody runs the board until I say so."
#
# ---------------------------------------------------------------------------
# A CORRUPT FLAG IS "NO BREAK", AND IS NEVER DELETED
# An unparseable or malformed flag exits 0 with a warning on stderr, and leaves
# the file alone. Two deliberate choices:
#   - Exit 0, because a single corrupt file must not be able to wedge every
#     orchestration on the board. Failing closed here would turn one bad write
#     into a repository-wide halt with no obvious cause.
#   - Do not delete it, because the operator needs to see it. Silently removing
#     evidence of a bad write is how the same bug happens twice.
#
################################################################################

set -o errexit
set -o nounset

SCRIPT_NAME="check-break.sh"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/../../.." && pwd)"

err() { printf '%s: %s\n' "$SCRIPT_NAME" "$1" >&2; }
usage() { printf 'Usage: %s [--peek]\n' "$SCRIPT_NAME" >&2; }

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

PEEK="false"
while [ "$#" -gt 0 ]; do
  case "$1" in
    --peek) PEEK="true"; shift ;;
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

# ---- THE FAST PATH. Nothing above this line parses anything. ----------------
[ -e "$FLAG" ] || exit 0

# ---- A flag exists. Only now is it worth starting an interpreter. -----------
if ! command -v python3 >/dev/null 2>&1; then
  err "warning: a break flag exists at $FLAG but python3 is unavailable to read it; reporting no break"
  exit 0
fi

set +o errexit
RECORD="$(python3 - "$FLAG" <<'PY'
import json
import sys

flag = sys.argv[1]
VALID_MODES = ("soft", "hard")

try:
    with open(flag, encoding="utf-8") as fh:
        record = json.load(fh)
except (OSError, ValueError) as exc:
    print(f"unreadable or unparseable: {exc}", file=sys.stderr)
    sys.exit(1)

if not isinstance(record, dict):
    print("not a JSON object", file=sys.stderr)
    sys.exit(1)

mode = record.get("mode")
if mode not in VALID_MODES:
    print(f"mode is {mode!r}, expected 'soft' or 'hard'", file=sys.stderr)
    sys.exit(1)

with_status = record.get("with_status")
if not isinstance(with_status, bool):
    print(f"with_status is {with_status!r}, expected a boolean", file=sys.stderr)
    sys.exit(1)

requested_at = record.get("requested_at") or "unknown"
requested_by = record.get("requested_by") or "unknown"

print(
    "mode=%s with_status=%s requested_at=%s requested_by=%s"
    % (mode, "true" if with_status else "false", requested_at, requested_by)
)
PY
)"
PARSE_STATUS=$?
set -o errexit

if [ "$PARSE_STATUS" -ne 0 ]; then
  # Corrupt flag: no break, warn, leave the file for the operator to see.
  err "warning: the break flag at $FLAG is malformed and is being ignored (treated as no break); it has NOT been deleted — inspect or remove it with /break clear"
  exit 0
fi

# Emit the record BEFORE consuming, so a failed delete still halts the caller.
printf '%s\n' "$RECORD"

case "$RECORD" in
  mode=soft*)
    if [ "$PEEK" = "false" ]; then
      rm -f "$FLAG" || err "warning: could not delete the consumed soft break flag at $FLAG; the next boundary may halt again"
    fi
    ;;
esac

exit 10
