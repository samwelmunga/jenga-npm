#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# skills/j-jenga/scripts/render-picker.sh
#
# Turn-by-turn numbered checklist renderer for `/jenga`'s bare-invocation
# interactive picker (E45_S02_T01). Renders a numbered hierarchical
# checklist of the full board (epics, stories, tasks, with summaries),
# sourced from `skills/j-jenga/scripts/board-scan.sh` (E45_S01_T01) — this
# script never re-scans the board directly.
#
# ---------------------------------------------------------------------------
# WHY THIS IS A TWO-INVOCATION, STATE-FILE SCRIPT (READ BEFORE CHANGING)
# ---------------------------------------------------------------------------
# Claude Code's Bash tool runs a command to completion and returns — it
# cannot block mid-script waiting on the next chat message. A single script
# that prints a checklist, then reads stdin for the user's selection, would
# never see real chat input; it would only ever see whatever the Bash tool
# call happened to pipe in (nothing, in the normal interactive case).
#
# So the picker is split across (at least) two invocations of this same
# script, coordinated by the calling agent, never by this script itself:
#
#   1. Turn 1 (start mode, no arguments): this script scans the board,
#      assigns every item a sequential number, writes that numbered
#      snapshot to a temp "state file", and prints a human-readable
#      checklist + instructions to STDOUT.
#   2. The calling agent relays this script's literal STDOUT to the user
#      as a chat message, verbatim — no summarizing, no reformatting.
#   3. The user replies in chat with their raw selection text (e.g.
#      "3, 17, 42").
#   4. The calling agent re-invokes this script, passing the state file
#      path (captured from turn 1's STDERR — see OUTPUT CONTRACT below)
#      and the user's raw reply as two arguments (continue mode).
#   5. This script reads the prior state, validates the reply against the
#      numbering-to-item snapshot it already captured, and either:
#        - emits a plain-text error turn (state file left untouched, same
#          path, ready for another continue-mode retry), or
#        - emits the final resolved selection as JSON (state file removed)
#          for the confirmation-tree renderer (E45_S02_T02) to consume.
#
# Do NOT attempt to "fix" this with a blocking read, a stdin prompt loop,
# or a polling/sleep loop waiting for external input — none of those work
# with the Bash tool's run-to-completion model, and ad-hoc polling loops as
# an inter-turn signaling mechanism are explicitly prohibited elsewhere in
# this repo's agent-coordination conventions (see epic E37).
#
# ---------------------------------------------------------------------------
# USAGE
# ---------------------------------------------------------------------------
#   skills/j-jenga/scripts/render-picker.sh
#       Start a new picker session. No arguments.
#
#   skills/j-jenga/scripts/render-picker.sh <state_file> "<raw_reply>"
#       Continue an existing picker session. <state_file> is the path
#       printed on STDERR by the start-mode invocation (or by a previous
#       error-turn continue-mode invocation — the path is stable across
#       retries). <raw_reply> is the user's raw chat text for this turn,
#       passed as a single argument (quote it).
#
# ---------------------------------------------------------------------------
# OUTPUT CONTRACT (deliberately NOT uniform JSON — see rationale below)
# ---------------------------------------------------------------------------
# Unlike board-scan.sh / resolve-id.sh / cascade-resolve.sh (which always
# emit pure JSON on stdout), this script splits its output by *audience*,
# because it is the one script in this family with a human in the loop for
# most of its turns:
#
#   - Start mode, and continue-mode ERROR turns:
#       STDOUT = plain human-readable text (the checklist, or an error
#                message + retry instructions). This is exactly what the
#                calling agent relays verbatim to the user — nothing to
#                parse, nothing to strip.
#       STDERR = a single line: `STATE_FILE: <absolute path>` — metadata
#                for the calling AGENT to capture for the next invocation.
#                Never intended for the human to read; do not relay it.
#
#   - Continue mode, RESOLVED (fully valid) turn:
#       STDOUT = a single JSON object (schema below) — the machine-readable
#                handoff to the confirmation-tree renderer (E45_S02_T02).
#                This is NOT meant to be relayed to the user verbatim.
#       STDERR = empty (state file has been removed; nothing to carry
#                forward).
#
#   - Continue mode, CANCELLED (`cancel` reply, case-insensitive):
#       STDOUT = plain human-readable cancellation acknowledgement.
#       STDERR = empty (state file has been removed).
#
# RESOLVED JSON schema:
#   {
#     "status":            "resolved",
#     "selected_numbers":  [3, 17, 42],          // as typed, de-duplicated,
#                                                 // in first-seen order
#     "resolved_ids":      ["E01", "E04_S05_T06"],
#     "resolved_ids_csv":  "E01,E04_S05_T06"      // ready to pass directly
#                                                 // as cascade-resolve.sh's
#                                                 // single argument
#   }
#
# ---------------------------------------------------------------------------
# SELECTION GRAMMAR (deliberately distinct from resolve-id.sh's ID grammar)
# ---------------------------------------------------------------------------
# A reply is a comma-separated list of positive integers referring to the
# numbers printed in THIS session's checklist (whitespace around commas and
# numbers is insignificant; purely empty segments from stray/trailing
# commas are ignored, not rejected). This is NOT the `E##_S##_T##` fuzzy-ID
# text grammar `resolve-id.sh` implements — that grammar belongs to the
# separate `/jenga <ids>` explicit-argument entry mode (E45_S01_T02), which
# bypasses this picker entirely. Reusing resolve-id.sh here would require
# it to parse a second, unrelated micro-grammar (bare numbers) its own
# header contract says nothing about, so this script builds and validates
# its own numbering-to-item mapping directly from the state file snapshot
# instead of calling into resolve-id.sh.
#
# Validation is ALL-OR-NOTHING per turn: if a reply contains any non-numeric
# token or any number outside the valid 1..N range for this session, the
# ENTIRE turn is rejected as an error turn (state file left untouched) —
# there is no partial application of the valid numbers in a mixed-validity
# reply, and no accumulation of a selection across multiple turns. A turn is
# either fully consumed (resolved) or fully retried (error) — this keeps the
# loop's semantics simple and satisfies the requirement that invalid/out-of-
# range numbers produce a clear error rather than being silently dropped.
#
# ---------------------------------------------------------------------------
# STATE FILE
# ---------------------------------------------------------------------------
# Created under `mktemp -t jenga-picker-XXXXXX.json`. It is a SELF-CONTAINED
# SNAPSHOT — each numbered entry stores the full board-scan.sh item object
# (id, type, title, status, summary, epic_id, story_id) as it looked at
# start-of-picker time, not just the id. This means an error-turn retry, or
# a re-print, never needs to re-invoke board-scan.sh and can never disagree
# with what the user was actually shown, even if the live board changes
# mid-session.
#
# If the state file is missing or unreadable when continue mode is invoked
# (e.g. the OS temp dir was cleared), this is treated as a real setup
# problem (exit 2), not a per-input validation failure — the user has to
# restart the picker (start mode) from scratch.
#
# ---------------------------------------------------------------------------
# NO CASCADE / DEDUP LOGIC HERE
# ---------------------------------------------------------------------------
# Selecting an epic's number and one of its own descendant task's numbers
# in the same reply is allowed; `resolved_ids` will contain both exactly as
# typed. Expansion of a parent selection to its eligible descendants,
# cross-level deduplication, and terminal-status filtering are the job of
# `cascade-resolve.sh` (E45_S01_T03, already built) and the confirmation-
# tree renderer (E45_S02_T02, not yet built) — this script's only
# responsibility is reporting exactly which board IDs the user typed a
# number for.
#
# ---------------------------------------------------------------------------
# EXIT CODES
# ---------------------------------------------------------------------------
#   0   start mode rendered successfully; OR continue mode fully resolved
#   1   continue mode: at least one invalid/out-of-range number in the
#       reply — an error turn was emitted, retry with the same state file
#   2   usage error, or a real setup problem (board-scan.sh / python3
#       unavailable, state file missing/corrupt)
#   3   continue mode: user replied "cancel" — picker session aborted,
#       state file removed
#
# ---------------------------------------------------------------------------

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BOARD_SCAN="$SCRIPT_DIR/board-scan.sh"

if ! command -v python3 >/dev/null 2>&1; then
  echo "Error: python3 is required by render-picker.sh" >&2
  exit 2
fi

if [ $# -eq 0 ]; then
  MODE="start"
elif [ $# -eq 2 ]; then
  MODE="continue"
  STATE_FILE="$1"
  RAW_REPLY="$2"
else
  echo "Usage:" >&2
  echo "  render-picker.sh                              # start a new picker session" >&2
  echo "  render-picker.sh <state_file> \"<raw_reply>\"    # continue an existing session" >&2
  exit 2
fi

if [ "$MODE" = "start" ]; then
  if [ ! -x "$BOARD_SCAN" ]; then
    echo "Error: board-scan.sh not found or not executable at $BOARD_SCAN" >&2
    exit 2
  fi

  BOARD_JSON="$("$BOARD_SCAN")" || {
    echo "Error: board-scan.sh failed" >&2
    exit 2
  }

  STATE_FILE="$(mktemp -t jenga-picker-XXXXXX.json)"

  # The rendering/state-writing logic is written to a temp .py file rather
  # than piped in via `python3 -` because the board JSON is delivered on
  # stdin — `python3 -` would consume stdin itself as the script source,
  # leaving nothing for the script's own sys.stdin.read() to see. Same
  # pattern as resolve-id.sh.
  PY_SCRIPT="$(mktemp -t render-picker-start-XXXXXX.py)"
  trap 'rm -f "$PY_SCRIPT"' EXIT

  cat > "$PY_SCRIPT" <<'PY'
import json
import sys
from datetime import datetime, timezone

state_file_path = sys.argv[1]
board_json = sys.stdin.read()

try:
    items = json.loads(board_json)
except Exception as e:
    print(f"Error: could not parse board-scan.sh output as JSON: {e}", file=sys.stderr)
    sys.exit(2)

epics = [i for i in items if i.get("type") == "epic"]
stories = [i for i in items if i.get("type") == "story"]
tasks = [i for i in items if i.get("type") == "task"]

valid_epic_ids = {e["id"] for e in epics}
valid_story_ids = {s["id"] for s in stories}

stories_by_epic = {}
unlinked_stories = []
for s in stories:
    epic_id = s.get("epic_id")
    if epic_id in valid_epic_ids:
        stories_by_epic.setdefault(epic_id, []).append(s)
    else:
        unlinked_stories.append(s)

tasks_by_story = {}
unlinked_tasks = []
for t in tasks:
    story_id = t.get("story_id")
    if story_id in valid_story_ids:
        tasks_by_story.setdefault(story_id, []).append(t)
    else:
        unlinked_tasks.append(t)

TYPE_TAG = {"epic": "EPIC", "story": "STORY", "task": "TASK"}
INDENT = {"epic": "", "story": "    ", "task": "        "}

numbering = {}
lines = []
counter = 1


def render_item(item, level):
    global counter
    n = counter
    counter += 1
    numbering[str(n)] = item
    indent = INDENT[level]
    title = item.get("title") or "(untitled)"
    status = item.get("status") or "(no status)"
    summary = item.get("summary") or "(no summary)"
    lines.append(f"{indent}{n}. [{TYPE_TAG[level]}] {item['id']} — {title}  (status: {status})")
    lines.append(f"{indent}     {summary}")


for e in epics:
    render_item(e, "epic")
    for s in stories_by_epic.get(e["id"], []):
        render_item(s, "story")
        for t in tasks_by_story.get(s["id"], []):
            render_item(t, "task")

if unlinked_stories:
    lines.append("")
    lines.append("-- Unlinked Stories (no matching epic on the board) --")
    for s in unlinked_stories:
        render_item(s, "story")
        for t in tasks_by_story.get(s["id"], []):
            render_item(t, "task")

if unlinked_tasks:
    lines.append("")
    lines.append("-- Unlinked Tasks (no matching story on the board) --")
    for t in unlinked_tasks:
        render_item(t, "story")  # top-level indent for an orphaned task

total = len(numbering)

state = {
    "version": 1,
    "created_at": datetime.now(timezone.utc).isoformat(),
    "total_items": total,
    "numbering": numbering,
}

with open(state_file_path, "w", encoding="utf-8") as f:
    json.dump(state, f, indent=2)
    f.write("\n")

header = [
    "=" * 68,
    " /jenga — Board Picker",
    "=" * 68,
    "Select items by number, comma-separated. You may mix levels freely",
    '— e.g. "3,17,42" can select an epic, a story, and a task all in',
    "the same reply. Selecting a parent (epic/story) later cascades to",
    "its eligible descendants during confirmation.",
    "",
    'Reply "cancel" at any time to abort the picker.',
    "-" * 68,
    "",
]

if total == 0:
    body = ["(The board is empty — there is nothing to select.)"]
else:
    body = lines

footer = [
    "",
    "-" * 68,
    f"Total: {len(epics)} epic(s), {len(stories)} stor{'y' if len(stories) == 1 else 'ies'}, "
    f"{len(tasks)} task(s) ({total} item(s) numbered 1-{total})." if total else "Nothing to select.",
    "",
    'Reply with your selection (comma-separated numbers), or "cancel".',
]

print("\n".join(header + body + footer))
print(f"STATE_FILE: {state_file_path}", file=sys.stderr)
PY

  python3 "$PY_SCRIPT" "$STATE_FILE" <<< "$BOARD_JSON"
  exit 0
fi

# --------------------------------------------------------------------------
# continue mode
# --------------------------------------------------------------------------

if [ ! -f "$STATE_FILE" ]; then
  echo "Error: state file not found at $STATE_FILE" >&2
  echo "The picker session may have expired (e.g. temp dir was cleared)." >&2
  echo "Start a new picker session with: render-picker.sh" >&2
  exit 2
fi

PY_SCRIPT="$(mktemp -t render-picker-continue-XXXXXX.py)"
trap 'rm -f "$PY_SCRIPT"' EXIT

cat > "$PY_SCRIPT" <<'PY'
import json
import re
import sys

state_file_path = sys.argv[1]
raw_reply = sys.argv[2]

try:
    with open(state_file_path, encoding="utf-8") as f:
        state = json.load(f)
except Exception as e:
    print(f"Error: could not read/parse state file at {state_file_path}: {e}", file=sys.stderr)
    sys.exit(2)

numbering = state.get("numbering", {})
total = state.get("total_items", len(numbering))

if raw_reply.strip().lower() == "cancel":
    import os
    try:
        os.remove(state_file_path)
    except OSError:
        pass
    print("Picker session cancelled. No selection was made.")
    sys.exit(3)

raw_tokens = raw_reply.split(",")
tokens = [tok.strip() for tok in raw_tokens]
tokens = [tok for tok in tokens if tok != ""]

if not tokens:
    print("Error: no selection numbers found in your reply.")
    print("")
    print('Reply with comma-separated numbers from the checklist above (e.g. "3,17,42"), or "cancel".')
    print(f"STATE_FILE: {state_file_path}", file=sys.stderr)
    sys.exit(1)

invalid = []
valid_numbers = []
for tok in tokens:
    if not re.fullmatch(r"[0-9]+", tok):
        invalid.append((tok, "not a whole number"))
        continue
    if tok not in numbering:
        invalid.append((tok, f"out of range (valid: 1-{total})"))
        continue
    valid_numbers.append(int(tok))

if invalid:
    print("Error: your reply contains invalid selection number(s):")
    for tok, reason in invalid:
        print(f"  - '{tok}': {reason}")
    print("")
    print(f"Valid selection numbers for this session are 1-{total}.")
    print('Reply again with a corrected, comma-separated list (e.g. "3,17,42"), or "cancel".')
    print(f"STATE_FILE: {state_file_path}", file=sys.stderr)
    sys.exit(1)

# All-or-nothing success: de-duplicate while preserving first-seen order.
seen = set()
selected_numbers = []
resolved_ids = []
for n in valid_numbers:
    if n in seen:
        continue
    seen.add(n)
    selected_numbers.append(n)
    resolved_ids.append(numbering[str(n)]["id"])

import os
try:
    os.remove(state_file_path)
except OSError:
    pass

result = {
    "status": "resolved",
    "selected_numbers": selected_numbers,
    "resolved_ids": resolved_ids,
    "resolved_ids_csv": ",".join(resolved_ids),
}
print(json.dumps(result, indent=2))
sys.exit(0)
PY

python3 "$PY_SCRIPT" "$STATE_FILE" "$RAW_REPLY"
exit $?
