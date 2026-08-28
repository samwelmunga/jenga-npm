#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# skills/jenga/scripts/cascade-resolve.sh
#
# Cascade resolver for `/jenga`'s interactive scope-selection flow (E45).
# Given a resolved board-ID set (exact `E##` / `E##_S##` / `E##_S##_T##`
# IDs — already resolved by the picker in E45_S02_T01 or by
# `resolve-id.sh` in E45_S01_T02; this script does NOT do fuzzy-ID
# parsing), expands any epic or story selection into its full set of
# eligible descendants:
#
#   - An epic selection expands to all of its stories and their tasks.
#   - A story selection expands to all of its tasks.
#   - Expansion only includes descendants in a Pending/eligible state —
#     terminal-status descendants (Passed, Passed with remarks, Failed,
#     Rejected, Blocked, Done) are excluded.
#   - A descendant epic/story that has not yet been broken down on the
#     board (zero stories under an epic, zero tasks under a story) is
#     flagged under `undecomposed` so jenga's existing Phase 1/2
#     decomposition logic can pick it up. This script never decomposes
#     anything itself — it only flags the need.
#
# Per this repo's "Scripts Over Inline Logic" principle and the sibling
# board-scan.sh's own header contract, this script consumes
# board-scan.sh's JSON output as the SINGLE SOURCE OF TRUTH for board
# contents — it does not re-scan project/board/ independently.
#
# Downstream consumer: E45_S02_T02 (confirmation-tree renderer) reads
# this script's output to render the nested Epic > Story > Task
# confirmation tree with per-level counts.
#
# ---------------------------------------------------------------------------
# USAGE
# ---------------------------------------------------------------------------
#   skills/jenga/scripts/cascade-resolve.sh "<comma-separated-ids>"
#
# One argument: a comma-separated list of exact, already-resolved board
# IDs (e.g. "E01,E02_S03,E04_S05_T06"). Whitespace around commas/ids is
# trimmed. IDs are matched case-sensitively against the board (board IDs
# are always uppercase per templates/SCRUM_BOARD_SCHEMA.md).
#
# ---------------------------------------------------------------------------
# OUTPUT SCHEMA (stable — downstream scripts depend on these exact names)
# ---------------------------------------------------------------------------
# stdout is a single JSON object. Nothing else is ever written to stdout.
#
#   {
#     "items": [ <board-scan.sh item objects — see that script's header
#                 for the per-item schema — for every epic/story/task
#                 node in the resolved tree, deduplicated> ],
#     "resolved_ids": ["E01", "E01_S02", "E01_S02_T01"],
#     "counts": {"epics": 1, "stories": 1, "tasks": 1},
#     "undecomposed": [
#       {"id": "E02", "type": "epic", "missing": "stories"},
#       {"id": "E02_S01", "type": "story", "missing": "tasks"}
#     ],
#     "warnings": [
#       {"input": "E99", "reason": "not found on board"},
#       {"input": "E01_S02_T09", "reason": "excluded: terminal status (Passed)"},
#       {"input": "foo", "reason": "malformed ID (does not match E##, E##_S##, or E##_S##_T## shape)"}
#     ]
#   }
#
# Field notes:
#   - `items` includes every node actually present in the resolved tree —
#     epics/stories that were directly selected or expanded into, plus
#     eligible (non-terminal) descendant stories/tasks. It is NOT limited
#     to leaf tasks, because the confirmation-tree renderer needs the
#     full Epic > Story > Task shape, not just an execution list.
#   - `resolved_ids` is the same set as `items`, as a flat list of IDs
#     (convenience for callers that only need IDs).
#   - `counts` reflects unique nodes of each type present in `items` —
#     i.e. what the confirmation tree will actually render — not a count
#     of input arguments.
#   - `undecomposed` entries mean "this epic/story has zero children on
#     the board at all", distinct from "this epic/story has children but
#     none are eligible" (which is not flagged — there is nothing to
#     decompose, the work is simply already done or blocked).
#   - `warnings` covers three non-fatal per-input problems: an ID not
#     found on the board, a directly-selected task/story/epic excluded
#     for being in a terminal status, and a malformed ID shape. None of
#     these abort the run — valid inputs are still resolved and stdout is
#     still a complete, valid JSON object.
#
# ---------------------------------------------------------------------------
# ERROR HANDLING
# ---------------------------------------------------------------------------
# Exit codes:
#   0   resolution completed (stdout is always valid JSON on this path,
#       even if some inputs produced warnings, and even if the result is
#       an empty items/resolved_ids set because every input was invalid)
#   1   a structural failure: no argument given, board-scan.sh itself
#       failed or produced unparseable output, or python3 is unavailable
#       — these are real setup problems, not per-input noise
#
# ---------------------------------------------------------------------------

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [ $# -lt 1 ] || [ -z "${1// /}" ]; then
  echo "Usage: cascade-resolve.sh \"<comma-separated-ids>\"" >&2
  echo "Example: cascade-resolve.sh \"E01,E02_S03,E04_S05_T06\"" >&2
  exit 1
fi

RAW_IDS="$1"

# No project-dir resolution needed here: board-scan.sh (invoked below)
# already resolves JENGA_PROJECT_DIR itself (CLAUDE_PROJECT_DIR -> git
# toplevel -> cwd) and is the sole source of board contents for this
# script, per the "Scripts Over Inline Logic" / single-source-of-truth
# contract documented in its own header.
BOARD_SCAN="$SCRIPT_DIR/board-scan.sh"

if [ ! -x "$BOARD_SCAN" ]; then
  echo "Error: board-scan.sh not found or not executable at $BOARD_SCAN" >&2
  exit 1
fi

if ! command -v python3 >/dev/null 2>&1; then
  echo "Error: python3 is required by cascade-resolve.sh" >&2
  exit 1
fi

BOARD_JSON_FILE="$(mktemp)"
trap 'rm -f "$BOARD_JSON_FILE"' EXIT

if ! "$BOARD_SCAN" > "$BOARD_JSON_FILE"; then
  echo "Error: board-scan.sh failed" >&2
  exit 1
fi

python3 - "$RAW_IDS" "$BOARD_JSON_FILE" <<'PY'
import json
import re
import sys

raw_ids_arg = sys.argv[1]
board_json_file = sys.argv[2]

try:
    with open(board_json_file, encoding="utf-8") as f:
        board_items = json.load(f)
except Exception as e:
    print(f"Error: could not parse board-scan.sh output as JSON: {e}", file=sys.stderr)
    sys.exit(1)

# Terminal statuses, verbatim from templates/SCRUM_BOARD_SCHEMA.md's
# Status Values table. An item in one of these statuses is never
# included as an expanded/eligible descendant.
TERMINAL_STATUSES = {
    "Passed",
    "Passed with remarks",
    "Failed",
    "Rejected",
    "Blocked",
    "Done",
}

EPIC_RE = re.compile(r'^E\d{2}$')
STORY_RE = re.compile(r'^E\d{2}_S\d{2}$')
TASK_RE = re.compile(r'^E\d{2}_S\d{2}_T\d{2}$')

by_id = {}
stories_by_epic = {}
tasks_by_story = {}

for item in board_items:
    item_id = item.get("id", "")
    if not item_id:
        continue
    by_id[item_id] = item
    if item.get("type") == "story":
        epic_id = item.get("epic_id")
        if epic_id:
            stories_by_epic.setdefault(epic_id, []).append(item)
    elif item.get("type") == "task":
        story_id = item.get("story_id")
        if story_id:
            tasks_by_story.setdefault(story_id, []).append(item)


def classify(item_id):
    if TASK_RE.match(item_id):
        return "task"
    if STORY_RE.match(item_id):
        return "story"
    if EPIC_RE.match(item_id):
        return "epic"
    return None


resolved = {}       # id -> item, dedup-preserving insertion order
resolved_order = []
undecomposed = []
undecomposed_seen = set()
warnings = []


def add_item(item):
    item_id = item["id"]
    if item_id not in resolved:
        resolved[item_id] = item
        resolved_order.append(item_id)


def flag_undecomposed(entry_id, entry_type, missing):
    key = (entry_id, missing)
    if key in undecomposed_seen:
        return
    undecomposed_seen.add(key)
    undecomposed.append({"id": entry_id, "type": entry_type, "missing": missing})


def expand_story(story_item, include_story_node=True):
    """Add an eligible story node and its eligible (non-terminal) tasks.
    Flags the story as undecomposed if it has zero tasks at all."""
    if include_story_node:
        add_item(story_item)
    story_id = story_item["id"]
    tasks = tasks_by_story.get(story_id, [])
    if not tasks:
        flag_undecomposed(story_id, "story", "tasks")
        return
    for task_item in tasks:
        if task_item.get("status") in TERMINAL_STATUSES:
            continue
        add_item(task_item)


raw_inputs = [tok.strip() for tok in raw_ids_arg.split(",")]
raw_inputs = [tok for tok in raw_inputs if tok]

for input_id in raw_inputs:
    item_type = classify(input_id)
    if item_type is None:
        warnings.append({
            "input": input_id,
            "reason": "malformed ID (does not match E##, E##_S##, or E##_S##_T## shape)",
        })
        continue

    item = by_id.get(input_id)
    if item is None:
        warnings.append({"input": input_id, "reason": "not found on board"})
        continue

    if item_type == "epic":
        # Always include the epic node itself for tree display, regardless
        # of the epic's own status — cascading is about its descendants.
        add_item(item)
        stories = stories_by_epic.get(input_id, [])
        if not stories:
            flag_undecomposed(input_id, "epic", "stories")
            continue
        for story_item in stories:
            if story_item.get("status") in TERMINAL_STATUSES:
                continue
            expand_story(story_item, include_story_node=True)

    elif item_type == "story":
        add_item(item)
        expand_story(item, include_story_node=False)

    else:  # task
        if item.get("status") in TERMINAL_STATUSES:
            warnings.append({
                "input": input_id,
                "reason": f"excluded: terminal status ({item.get('status')})",
            })
            continue
        add_item(item)

items_out = [resolved[i] for i in resolved_order]
counts = {"epics": 0, "stories": 0, "tasks": 0}
for it in items_out:
    t = it.get("type")
    if t == "epic":
        counts["epics"] += 1
    elif t == "story":
        counts["stories"] += 1
    elif t == "task":
        counts["tasks"] += 1

output = {
    "items": items_out,
    "resolved_ids": resolved_order,
    "counts": counts,
    "undecomposed": undecomposed,
    "warnings": warnings,
}

json.dump(output, sys.stdout, indent=2)
sys.stdout.write("\n")
PY
