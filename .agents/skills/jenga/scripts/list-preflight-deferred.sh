#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# skills/jenga/scripts/list-preflight-deferred.sh
#
# Lists the units of work that `/j-do` DEFERRED at its pre-task pre-flight gate during one `/jenga`
# run (E67_S03_T06). `/jenga` Phase 4 uses the output as a run-scoped exclusion set so a deferred
# unit is dispatched at most once per run instead of once per wave.
#
# Why: `skills/j-do/SKILL.md` step 4.1.2 defers a unit (reverts it to `Pending`, appends a
# `preflight_deferred` event) when its `pre-task` gate needs a user decision and `/do` is a background
# sub-agent with no live user channel. Phase 4's loop-back re-collects every `Pending` item, so
# without an exclusion the same unit would be re-dispatched, and defer instantly, on every wave.
# A deferral needs a human; re-dispatching cannot resolve it.
#
# Extracting ids from `events.json` is deterministic, so it is this script's job; the SKILL.md prose
# keeps only the judgment (what to exclude, what to tell the user).
#
# ---------------------------------------------------------------------------
# USAGE
# ---------------------------------------------------------------------------
#   skills/jenga/scripts/list-preflight-deferred.sh <orchestrator_session_id>
#
# Prints, one per line, de-duplicated, in first-seen order, the `item_id` of every event in the
# events log with `"event": "preflight_deferred"` and `"session_id"` exactly equal to the argument.
# For a Story-Bundle the `item_id` is the STORY id; for any other unit it is the task id.
# Nothing else is printed on stdout. Other event types (including `capacity_blocked`) and other
# sessions' events are never returned.
#
# Event shape (defined at skills/j-do/SKILL.md step 4.1.2):
#   {"event": "preflight_deferred", "agent": "orchestrator", "session_id": "<id>",
#    "item_id": "<id>", "phase": "pre-task", "run_id": "...", "items": [...], "date": "..."}
#
# The events file is treated as untrusted-ish: it is normally a JSON array of objects, but entries
# that are not objects, lack `event`/`session_id`/`item_id`, or carry an `item_id` that is not a
# plain board-id-shaped string ([A-Za-z0-9_.-]+) are silently skipped. (The id shape check keeps a
# stray newline or space in a hand-edited log from injecting extra output lines.)
#
# ---------------------------------------------------------------------------
# EVENTS FILE LOCATION
# ---------------------------------------------------------------------------
#   JENGA_PREFLIGHT_EVENTS_FILE   test seam: when set and non-empty, read this file and skip
#                                 working-file path resolution entirely.
#   otherwise                     "$(scripts/resolve-root.sh get logs)/events.json" -- never a
#                                 hardcoded `project/` literal (E34_S01 resolver contract).
#
# Missing file, empty file, or a file with only whitespace: prints nothing, exit 0.
#
# ---------------------------------------------------------------------------
# EXIT CODES
# ---------------------------------------------------------------------------
#   0  success (including: no events, no matching events, missing or empty events file)
#   1  events file is malformed: not valid JSON, or valid JSON whose top level is not an array
#      (specific message on stderr, never a traceback)
#   2  usage error (missing, empty or extra argument)
#   3  the logs path could not be resolved via scripts/resolve-root.sh
#   4  python3 is not installed
#   5  the events file exists but could not be read (permissions, is a directory, ...)
#
# macOS bash 3.2 compatible; uses no `timeout` binary (none ships on macOS).
# ---------------------------------------------------------------------------

set -u

SELF="list-preflight-deferred.sh"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PACKAGE_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
RESOLVE_ROOT="$PACKAGE_ROOT/scripts/resolve-root.sh"

die() {
  local code="$1"
  shift
  printf '%s: %s\n' "$SELF" "$*" >&2
  exit "$code"
}

if [ "$#" -ne 1 ] || [ -z "$1" ]; then
  die 2 "usage: $SELF <orchestrator_session_id>"
fi
SESSION_ID="$1"

command -v python3 >/dev/null 2>&1 || die 4 "python3 is required"

if [ -n "${JENGA_PREFLIGHT_EVENTS_FILE:-}" ]; then
  EVENTS_FILE="$JENGA_PREFLIGHT_EVENTS_FILE"
else
  LOGS_DIR="$(bash "$RESOLVE_ROOT" get logs 2>/dev/null)" || LOGS_DIR=""
  [ -n "$LOGS_DIR" ] || die 3 "could not resolve the logs path via scripts/resolve-root.sh"
  EVENTS_FILE="$LOGS_DIR/events.json"
fi

# No log yet means nothing was ever deferred.
[ -e "$EVENTS_FILE" ] || exit 0

python3 - "$EVENTS_FILE" "$SESSION_ID" <<'PY'
import json
import re
import sys

path, session_id = sys.argv[1], sys.argv[2]
SELF = "list-preflight-deferred.sh"
ID_RE = re.compile(r"^[A-Za-z0-9_.-]+$")

try:
    with open(path, "r", encoding="utf-8") as fh:
        raw = fh.read()
except (OSError, UnicodeDecodeError) as exc:
    # UnicodeDecodeError is a ValueError, not an OSError: bytes that are not UTF-8 are malformed content.
    if isinstance(exc, UnicodeDecodeError):
        sys.stderr.write("%s: events file %s is malformed: not valid UTF-8 (%s)\n" % (SELF, path, exc.reason))
        sys.exit(1)
    sys.stderr.write("%s: cannot read events file %s: %s\n" % (SELF, path, exc.strerror or exc))
    sys.exit(5)

if not raw.strip():
    sys.exit(0)

try:
    data = json.loads(raw)
except (ValueError, RecursionError) as exc:
    sys.stderr.write("%s: events file %s is malformed: %s\n" % (SELF, path, exc))
    sys.exit(1)

if not isinstance(data, list):
    sys.stderr.write(
        "%s: events file %s is malformed: expected a JSON array of events, found %s\n"
        % (SELF, path, type(data).__name__)
    )
    sys.exit(1)

seen = set()
out = []
for entry in data:
    if not isinstance(entry, dict):
        continue
    if entry.get("event") != "preflight_deferred":
        continue
    if entry.get("session_id") != session_id:
        continue
    item_id = entry.get("item_id")
    if not isinstance(item_id, str) or not ID_RE.match(item_id):
        continue
    if item_id in seen:
        continue
    seen.add(item_id)
    out.append(item_id)

if out:
    sys.stdout.write("\n".join(out) + "\n")
PY
