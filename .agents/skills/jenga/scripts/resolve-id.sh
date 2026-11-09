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
# GRAMMAR (two-digit chunks negotiated with the user; revised under E86)
# ---------------------------------------------------------------------------
#   History: the original grammar (E45) chunked every digit run into two-digit
#   pieces and was marked "final - negotiated with the user, do not
#   reinterpret". It could not express item numbers of three or more digits
#   (E100, E1001_S100_T02). It was REVISED under epic E86 (E86_S03_T02) on
#   2026-10-25 WITH THE USER'S EXPLICIT APPROVAL (E86 brainstorm); this
#   revision supersedes the old "final" two-digit grammar. The two-digit
#   behaviour below is unchanged: whatever resolved on a two-digit board
#   before still resolves to the same ID.
#
#   1. Uppercase the input and strip whitespace, underscores and punctuation,
#      except that a separator sitting BETWEEN TWO DIGIT RUNS is kept as a run
#      boundary ("100 2" is the runs 100 and 2, not the run 1002). Any other
#      separator is dropped, so letter/digit adjacency ignores separators
#      exactly as before ("e 01" still tags 01).
#   2. A digit run is TAGGED when a single E/S/T letter is adjacent to it:
#      a letter tags the run that FOLLOWS it; a trailing letter with no digit
#      run after it tags the run before it. A multi-letter run or any other
#      letter is noise and tags nothing.
#   3. A TAGGED run is that level's number at ANY width, compared numerically
#      ("e100s2" -> epic 100, story 2; "E001" = epic 1; "e10s1" never
#      matches E100_S01). Overlap rule: an even-length tagged run of 4 or 6
#      digits also has the LEGACY reading, where the run is cut into two-digit
#      chunks, the chunk next to the letter is tagged and the rest are
#      untagged ("E0102" = E01 plus an untagged 02 = E01_S02). Both readings
#      are tried against the board: only the legacy reading resolving keeps
#      the legacy ID, only the wide reading resolving uses the wide ID, and if
#      BOTH resolve the input is rejected as ambiguous and asks for letters or
#      separators - never guessed. Example: with E01_S02 and E102 on the
#      board, "e0102" is rejected; "e01s02" and "e102" are not.
#   4. An UNTAGGED run is chunked into two-digit pieces only when its length
#      is even, at most 6 digits, and no chunk is "00" (numbering starts at
#      01). A separator-bounded untagged run that fails that cut-off is one
#      whole number ("100 2" -> epic 100, story 2). A bare untagged run that
#      fails it is REJECTED with a message naming the fix: odd length
#      ("10002", "010", "100"), a "00" chunk ("1000"), or longer than 6 digits
#      (an even run such as "0102030405" keeps the earlier "too many untagged
#      chunks" rejection).
#   5. Tagged numbers claim their level; untagged pieces fill the remaining
#      levels positionally, epic -> story -> task, left to right.
#   6. The candidate (full or partial) is resolved against the board
#      inventory with NUMERIC level matching. A partial ID that does not
#      uniquely resolve (e.g. a story number with no epic when several epics
#      have it, including an epic E100) is REJECTED and reports that
#      disambiguation is required - never guessed across epics.
#
# Examples (must resolve exactly as documented):
#   "E01s02"          -> E01_S02
#   "e01 S04 t02"     -> E01_S04_T02
#   "0103"            -> E01_S03     (two untagged chunks: epic=01, story=03)
#   "e100s2"          -> E100_S02    (tagged runs are numbers of any width)
#   "100 2"           -> E100_S02    (separator-bounded untagged runs)
#   "e1001 s100 t2"   -> E1001_S100_T02
#   "10002"           -> rejected    (odd untagged run: use e100s02 or "100 02")
#   "1000"            -> rejected    (a 00 chunk is never a board number: use
#                                     letters or separators, e.g. e100s02)
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
#   - "digit run '<run>' cannot be read unambiguously (<why>); use letters or
#      separators, e.g. e100s02 or '100 2'"   (odd length, a 00 chunk, or
#      more than 6 digits in a bare untagged run)
#   - "ambiguous digit run in '<input>': it reads as <id1> or <id2> on this
#      board - use letters or separators to say which, e.g. <id1-lower> ..."
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
import itertools
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


SEP = "\x00"  # run boundary between two digit runs (grammar step 1)
FIX_HINT = "use letters or separators, e.g. e100s02 or '100 2'"


def strip_and_upper(segment):
    """Grammar step 1: uppercase, strip whitespace/underscores/punctuation.
    A separator between two digit runs survives as SEP so the runs stay
    separate ('100 2' is 100 and 2, never 1002); every other separator is
    dropped, which keeps letter/digit adjacency exactly as before."""
    s = segment.upper()
    s = re.sub(r"(?<=[0-9])[^A-Z0-9]+(?=[0-9])", SEP, s)
    return re.sub(r"[^A-Z0-9" + SEP + "]", "", s)


def tokenize(cleaned):
    """Split the cleaned string into ordered (kind, value) tokens, kind being
    'digits', 'letters' or 'sep' (a SEP boundary, only ever between two digit
    runs)."""
    tokens = []
    for m in re.finditer(r"[0-9]+|[A-Z]+|" + SEP, cleaned):
        val = m.group(0)
        kind = "sep" if val == SEP else ("digits" if val.isdigit() else "letters")
        tokens.append((kind, val))
    return tokens


class RejectError(Exception):
    def __init__(self, reason):
        self.reason = reason


def chunks_of(run):
    return [run[i:i + 2] for i in range(0, len(run), 2)]


def can_chunk(run):
    """Untagged cut-off (grammar step 4): even length, at most 6 digits, no
    '00' chunk."""
    return len(run) % 2 == 0 and len(run) <= 6 and "00" not in chunks_of(run)


def untagged_pieces(run, bounded):
    """Pieces [(int, None)] for an untagged digit run."""
    if can_chunk(run):
        return [(int(c), None) for c in chunks_of(run)]
    if bounded:
        return [(int(run), None)]
    if len(run) % 2 == 0 and len(run) > 6 and "00" not in chunks_of(run):
        # Even and long: chunking yields more chunks than levels; the
        # established "too many untagged chunks" rejection applies.
        return [(int(c), None) for c in chunks_of(run)]
    if len(run) % 2 != 0:
        why = f"odd length {len(run)}"
    elif "00" in chunks_of(run):
        why = "contains a 00 chunk and numbering starts at 01"
    else:
        why = f"{len(run)} digits is more than 6"
    raise RejectError(f"digit run '{run}' cannot be read unambiguously ({why}); {FIX_HINT}")


def analyse(cleaned):
    """Tokenize and attach tags. Returns a list of run dicts in input order:
    {run, pre, post, bounded}. 'pre' is the level of a letter that tags this
    run from before it, 'post' of a trailing letter with no digit run after
    it (grammar step 2)."""
    if not cleaned:
        raise RejectError("empty input after stripping whitespace/underscores/punctuation")

    tokens = tokenize(cleaned)
    if not any(kind == "digits" for kind, _ in tokens):
        raise RejectError("no ID chunks found in input")

    runs = {}
    for i, (kind, val) in enumerate(tokens):
        if kind == "digits":
            bounded = (i > 0 and tokens[i - 1][0] == "sep") or (
                i + 1 < len(tokens) and tokens[i + 1][0] == "sep")
            runs[i] = {"run": val, "pre": None, "post": None, "bounded": bounded,
                       "pre_letter": None, "post_letter": None}

    # A single E/S/T letter tags the FOLLOWING digit run; only when no digit
    # run follows it does it fall back to tagging the PRECEDING run. Any
    # other letter run is noise.
    for i, (kind, val) in enumerate(tokens):
        if kind != "letters" or len(val) != 1 or val not in LETTER_LEVEL:
            continue
        level = LETTER_LEVEL[val]
        if i + 1 < len(tokens) and tokens[i + 1][0] == "digits":
            slot, target = "pre", runs[i + 1]
        elif i - 1 >= 0 and tokens[i - 1][0] == "digits":
            slot, target = "post", runs[i - 1]
        else:
            continue
        if target[slot] is not None and target[slot] != level:
            raise RejectError(
                f"conflicting tags around chunk '{target['run']}': "
                f"adjacent to both {target[slot + '_letter']} and {val}"
            )
        target[slot] = level
        target[slot + "_letter"] = val
    return [runs[k] for k in sorted(runs)]


def run_readings(r):
    """The ordered alternatives for one run. Each alternative is a list of
    (int_value, tag_level_or_None) pieces, or a RejectError when that
    reading is itself invalid. There is more than one alternative only for an
    even-length TAGGED run of 4 or 6 digits (legacy chunks first, then the
    wide single number): the E0102 overlap rule, grammar step 3."""
    run, pre, post = r["run"], r["pre"], r["post"]
    if pre is None and post is None:
        return [untagged_pieces(run, r["bounded"])]

    def wide():
        if pre is not None and post is not None and pre != post:
            return RejectError(
                f"conflicting tags around chunk '{run}': "
                f"adjacent to both {r['pre_letter']} and {r['post_letter']}"
            )
        return [(int(run), pre if pre is not None else post)]

    def legacy():
        cs = chunks_of(run)
        pieces = [[int(c), None] for c in cs]
        for tag, idx, letter in ((pre, 0, r["pre_letter"]), (post, -1, r["post_letter"])):
            if tag is None:
                continue
            if pieces[idx][1] is not None and pieces[idx][1] != tag:
                return RejectError(
                    f"conflicting tags around chunk '{cs[idx]}': "
                    f"adjacent to both {LEVEL_LETTER[pieces[idx][1]]} and {letter}"
                )
            pieces[idx][1] = tag
        return [tuple(p) for p in pieces]

    if len(run) in (4, 6):
        return [legacy(), wide()]
    alt = wide()
    if isinstance(alt, RejectError):
        raise alt
    return [alt]


def assemble(pieces):
    """Grammar step 5: tagged pieces claim their level (duplicates conflict);
    untagged pieces fill the open levels epic -> story -> task."""
    result = {}
    untagged = []
    for value, tag in pieces:
        if tag is None:
            untagged.append(value)
        elif tag in result:
            raise RejectError(
                f"conflicting tags: level '{LEVEL_LETTER[tag]}' tagged more than once"
            )
        else:
            result[tag] = value
    open_levels = [lvl for lvl in LEVELS if lvl not in result]
    if len(untagged) > len(open_levels):
        raise RejectError(
            f"too many untagged chunks: {len(untagged)} chunks but "
            f"only {len(open_levels)} open level(s)"
        )
    for value, level in zip(untagged, open_levels):
        result[level] = value
    return result


def candidate_maps(cleaned):
    """Returns the alternative readings of a segment as a list (legacy-first,
    a single entry when unambiguous). Each entry is a {level: int} map or the
    RejectError that reading raised."""
    per_run = [run_readings(r) for r in analyse(cleaned)]
    out = []
    for combo in itertools.product(*per_run):
        bad = next((a for a in combo if isinstance(a, RejectError)), None)
        if bad is not None:
            out.append(bad)
            continue
        try:
            out.append(assemble([p for alt in combo for p in alt]))
        except RejectError as e:
            out.append(e)
    return out


def fmt(value):
    """Zero-padded to at least two digits ('E09', 'E100')."""
    return f"{value:02d}"


def item_levels(item_id):
    """Split a board id like 'E01_S02_T03' into {'epic': 1, 'story': 2,
    'task': 3} (numeric, so 'E100' is 100 and never matches 'E10')."""
    levels = {}
    for part in item_id.split("_"):
        m = re.fullmatch(r"([EST])([0-9]+)", part)
        if m:
            levels[LETTER_LEVEL[m.group(1)]] = int(m.group(2))
    return levels


def resolve_against_board(level_map, board):
    """Resolve a parsed level_map ({level: int}) against the board inventory.
    Returns (resolved_id, reason, hits): resolved_id on unique success,
    otherwise None plus a reason; hits is how many board items matched
    (0 = not found, >1 = ambiguous), which the overlap rule uses.

    The candidate's TYPE is the deepest level present in level_map (e.g.
    {epic, story} targets a story, {epic, story, task} targets a task,
    {story} alone still targets a story - just an under-specified one).
    Restricting the match to items of exactly that `type` (the field
    board-scan.sh already emits) is what keeps a story-level candidate
    like "0103" (epic=01, story=03, no task) resolving to the STORY
    'E01_S03' itself rather than colliding with every task underneath it.

    Level numbers are compared NUMERICALLY, so 'e100s2' matches E100_S02 and
    'e10s1' never matches E100_S01. For a genuinely partial candidate missing
    shallower levels (e.g. only a story number with no epic), the same
    type-restricted filter requires uniqueness ACROSS epics, which is the
    disambiguation guarantee the grammar requires."""
    if not level_map:
        return None, "no ID chunks found in input", 0

    deepest = max(level_map.keys(), key=LEVELS.index)

    def matches(item):
        if item.get("type") != deepest:
            return False
        levels = item_levels(item.get("id", ""))
        return all(levels.get(lvl) == want for lvl, want in level_map.items())

    matches_list = [item for item in board if matches(item)]

    partial_desc = ", ".join(f"{lvl}={LEVEL_LETTER[lvl]}{fmt(v)}" for lvl, v in level_map.items())

    if len(matches_list) == 1:
        return matches_list[0]["id"], None, 1
    if len(matches_list) == 0:
        return None, f"not found on board: {partial_desc}", 0

    ids = sorted(m["id"] for m in matches_list)
    preview = ", ".join(ids[:8]) + (", ..." if len(ids) > 8 else "")
    return None, (
        f"ambiguous partial ID '{partial_desc}': matches {len(matches_list)} "
        f"candidates ({preview}) - disambiguation required"
    ), len(matches_list)


def resolve_segment(raw_segment, board):
    """Parse and resolve one segment; returns (resolved_id, reason).

    Normally a single reading. When a tagged 4/6-digit run has both the
    legacy (E0102 = E01 + 02) and the wide reading, the readings that match
    something on the board decide: one hit wins, several different hits are
    rejected as ambiguous (grammar step 3)."""
    outcomes = []  # (kind, resolved_id, reason, hits, level_map)
    for cand in candidate_maps(strip_and_upper(raw_segment)):
        if isinstance(cand, RejectError):
            outcomes.append((cand.reason, None, 0))
        else:
            rid, reason, hits = resolve_against_board(cand, board)
            outcomes.append((reason, rid, hits))

    hit = [o for o in outcomes if o[2] > 0]
    if not hit:
        return None, outcomes[0][0]
    distinct = []
    for reason, rid, _hits in hit:
        label = rid if rid is not None else reason
        if label not in distinct:
            distinct.append(label)
    if len(distinct) == 1:
        return hit[0][1], hit[0][0]

    ids = [o[1] for o in hit if o[1] is not None]
    hint = " or ".join(i.replace("_", "").lower() for i in dict.fromkeys(ids))
    names = " and ".join(distinct) if all(o[1] is not None for o in hit) else (
        f"{len(distinct)} different items")
    return None, (
        f"ambiguous digit run in '{raw_segment.strip()}': it reads as {names} on this "
        "board - use letters or separators to say which"
        + (f", e.g. {hint}" if hint else "")
    )


results = []
any_rejected = False

segments = raw_input.split(",") if raw_input.strip() != "" else []

for raw_segment in segments:
    entry = {"input": raw_segment, "status": None, "resolved_id": None, "reason": None}
    try:
        resolved_id, reason = resolve_segment(raw_segment, board)
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
