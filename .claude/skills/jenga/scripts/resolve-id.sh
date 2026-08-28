#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# skills/jenga/scripts/resolve-id.sh
#
# Deterministic fuzzy-ID grammar parser and board-backed resolver for
# `/jenga`'s interactive scope-selection flow (E45). Given the raw,
# comma-separated ID string a user typed for `/jenga <ids>` (or IDs
# translated back from picker selection numbers), this script parses each
# comma-delimited segment per the exact grammar negotiated with the user,
# then resolves the parsed candidate against the real board inventory
# produced by `skills/jenga/scripts/board-scan.sh` (E45_S01_T01).
#
# This script NEVER re-scans the board independently — it invokes
# board-scan.sh as a subprocess and reads its JSON stdout as the single
# source of truth for what IDs actually exist. See board-scan.sh's own
# header comment for its output schema.
#
# ---------------------------------------------------------------------------
# GRAMMAR (final — negotiated with the user, do not reinterpret)
# ---------------------------------------------------------------------------
#   1. Strip whitespace, underscores, and punctuation from the input;
#      uppercase it. Only [A-Z0-9] characters survive this step.
#   2. Split each contiguous digit run into 2-digit chunks, left to right.
#      A digit run whose length is not a multiple of 2 is REJECTED as
#      invalid input (never silently truncated or padded).
#   3. A chunk is TAGGED to a level (epic/story/task) when the digit run it
#      came from is immediately adjacent — directly before or directly
#      after, no separator survives step 1 — to a single E/S/T letter.
#   4. Untagged chunks fill the remaining levels positionally, in
#      epic -> story -> task order, left to right, skipping any level
#      already claimed by an explicit tag.
#   5. The parsed candidate (full or partial) is resolved against the board
#      inventory. A partial ID that does not uniquely resolve (e.g. a story
#      chunk with no epic tag, when multiple epics share that story number)
#      is REJECTED and reports that disambiguation is required — never
#      guessed across epics.
#
# Negotiated examples (must resolve exactly as documented):
#   "E01s02"        -> E01_S02
#   "e01 S04 t02"   -> E01_S04_T02
#   "0103"          -> E01_S03   (two untagged chunks: epic=01, story=03)
#
# ---------------------------------------------------------------------------
# USAGE
# ---------------------------------------------------------------------------
#   skills/jenga/scripts/resolve-id.sh "<comma-separated raw ID list>"
#
# Example:
#   skills/jenga/scripts/resolve-id.sh "E01s02, e01 S04 t02, 0103"
#
# Each comma-delimited segment of the argument is parsed and resolved
# independently. Whitespace around commas is insignificant (stripped by the
# grammar itself in step 1, since spaces are whitespace).
#
# ---------------------------------------------------------------------------
# OUTPUT SCHEMA
# ---------------------------------------------------------------------------
# stdout is a single JSON array, one object per input segment, in input
# order. Nothing else is ever written to stdout.
#
#   {
#     "input":       "E01s02",       // the raw segment exactly as given
#     "status":      "resolved" | "rejected",
#     "resolved_id": "E01_S02" | null,
#     "reason":      null | "<human-readable rejection reason>"
#   }
#
# Rejection reasons include (not exhaustive, always human-readable):
#   - "empty input after stripping whitespace/underscores/punctuation"
#   - "malformed digit run: '<run>' has odd length <n> (not a multiple of 2)"
#   - "too many untagged chunks: <n> chunks but only <m> open level(s)"
#   - "no ID chunks found in input"
#   - "conflicting tags: level '<L>' tagged more than once"
#   - "not found on board: <id-or-partial-description>"
#   - "ambiguous partial ID '<partial>': matches <n> candidates
#      (<id1>, <id2>, ...) - disambiguation required"
#
# ---------------------------------------------------------------------------
# EXIT CODES
# ---------------------------------------------------------------------------
#   0   every segment resolved
#   1   at least one segment was rejected (stdout is still valid JSON;
#       callers should inspect each element's "status", not rely on the
#       exit code alone to know WHICH segment failed)
#   2   usage error (no argument given) or board-scan.sh / python3 failure
#       — a real setup problem, not a per-segment parse failure
#
# ---------------------------------------------------------------------------

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Unlike board-scan.sh, this script never reads project/board/ directly —
# it only needs SCRIPT_DIR to locate and invoke board-scan.sh, which does
# its own JENGA_PROJECT_DIR resolution internally. No project-root
# resolution is needed here.
BOARD_SCAN="$SCRIPT_DIR/board-scan.sh"

if [ $# -lt 1 ] || [ -z "${1:-}" ]; then
  echo 'Usage: resolve-id.sh "<comma-separated raw ID list>"' >&2
  exit 2
fi

RAW_INPUT="$1"

if [ ! -x "$BOARD_SCAN" ]; then
  echo "Error: board-scan.sh not found or not executable at $BOARD_SCAN" >&2
  exit 2
fi

if ! command -v python3 >/dev/null 2>&1; then
  echo "Error: python3 is required by resolve-id.sh" >&2
  exit 2
fi

# Capture the board inventory ONCE for this whole run — every segment is
# resolved against the same snapshot, and we never re-scan per segment.
BOARD_JSON="$("$BOARD_SCAN")" || {
  echo "Error: board-scan.sh failed" >&2
  exit 2
}

# The parsing/resolution logic is written to a temp .py file rather than
# piped in via `python3 -` because the board JSON is delivered on stdin —
# `python3 -` would consume stdin itself as the script source, leaving
# nothing for the script's own sys.stdin.read() to see.
PY_SCRIPT="$(mktemp -t resolve-id-XXXXXX.py)"
trap 'rm -f "$PY_SCRIPT"' EXIT

cat > "$PY_SCRIPT" <<'PY'
import json
import re
import sys

raw_input = sys.argv[1]
board_json = sys.stdin.read()

try:
    board = json.loads(board_json)
except Exception as e:
    print(f"Error: could not parse board-scan.sh output as JSON: {e}", file=sys.stderr)
    sys.exit(2)

LEVELS = ("epic", "story", "task")
LEVEL_LETTER = {"epic": "E", "story": "S", "task": "T"}
LETTER_LEVEL = {"E": "epic", "S": "story", "T": "task"}


def strip_and_upper(segment):
    """Grammar step 1: strip whitespace/underscores/punctuation, uppercase.
    Only [A-Za-z0-9] survives."""
    return re.sub(r"[^A-Za-z0-9]", "", segment).upper()


def tokenize(cleaned):
    """Split the cleaned string into an ordered list of
    (kind, value) tokens where kind is 'digits' or 'letters', preserving
    adjacency (walks left to right, alternating runs)."""
    tokens = []
    for m in re.finditer(r"[0-9]+|[A-Z]+", cleaned):
        val = m.group(0)
        kind = "digits" if val.isdigit() else "letters"
        tokens.append((kind, val))
    return tokens


class RejectError(Exception):
    def __init__(self, reason):
        self.reason = reason


def parse_segment(cleaned):
    """Returns a dict {level: '01'} chunk map (2-digit strings) covering
    only the levels present in this candidate. Raises RejectError on any
    grammar violation."""
    if not cleaned:
        raise RejectError("empty input after stripping whitespace/underscores/punctuation")

    tokens = tokenize(cleaned)

    digit_positions = [i for i, (kind, _) in enumerate(tokens) if kind == "digits"]
    if not digit_positions:
        raise RejectError("no ID chunks found in input")

    # Expand every digit run into its 2-digit chunks (grammar step 2),
    # rejecting any run whose length isn't a multiple of 2. Each run keeps
    # its own ordered list of chunk dicts: {"value": "01", "tag": None}.
    runs = []  # list of {"token_pos": i, "chunks": [chunk_dict, ...]}
    for pos in digit_positions:
        run = tokens[pos][1]
        if len(run) % 2 != 0:
            raise RejectError(
                f"malformed digit run: '{run}' has odd length {len(run)} "
                "(not a multiple of 2)"
            )
        run_chunks = [{"value": run[i:i + 2], "tag": None} for i in range(0, len(run), 2)]
        runs.append({"token_pos": pos, "chunks": run_chunks})

    run_by_token_pos = {r["token_pos"]: r for r in runs}

    # Tag assignment (grammar step 3), one pass over LETTER tokens. A tag
    # letter run must be a SINGLE E/S/T letter — a multi-letter run, or a
    # letter that isn't E/S/T, is not a valid tag and is ignored (treated
    # as noise, not a rejection).
    #
    # Adjacency priority when a single tag letter sits BETWEEN two digit
    # runs (e.g. "E01S02" — the 'S' is simultaneously "after 01" and
    # "before 02"): the letter tags the FOLLOWING run's FIRST chunk, never
    # the preceding run's last chunk. This is what makes the negotiated
    # examples parse correctly — "E01s02" reads as E=epic(01), S=story(02),
    # not as a conflict between the two adjacencies of the same 'S'. A
    # trailing letter with NO digit run after it (a true suffix tag, e.g.
    # "0102T" with nothing following the T) falls back to tagging the
    # PRECEDING run's LAST chunk, since there is no following run to prefer.
    for i, (kind, val) in enumerate(tokens):
        if kind != "letters" or len(val) != 1 or val not in LETTER_LEVEL:
            continue
        level = LETTER_LEVEL[val]

        target_chunk = None
        if i + 1 < len(tokens) and tokens[i + 1][0] == "digits":
            target_chunk = run_by_token_pos[i + 1]["chunks"][0]
        elif i - 1 >= 0 and tokens[i - 1][0] == "digits":
            target_chunk = run_by_token_pos[i - 1]["chunks"][-1]

        if target_chunk is None:
            continue

        if target_chunk["tag"] is not None and target_chunk["tag"] != level:
            raise RejectError(
                f"conflicting tags around chunk '{target_chunk['value']}': "
                f"adjacent to both {LEVEL_LETTER[target_chunk['tag']]} and {val}"
            )
        target_chunk["tag"] = level

    chunks = [c for r in runs for c in r["chunks"]]

    # Assign tagged chunks to their levels, rejecting duplicate tags for the
    # same level (grammar step 3/4) — e.g. two separate digit runs both
    # tagged 'E'.
    result = {}
    tagged_chunks = [c for c in chunks if c["tag"] is not None]
    untagged_chunks = [c for c in chunks if c["tag"] is None]

    for c in tagged_chunks:
        level = c["tag"]
        if level in result:
            raise RejectError(
                f"conflicting tags: level '{LEVEL_LETTER[level]}' tagged more than once"
            )
        result[level] = c["value"]

    # Untagged chunks fill remaining levels positionally, epic -> story ->
    # task, left to right, skipping levels already claimed by a tag.
    open_levels = [lvl for lvl in LEVELS if lvl not in result]
    if len(untagged_chunks) > len(open_levels):
        raise RejectError(
            f"too many untagged chunks: {len(untagged_chunks)} chunks but "
            f"only {len(open_levels)} open level(s)"
        )
    for c, level in zip(untagged_chunks, open_levels):
        result[level] = c["value"]

    return result


def candidate_id_fragments(level_map):
    """Given {'epic': '01', 'story': '02'}, produce per-level ID fragments
    ('epic': 'E01', 'story': 'S02', ...) used for board matching."""
    return {lvl: f"{LEVEL_LETTER[lvl]}{val}" for lvl, val in level_map.items()}


def item_levels(item_id):
    """Split a board id like 'E01_S02_T03' into {'epic': 'E01', ...}."""
    parts = item_id.split("_")
    levels = {}
    if len(parts) >= 1 and parts[0].startswith("E"):
        levels["epic"] = parts[0]
    if len(parts) >= 2 and parts[1].startswith("S"):
        levels["story"] = parts[1]
    if len(parts) >= 3 and parts[2].startswith("T"):
        levels["task"] = parts[2]
    return levels


def resolve_against_board(level_map, board):
    """Resolve a parsed level_map against the board inventory. Returns
    (resolved_id, None) on unique success, or (None, reason) on failure.

    The candidate's TYPE is the deepest level present in level_map (e.g.
    {epic, story} targets a story, {epic, story, task} targets a task,
    {story} alone still targets a story — just an under-specified one).
    Restricting the match to items of exactly that `type` (the field
    board-scan.sh already emits) is what keeps a story-level candidate
    like "0103" (epic=01, story=03, no task) resolving to the STORY
    'E01_S03' itself rather than colliding with every task underneath it —
    without this restriction, a levels-only filter would also match
    'E01_S03_T01', 'E01_S03_T02', etc., since they share the same
    epic/story numbers.

    For a genuinely partial candidate missing shallower levels (e.g. only
    a story chunk with no epic tag), the same type-restricted filter
    naturally requires uniqueness ACROSS epics, which is exactly the
    disambiguation guarantee the grammar spec requires."""
    if not level_map:
        return None, "no ID chunks found in input"

    frag = candidate_id_fragments(level_map)
    deepest = max(level_map.keys(), key=LEVELS.index)

    def matches(item):
        if item.get("type") != deepest:
            return False
        levels = item_levels(item.get("id", ""))
        for lvl, want in frag.items():
            if levels.get(lvl) != want:
                return False
        return True

    matches_list = [item for item in board if matches(item)]

    partial_desc = ", ".join(f"{lvl}={v}" for lvl, v in frag.items())

    if len(matches_list) == 1:
        return matches_list[0]["id"], None
    if len(matches_list) == 0:
        return None, f"not found on board: {partial_desc}"

    ids = sorted(m["id"] for m in matches_list)
    preview = ", ".join(ids[:8]) + (", ..." if len(ids) > 8 else "")
    return None, (
        f"ambiguous partial ID '{partial_desc}': matches {len(matches_list)} "
        f"candidates ({preview}) - disambiguation required"
    )


results = []
any_rejected = False

segments = raw_input.split(",") if raw_input.strip() != "" else []

for raw_segment in segments:
    entry = {"input": raw_segment, "status": None, "resolved_id": None, "reason": None}
    try:
        cleaned = strip_and_upper(raw_segment)
        level_map = parse_segment(cleaned)
        resolved_id, reason = resolve_against_board(level_map, board)
        if resolved_id is not None:
            entry["status"] = "resolved"
            entry["resolved_id"] = resolved_id
        else:
            entry["status"] = "rejected"
            entry["reason"] = reason
            any_rejected = True
    except RejectError as e:
        entry["status"] = "rejected"
        entry["reason"] = e.reason
        any_rejected = True
    results.append(entry)

print(json.dumps(results, indent=2))
sys.exit(1 if any_rejected else 0)
PY

python3 "$PY_SCRIPT" "$RAW_INPUT" <<< "$BOARD_JSON"
exit $?
