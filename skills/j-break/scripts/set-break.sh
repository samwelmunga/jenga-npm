#!/usr/bin/env bash
################################################################################
# set-break.sh — record a stop-at-the-next-boundary request
#
# The write side of the break flag contract (templates/SCRUM_BOARD_SCHEMA.md,
# "Break Request Flag"). `/break` and `/break hard` both dispatch here; nothing
# about the flag's shape or its escalation rule lives in a SKILL.md.
#
# Usage:
#   set-break.sh [--hard] [--status]
#
#   --hard    mode=hard: the flag persists until clear-break.sh removes it.
#             Without it, mode=soft: the first loop to reach a task boundary
#             consumes the flag and clears it.
#   --status  with_status=true: the halting loop should also print the scoped
#             execution rapport.
#
# ESCALATION IS ONE-WAY. If a flag already exists with mode=hard and this
# request is soft, the mode STAYS hard. A bare `/break` must never silently
# weaken a standing hard break — "nobody runs the board until I say so" is not
# something a later, weaker request gets to undo by accident. A soft flag given
# --hard does become hard. Either way `requested_at` and `with_status` are
# refreshed from this request, because the operator just restated their intent.
#
# THE WRITE IS ATOMIC. The record goes to a temp file in the same directory and
# is then renamed over the target, so a loop calling check-break.sh concurrently
# sees a whole old record or a whole new one and never a half-written file.
# Rename-within-a-directory is atomic on POSIX; writing in place is not.
#
# Exit codes:
#   0  the flag is in place (newly written or updated)
#   2  usage error
#   3  the queue directory could not be resolved or created
#   4  python3 is not available
#   5  the write failed
#
################################################################################

set -o errexit
set -o nounset

SCRIPT_NAME="set-break.sh"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/../../.." && pwd)"

err() { printf '%s: %s\n' "$SCRIPT_NAME" "$1" >&2; }
usage() { printf 'Usage: %s [--hard] [--status]\n' "$SCRIPT_NAME" >&2; }

# Resolve a sibling framework script: this repo first, then an installed
# package. Never relative to the caller's cwd — a loop may call this from a
# worktree or any subdirectory.
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

MODE="soft"
WITH_STATUS="false"

while [ "$#" -gt 0 ]; do
  case "$1" in
    --hard)   MODE="hard";        shift ;;
    --status) WITH_STATUS="true"; shift ;;
    -h|--help|help) usage; exit 0 ;;
    *) err "unknown argument: $1"; usage; exit 2 ;;
  esac
done

command -v python3 >/dev/null 2>&1 || { err "python3 is required"; exit 4; }

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

mkdir -p "$QUEUE_DIR" || { err "could not create $QUEUE_DIR"; exit 3; }

FLAG="$QUEUE_DIR/.break_request.json"
REQUESTED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

set +o errexit
python3 - "$FLAG" "$MODE" "$WITH_STATUS" "$REQUESTED_AT" <<'PY'
import json
import os
import sys
import tempfile

flag, requested_mode, with_status, requested_at = sys.argv[1:5]
with_status = with_status == "true"

VALID_MODES = ("soft", "hard")

existing_mode = None
was_existing = False
if os.path.exists(flag):
    was_existing = True
    try:
        with open(flag, encoding="utf-8") as fh:
            record = json.load(fh)
        if isinstance(record, dict) and record.get("mode") in VALID_MODES:
            existing_mode = record["mode"]
    except (OSError, ValueError):
        # An unparseable existing flag carries no mode to preserve. Overwrite it:
        # check-break.sh already treats a corrupt flag as "no break", so leaving
        # it in place would leave the operator's request unhonoured.
        existing_mode = None

# Escalation is one-way: hard is never downgraded to soft by a later request.
mode = requested_mode
if existing_mode == "hard" and requested_mode == "soft":
    mode = "hard"

record = {
    "mode": mode,
    "with_status": with_status,
    "requested_at": requested_at,
    "requested_by": "/break",
}

directory = os.path.dirname(flag) or "."
tmp_fd, tmp_path = tempfile.mkstemp(prefix=".break_request.", suffix=".tmp", dir=directory)
try:
    with os.fdopen(tmp_fd, "w", encoding="utf-8") as fh:
        json.dump(record, fh, indent=2)
        fh.write("\n")
        fh.flush()
        os.fsync(fh.fileno())
    os.replace(tmp_path, flag)        # atomic within the directory
except Exception as exc:              # noqa: BLE001 - any failure must not leave a temp file
    try:
        os.unlink(tmp_path)
    except OSError:
        pass
    print(f"set-break.sh: could not write {flag}: {exc}", file=sys.stderr)
    sys.exit(5)

status_phrase = "with a status rapport" if with_status else "without a status rapport"
if not was_existing:
    what = "new break request"
elif existing_mode == "hard" and requested_mode == "soft":
    what = "existing hard break kept (a soft request does not downgrade it)"
elif existing_mode == mode:
    what = "existing break refreshed"
else:
    what = f"existing break upgraded from {existing_mode} to {mode}"

print(f"break set: mode={mode} {status_phrase} — {what} (requested_at={requested_at})")
PY
PY_STATUS=$?
set -o errexit

exit "$PY_STATUS"
