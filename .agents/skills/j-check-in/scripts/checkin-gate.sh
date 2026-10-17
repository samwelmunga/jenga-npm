#!/usr/bin/env bash
################################################################################
# checkin-gate.sh — has a check-in already run in this session?
#
# This is the `verify` command for the `checkin-run-before-dispatch` pre-flight
# checklist item. It answers exactly one question and nothing else:
#
#     does the project's logs/events.json hold a `checkin` event for THIS
#     session?
#
# Exit 0 means yes (the item is satisfied). Any non-zero means no, and the item
# is reported failed -> prompt, because its enforcement is `confirm`.
#
# ---------------------------------------------------------------------------
# WHY THIS IS A SEPARATE SCRIPT FROM collect-liveness.sh, AND MUST STAY SEPARATE
#
# A verify command's EXIT STATUS is the gate signal: scripts/checklist.sh scores
# "machine, verify exits 0 -> passed" and any non-zero as a failure. That
# collides head-on with collect-liveness.sh's exit-0-always contract, where the
# signal lives in the emitted JSON and the exit code is reserved for internal
# script failure.
#
# Rather than compromise either contract, the gate is a different script with
# different semantics. collect-liveness.sh is NEVER invoked by `verify`, never
# runs inside a verify timeout, and its contract is untouched by this one.
# Do not "simplify" this by calling the collector here.
#
# ---------------------------------------------------------------------------
# WHAT "THIS SESSION" MEANS
#
# The session key is resolved by scripts/checklist-marker.sh session-key, which
# owns the probe order (--session, JENGA_CHECKLIST_SESSION_ID,
# CLAUDE_CODE_SESSION_ID, JENGA_SESSION_ID). This script does NOT re-implement
# that order: the gate, the situation marker and the tick store must agree on
# what one session is, and the only way to guarantee that is to share the one
# resolver.
#
# NOTE on the tick store, since the task description assumes otherwise: the tick
# store is NOT session-keyed. Persistent ticks live in one project-root-scoped
# persistent.json and run-scoped ticks are keyed by run id. Only the marker has
# a session key, so the marker is the single source this script follows.
#
# A `checkin` event is matched on `session_key` first — the marker-resolved key
# that j.check-in's step 6 writes for exactly this purpose — and on `session_id`
# as a fallback, because collect-liveness.sh derives its own session_id from a
# different probe order (SESSION_ID / HARNESS_SESSION_ID / hostname-pid) and the
# two values legitimately differ.
#
# ---------------------------------------------------------------------------
# FAIL DIRECTION
#
# No resolvable session key, no logs directory, no events file, an unreadable
# events file: all NON-ZERO, i.e. "the gate is not satisfied". That is the safe
# direction here. Enforcement is `confirm`, so a non-zero costs the user one
# prompt; a zero would silently skip the check-in the item exists to force. This
# mirrors the checker's own rule that a forgotten key costs a re-verification
# and never a skipped check.
#
# ---------------------------------------------------------------------------
# VERIFY-CONTRACT CONSTRAINTS (scripts/checklist.sh's header)
#
# - Runs as `bash -c` from the resolved project root, stdin from /dev/null.
# - Runs in its own process group under a wall-clock timeout, SIGKILLed as a
#   group: so this script must NOT start a long-lived background process. It
#   does not fork anything that outlives it.
# - Must be read-only. It is: one directory resolution, one session-key
#   resolution, one file read. No writes, no temp files, no lock.
# - Must never mask its own failure. No success-forcing suffix and no leading
#   negation appears anywhere in this script, deliberately written so that a
#   grep for either stays a reliable check: every failure path exits non-zero
#   on purpose. The one tolerated-failure assignment (the session-key probe)
#   is immediately followed by an explicit empty check that exits 7.
# - Must be fast. Measured at well under a second against this repository's real
#   events.json.
#
# ---------------------------------------------------------------------------
# USAGE
#   checkin-gate.sh [--max-age-minutes <n>] [--session <key>]
#
#   --max-age-minutes <n>  Accepted and validated, but deliberately a no-op today.
#                          It is reserved for the deferred time-based cadence mode,
#                          so that mode can be switched on later without changing
#                          this script's interface. With the flag absent — and the
#                          registry never passes it — the presence of ANY `checkin`
#                          event for this session satisfies the gate.
#   --session <key>        forwarded to the session-key resolver; a test seam and
#                          an escape hatch, not used in normal operation.
#
# EXIT CODES
#   0  a `checkin` event for this session exists — item satisfied
#   1  no such event — item not satisfied
#   2  usage error
#   3  the logs directory could not be resolved, or the events file is absent
#      or unreadable
#   4  python3 is not available
#   7  no session key could be resolved (mirrors checklist-marker.sh's exit 7)
#
################################################################################

set -o errexit
set -o nounset

SCRIPT_NAME="checkin-gate.sh"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/../../.." && pwd)"

err() { printf '%s: %s\n' "$SCRIPT_NAME" "$1" >&2; }

usage() {
  printf 'Usage: %s [--max-age-minutes <n>] [--session <key>]\n' "$SCRIPT_NAME" >&2
}

# Resolve a sibling framework script: this repo first, then an installed package.
# Never resolved under the evidence root — these are scripts we EXECUTE.
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

MAX_AGE_MINUTES=""
SESSION_OVERRIDE=""

while [ "$#" -gt 0 ]; do
  case "$1" in
    --max-age-minutes)
      [ "$#" -ge 2 ] || { err "--max-age-minutes needs a value"; usage; exit 2; }
      MAX_AGE_MINUTES="$2"
      shift 2
      ;;
    --max-age-minutes=*)
      MAX_AGE_MINUTES="${1#--max-age-minutes=}"
      shift
      ;;
    --session)
      [ "$#" -ge 2 ] || { err "--session needs a value"; usage; exit 2; }
      SESSION_OVERRIDE="$2"
      shift 2
      ;;
    --session=*)
      SESSION_OVERRIDE="${1#--session=}"
      shift
      ;;
    -h|--help|help)
      usage
      exit 0
      ;;
    *)
      err "unknown argument: $1"
      usage
      exit 2
      ;;
  esac
done

if [ -n "$MAX_AGE_MINUTES" ]; then
  case "$MAX_AGE_MINUTES" in
    ''|*[!0-9]*) err "--max-age-minutes must be a non-negative integer"; exit 2 ;;
  esac
  err "note: --max-age-minutes is reserved and has no effect yet; presence of any checkin event for this session satisfies the gate"
fi

command -v python3 >/dev/null 2>&1 || { err "python3 is required"; exit 4; }

# --- resolve the logs directory through the root resolver, never a literal ---
RESOLVE_ROOT="$(resolve_helper scripts/resolve-root.sh)" || {
  err "could not locate scripts/resolve-root.sh"
  exit 3
}

LOGS_DIR=""
if ! LOGS_DIR="$(bash "$RESOLVE_ROOT" get logs 2>/dev/null)"; then
  err "could not resolve the logs directory"
  exit 3
fi
[ -n "$LOGS_DIR" ] || { err "the logs directory resolved to an empty path"; exit 3; }

EVENTS_FILE="$LOGS_DIR/events.json"
if [ ! -f "$EVENTS_FILE" ]; then
  err "no events file at $EVENTS_FILE, so no check-in can be recorded for this session"
  exit 3
fi
if [ ! -r "$EVENTS_FILE" ]; then
  err "events file is not readable: $EVENTS_FILE"
  exit 3
fi

# --- resolve the session key through the marker's own resolver ----------------
MARKER="$(resolve_helper scripts/checklist-marker.sh)" || {
  err "could not locate scripts/checklist-marker.sh"
  exit 3
}

SESSION_KEY=""
if [ -n "$SESSION_OVERRIDE" ]; then
  SESSION_KEY="$(bash "$MARKER" session-key --session "$SESSION_OVERRIDE" 2>/dev/null)" || SESSION_KEY=""
else
  SESSION_KEY="$(bash "$MARKER" session-key 2>/dev/null)" || SESSION_KEY=""
fi
SESSION_KEY="$(printf '%s' "$SESSION_KEY" | tr -d '\r\n')"

if [ -z "$SESSION_KEY" ]; then
  err "no session key could be resolved, so this session's check-in state is unknown"
  exit 7
fi

# --- look for a checkin event belonging to this session ----------------------
#
# Parsed tolerantly, for the same reason collect-liveness.sh is: this
# repository's real events.json is an unterminated JSON array with a missing
# comma, so a strict json.load fails on it outright. A strict parse here would
# make the gate permanently unsatisfiable, which under `confirm` means prompting
# on every single dispatch forever.
#
# The event spelling is matched EXACTLY against "checkin". A differently-spelled
# event does not satisfy the gate — that is what makes the single-canonical-
# spelling rule real rather than aspirational.
set +o errexit
python3 - "$EVENTS_FILE" "$SESSION_KEY" <<'PY'
import json
import sys

CANONICAL_EVENT = "checkin"

path, session_key = sys.argv[1], sys.argv[2]

try:
    with open(path, encoding="utf-8", errors="replace") as fh:
        raw = fh.read()
except OSError as exc:
    print(f"checkin-gate.sh: cannot read {path}: {exc}", file=sys.stderr)
    sys.exit(3)

decoder = json.JSONDecoder()
events = []
i, n = 0, len(raw)
while i < n:
    if raw[i] in " \t\r\n,[]":
        i += 1
        continue
    try:
        obj, j = decoder.raw_decode(raw, i)
    except ValueError:
        nl = raw.find("\n", i)
        if nl == -1:
            break
        i = nl + 1
        continue
    i = j
    if isinstance(obj, dict):
        events.append(obj)
    elif isinstance(obj, list):
        events.extend(x for x in obj if isinstance(x, dict))

for event in events:
    if event.get("event") != CANONICAL_EVENT:
        continue
    # session_key is the marker-resolved key j.check-in writes for this gate.
    # session_id is collect-liveness.sh's own differently-derived value, kept as
    # a fallback so a check-in recorded without the explicit key still counts.
    if session_key in (event.get("session_key"), event.get("session_id")):
        sys.exit(0)

print(
    f"checkin-gate.sh: no '{CANONICAL_EVENT}' event for session {session_key} "
    f"in {path} ({len(events)} events read)",
    file=sys.stderr,
)
sys.exit(1)
PY
PY_STATUS=$?
set -o errexit

exit "$PY_STATUS"
