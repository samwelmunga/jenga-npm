#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# skills/reconcile/scripts/resolve-reconcile-scope.sh
#
# Deterministic scope-argument resolver backing `/reconcile`'s new scope
# argument (story E17_S07). This script owns ALL scope-argument parsing and
# id-range expansion for `/reconcile` — `skills/reconcile/SKILL.md` (wired in
# the sibling task E17_S07_T02) only interprets this script's structured
# stdout output; it must not re-derive any parsing or resolution logic
# inline.
#
# ---------------------------------------------------------------------------
# REUSE CONTRACT — do not re-derive
# ---------------------------------------------------------------------------
# This script NEVER re-scans the board or re-implements id-grammar parsing.
# It shells out to the two scripts `/reconcile` and `/uncharted` already
# share:
#
#   skills/jenga/scripts/board-scan.sh   Single source of truth for board
#                                        inventory (epics/stories/tasks,
#                                        their statuses and parent ids).
#                                        Called at most ONCE per invocation
#                                        of this script.
#
#   skills/jenga/scripts/resolve-id.sh   The documented fuzzy-ID grammar
#                                        parser. Resolves one or more
#                                        comma-separated bare/tagged id
#                                        segments (e.g. "E12", "S03",
#                                        "E12_S03_T01") against the board
#                                        inventory. EVERY individual id this
#                                        script needs resolved — a plain
#                                        single argument, or every member of
#                                        an expanded range — goes through
#                                        one call to resolve-id.sh. This
#                                        script adds NO second id parser.
#
# Range expansion itself (e.g. "S03-05" -> S03, S04, S05) is new logic that
# belongs here, layered ON TOP OF resolve-id.sh's per-id resolution — neither
# board-scan.sh nor resolve-id.sh understands ranges. Once expanded, each
# range member is just another candidate segment fed to resolve-id.sh
# alongside the plain-argument case, in the same single batch call.
#
# ---------------------------------------------------------------------------
# INVOCATION
# ---------------------------------------------------------------------------
#   resolve-reconcile-scope.sh [<scope-argument>]
#
# ---------------------------------------------------------------------------
# RESOLUTION RULES (settled — see E17_S07's Background/AC, do not relitigate)
# ---------------------------------------------------------------------------
#   No argument              -> full-board scope, unchanged from today's
#                                `/reconcile` behavior.
#   Bare epic id               e.g. "E12"
#                             -> scope is that epic, in full.
#   Bare story id               e.g. "E12_S03", or "S03" if resolve-id.sh
#                              resolves it unambiguously
#                             -> scope defaults to the story's CONTAINING
#                                EPIC, in full (default-scope-to-epic rule:
#                                rollup can't be evaluated correctly without
#                                seeing all sibling stories/tasks).
#   Bare task id                e.g. "E12_S03_T01"
#                             -> same default-scope-to-epic rule as above.
#   A range                     e.g. "S03-05" or "E12_S03-05"
#                             -> scope is EXACTLY the named stories (and
#                                their tasks), plus rollup limited to only
#                                the epic(s) those named stories belong to.
#                                Does NOT expand to unrelated stories in the
#                                same epic(s). Only STORY-level ranges are
#                                supported — an epic-level range (e.g.
#                                "E01-03") or a task-level range (e.g.
#                                "T01-03") is rejected with a clear reason,
#                                never silently reinterpreted.
#   Invalid/unresolvable input  unknown id, malformed range, an ambiguous
#                              partial that resolve-id.sh itself would
#                              reject
#                             -> a structured error, non-zero exit, NOTHING
#                                else written to stdout. No partial result,
#                                no silent full-board fallback.
#
# ---------------------------------------------------------------------------
# RANGE GRAMMAR (new logic owned by this script)
# ---------------------------------------------------------------------------
# A range argument matches, case-insensitively:
#
#   ^(E[0-9]+_?)?S([0-9]{1,3})-([0-9]{1,3})$
#
# i.e. an optional epic tag ("E12" or "E12_"), followed by a story tag "S",
# followed by <start>-<end>. Examples: "S03-05", "E12_S03-05", "e12s3-5".
#
# Expansion:
#   1. start/end are parsed as integers; start must be <= end, and the span
#      is capped at 100 stories (defensive — a wider range is almost
#      certainly a typo, not a real request).
#   2. Each number in [start, end] is zero-padded to the wider of the two
#      input widths (minimum 2 digits, matching this board's "S03"/"T01"
#      convention) and combined with the (optional) epic tag into a
#      candidate segment, e.g. "E12_S03", "E12_S04", "E12_S05".
#   3. ALL candidate segments are resolved in a SINGLE comma-separated call
#      to resolve-id.sh (its documented batch interface) — one subprocess,
#      not one per number. A candidate with no epic tag (bare "S03") still
#      works: resolve-id.sh resolves it against the whole board and rejects
#      it as ambiguous if more than one epic has a story numbered 03,
#      exactly like a normal bare "S03" invocation would.
#   4. If ANY candidate segment comes back "rejected", the whole range fails
#      with that segment's own rejection reason (first rejection found, in
#      input order) — no partial range is ever resolved.
#   5. resolve-id.sh's own type-restriction rule guarantees every resolved
#      id here is a STORY id (the parsed level_map for each candidate never
#      includes a task chunk), which this script's Python driver still
#      double-checks defensively against the board inventory before trusting
#      it.
#
# A non-range argument that still contains "-" (an epic range, a task range,
# stray punctuation) does NOT match the grammar above and falls straight
# into the single-id path below, where resolve-id.sh's own grammar produces
# its own real rejection reason — this script does not add a second,
# possibly-inconsistent error message for that case.
#
# ---------------------------------------------------------------------------
# OUTPUT CONTRACT (stdout, single JSON object, nothing else)
# ---------------------------------------------------------------------------
#   {
#     "scope_type":       "full" | "epic" | "range",
#     "epic_ids":         ["E12"],
#     "story_ids":        ["E12_S03", "E12_S04", "E12_S05"],
#     "task_ids":         ["E12_S03_T01", "..."],
#     "owned_path_hints": ["skills/reconcile/", "..."]
#   }
#
#   scope_type "full"   epic_ids/story_ids/task_ids are all EMPTY arrays.
#                        Consumers treat this exactly like today's unscoped
#                        `/reconcile` run.
#   scope_type "epic"   epic_ids has exactly one element (the target epic);
#                        story_ids/task_ids list every story/task on the
#                        board whose epic_id is that epic — the FULL epic,
#                        per the default-scope-to-epic rule, regardless of
#                        whether the input argument named the epic directly
#                        or named a story/task inside it.
#   scope_type "range"  epic_ids lists every DISTINCT epic the resolved
#                        stories belong to (may be more than one if a bare
#                        "S03-05" range happens to resolve across epics);
#                        story_ids is EXACTLY the resolved range members
#                        (never expanded to siblings); task_ids is every
#                        task on the board whose story_id is one of those
#                        stories.
#
#   owned_path_hints     Best-effort, NON-AUTHORITATIVE list of path
#                        prefixes the resolved scope's own stories/tasks
#                        (and, for an epic scope, the epic file itself if it
#                        carries one) reference via their `docs:`
#                        frontmatter field — the ONLY place this script
#                        looks (it does NOT scan Acceptance Criteria prose
#                        for paths; that would be a second, heuristic
#                        path-finder and this stays intentionally narrow).
#                        Sorted, de-duplicated, may be EMPTY — an empty list
#                        is a valid, normal result. Downstream phases
#                        (E17_S07_T02) must treat a path they cannot
#                        attribute to the scope as UNFILTERED evidence,
#                        never as proof of exclusion.
#
#   On error:  {"status":"error","reason":"<clear, specific message>"}
#              and a non-zero exit code — matching the same error-contract
#              shape resolve-id.sh and cascade-resolve.sh already use for
#              their own unresolved/malformed cases.
#
# ---------------------------------------------------------------------------
# EXIT CODES
# ---------------------------------------------------------------------------
#   0   scope resolved; stdout is the single JSON scope object described
#       above (never the error object on this path)
#   1   scope could not be resolved (unknown id, malformed range, ambiguous
#       partial); stdout is ONLY the {"status":"error",...} object above
#   2   environment error (board-scan.sh / resolve-id.sh missing or not
#       executable, python3 unavailable, either subprocess failing outright)
#       — a real setup problem, reported the same way as a resolution error
#       (stdout is the error object) so every non-zero exit is uniformly
#       safe for a caller to treat as "stop, do not touch any board file"
#
# Requires: bash, python3. No new dependency beyond what board-scan.sh and
# resolve-id.sh already require.
# ---------------------------------------------------------------------------

set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)

BOARD_SCAN="$SCRIPT_DIR/../../jenga/scripts/board-scan.sh"
RESOLVE_ID="$SCRIPT_DIR/../../jenga/scripts/resolve-id.sh"

# Resolve JENGA_PROJECT_DIR the same way board-scan.sh does (CLAUDE_PROJECT_DIR -> git toplevel ->
# cwd) — needed here only to locate the resolved scope's board files for owned_path_hints.
if [ -f "$SCRIPT_DIR/../../../lib/resolve-project-dir.sh" ]; then
  # shellcheck source=lib/resolve-project-dir.sh
  source "$SCRIPT_DIR/../../../lib/resolve-project-dir.sh"
elif [ -n "${CLAUDE_PROJECT_DIR:-}" ]; then
  JENGA_PROJECT_DIR="$CLAUDE_PROJECT_DIR"
else
  JENGA_PROJECT_DIR="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel 2>/dev/null || pwd)"
fi

emit_error() {
  # emit_error <reason>
  # The ONLY thing ever written to stdout on an error path, per the output
  # contract above. Uses python3 for correct JSON string escaping rather
  # than hand-rolled shell quoting.
  python3 -c '
import json, sys
print(json.dumps({"status": "error", "reason": sys.argv[1]}))
' "$1"
}

die_error() {
  # die_error <reason> <exit-code>
  emit_error "$1"
  exit "${2:-1}"
}

# --- environment checks ------------------------------------------------------------------------
command -v python3 >/dev/null 2>&1 || die_error "python3 is required but was not found on PATH" 2
[ -x "$BOARD_SCAN" ] || die_error "board-scan.sh not found or not executable at $BOARD_SCAN" 2
[ -x "$RESOLVE_ID" ] || die_error "resolve-id.sh not found or not executable at $RESOLVE_ID" 2

if [ "$#" -gt 1 ]; then
  die_error "at most one scope-argument is accepted (got $#); combine multiple ids with a range, or invoke separately" 1
fi

RAW_ARG="${1:-}"

# --- case: no argument -> full-board scope, no board scan needed --------------------------------
if [ -z "$RAW_ARG" ]; then
  python3 -c '
import json
print(json.dumps({
    "scope_type": "full",
    "epic_ids": [],
    "story_ids": [],
    "task_ids": [],
    "owned_path_hints": []
}))
'
  exit 0
fi

# --- detect a story-level range -------------------------------------------------------------
# Matches "S03-05" and "E12_S03-05" (and loose variants like "e12s3-5"), case-insensitively. Any
# other use of "-" (epic range, task range, stray punctuation) does NOT match and falls through
# to the single-id path below, where resolve-id.sh's own grammar produces its own real rejection.
RANGE_RE='^([Ee][0-9]+_?)?[Ss]([0-9]{1,3})-([0-9]{1,3})$'

IS_RANGE=0
CANDIDATES=""

if [[ "$RAW_ARG" =~ $RANGE_RE ]]; then
  IS_RANGE=1
  EPIC_TAG="${BASH_REMATCH[1]}"
  START_STR="${BASH_REMATCH[2]}"
  END_STR="${BASH_REMATCH[3]}"

  EPIC_TAG_NORM="$(printf '%s' "$EPIC_TAG" | tr '[:lower:]' '[:upper:]' | tr -d '_')"

  START_NUM=$((10#$START_STR))
  END_NUM=$((10#$END_STR))

  if [ "$START_NUM" -gt "$END_NUM" ]; then
    die_error "malformed range '$RAW_ARG': start (S$START_STR) is greater than end (S$END_STR)" 1
  fi
  SPAN=$((END_NUM - START_NUM + 1))
  if [ "$SPAN" -gt 100 ]; then
    die_error "malformed range '$RAW_ARG': spans $SPAN stories, which exceeds the 100-story safety cap — check for a typo" 1
  fi

  WIDTH=${#START_STR}
  if [ "${#END_STR}" -gt "$WIDTH" ]; then
    WIDTH="${#END_STR}"
  fi
  if [ "$WIDTH" -lt 2 ]; then
    WIDTH=2
  fi

  N="$START_NUM"
  while [ "$N" -le "$END_NUM" ]; do
    PADDED="$(printf "%0${WIDTH}d" "$N")"
    if [ -n "$EPIC_TAG_NORM" ]; then
      SEG="${EPIC_TAG_NORM}_S${PADDED}"
    else
      SEG="S${PADDED}"
    fi
    if [ -z "$CANDIDATES" ]; then
      CANDIDATES="$SEG"
    else
      CANDIDATES="${CANDIDATES},${SEG}"
    fi
    N=$((N + 1))
  done
elif [[ "$RAW_ARG" == *-* ]]; then
  # Contains a "-" but doesn't match the supported story-range grammar (e.g. an epic range
  # "E01-03", a task range "T01-03", or stray punctuation). Reject explicitly HERE rather than
  # letting it fall through to resolve-id.sh: that script's grammar strips "-" as punctuation
  # (step 1) and can coincidentally re-parse the remaining digits into a DIFFERENT, unintended id
  # that happens to exist on the board (e.g. "E01-03" -> stripped to "E0103" -> misread as
  # epic=E01 alone once the "03" chunk has nowhere else to land) — a silent misresolution, which
  # is exactly what the "no partial result and no silent fallback" requirement rules out.
  die_error "unsupported range syntax '$RAW_ARG': only story-level ranges (e.g. 'S03-05' or 'E12_S03-05') are supported" 1
else
  CANDIDATES="$RAW_ARG"
fi

# --- board inventory, fetched ONCE ---------------------------------------------------------------
BOARD_JSON="$("$BOARD_SCAN" 2>/tmp/resolve-reconcile-scope.board-scan.$$.err)" || {
  ERR_MSG="$(cat "/tmp/resolve-reconcile-scope.board-scan.$$.err" 2>/dev/null)"
  rm -f "/tmp/resolve-reconcile-scope.board-scan.$$.err"
  die_error "board-scan.sh failed: ${ERR_MSG:-unknown error}" 2
}
rm -f "/tmp/resolve-reconcile-scope.board-scan.$$.err"

# --- resolve every candidate segment in ONE batch call to resolve-id.sh -------------------------
set +e
RESOLVE_OUT="$("$RESOLVE_ID" "$CANDIDATES" 2>/tmp/resolve-reconcile-scope.resolve-id.$$.err)"
RESOLVE_RC=$?
set -e
RESOLVE_ERR="$(cat "/tmp/resolve-reconcile-scope.resolve-id.$$.err" 2>/dev/null)"
rm -f "/tmp/resolve-reconcile-scope.resolve-id.$$.err"

if [ "$RESOLVE_RC" -eq 2 ]; then
  die_error "resolve-id.sh failed while resolving '$RAW_ARG': ${RESOLVE_ERR:-unknown error}" 2
fi
# RESOLVE_RC is 0 (every segment resolved) or 1 (at least one rejected) at this point — both leave
# valid JSON on stdout, per resolve-id.sh's own documented contract.

# --- drive the rest from one Python script (board lookups, scope assembly, owned_path_hints) ----
# Written to a temp file rather than piped in via `python3 -`, matching resolve-id.sh's own
# convention: the board JSON is delivered on stdin, and `python3 -` would consume stdin as the
# script source instead of leaving it for sys.stdin.read().
PY_SCRIPT="$(mktemp -t resolve-reconcile-scope-XXXXXX.py)"
trap 'rm -f "$PY_SCRIPT"' EXIT

cat > "$PY_SCRIPT" <<'PY'
import json
import os
import re
import sys

raw_arg, is_range_s, resolve_out_s, project_dir = sys.argv[1:5]
is_range = is_range_s == "1"
board_json = sys.stdin.read()


def emit_error(reason):
    print(json.dumps({"status": "error", "reason": reason}))
    sys.exit(1)


try:
    resolve_results = json.loads(resolve_out_s)
except Exception as e:
    emit_error("could not parse resolve-id.sh output: %s" % e)

try:
    board = json.loads(board_json)
except Exception as e:
    emit_error("could not parse board-scan.sh output: %s" % e)

by_id = {item["id"]: item for item in board if item.get("id")}

rejected = [r for r in resolve_results if r.get("status") != "resolved"]
if rejected:
    r = rejected[0]
    label = "range member" if is_range else "id"
    emit_error(
        'could not resolve %s "%s" (from scope argument "%s"): %s'
        % (label, r.get("input", "?"), raw_arg, r.get("reason", "unknown reason"))
    )

resolved_ids = [r["resolved_id"] for r in resolve_results]

if is_range:
    # resolve-id.sh's own type-restriction rule guarantees every id resolved from a bare/tagged
    # story-level candidate is a STORY id — double-checked here defensively against the board
    # inventory rather than trusted blindly.
    story_ids = sorted(set(resolved_ids))
    epic_ids = set()
    not_stories = []
    for sid in story_ids:
        item = by_id.get(sid)
        if item is None or item.get("type") != "story":
            not_stories.append(sid)
            continue
        if item.get("epic_id"):
            epic_ids.add(item["epic_id"])
    if not_stories:
        emit_error(
            "range member(s) resolved but are not story-type items in the board inventory: %s"
            % ", ".join(not_stories)
        )
    task_ids = sorted(
        item["id"] for item in board
        if item.get("type") == "task" and item.get("story_id") in set(story_ids)
    )
    scope_type = "range"
    epic_ids = sorted(epic_ids)
else:
    if len(resolved_ids) != 1:
        emit_error("expected exactly one resolved id for a non-range argument, got %d" % len(resolved_ids))
    resolved_id = resolved_ids[0]
    item = by_id.get(resolved_id)
    if item is None:
        emit_error('resolved id "%s" not found in the board inventory' % resolved_id)

    item_type = item.get("type")
    if item_type == "epic":
        target_epic = resolved_id
    elif item_type in ("story", "task"):
        # Default-scope-to-epic rule: a story/task argument always resolves to its containing
        # epic, in full — rollup can't be evaluated correctly without all sibling stories/tasks.
        target_epic = item.get("epic_id")
        if not target_epic:
            emit_error('resolved id "%s" has no epic_id in the board inventory' % resolved_id)
    else:
        emit_error('resolved id "%s" has an unrecognized type "%s"' % (resolved_id, item_type))

    epic_item = by_id.get(target_epic)
    if epic_item is None or epic_item.get("type") != "epic":
        emit_error(
            'could not find containing epic "%s" for resolved id "%s" in the board inventory'
            % (target_epic, resolved_id)
        )

    story_ids = sorted(
        i["id"] for i in board if i.get("type") == "story" and i.get("epic_id") == target_epic
    )
    task_ids = sorted(
        i["id"] for i in board if i.get("type") == "task" and i.get("epic_id") == target_epic
    )
    epic_ids = [target_epic]
    scope_type = "epic"

# --- owned_path_hints: best-effort, derived ONLY from docs: frontmatter -------------------------
# Reads each resolved scope item's own board file (path already known from board-scan.sh's `file`
# field) and extracts a single-line `docs: ["a", "b"]`-style frontmatter list if present. This is
# the ONLY source consulted — Acceptance Criteria prose is deliberately NOT scanned for paths, to
# keep this a narrow, predictable best-effort lookup rather than a second heuristic path-finder.
# An empty result is valid and expected when none of the resolved items declare a `docs:` list.
target_ids = set(epic_ids) | set(story_ids) | set(task_ids)
files = [item["file"] for item in board if item.get("id") in target_ids and item.get("file")]

FRONTMATTER_RE = re.compile(r"^---\n(.*?)\n---\n", re.DOTALL)
DOCS_LINE_RE = re.compile(r"^docs:\s*\[(.*)\]\s*$")

hints = set()
for rel_file in files:
    full = os.path.join(project_dir, rel_file)
    try:
        with open(full, encoding="utf-8", errors="replace") as fh:
            text = fh.read()
    except OSError:
        continue
    fm_match = FRONTMATTER_RE.match(text)
    if not fm_match:
        continue
    for line in fm_match.group(1).splitlines():
        m = DOCS_LINE_RE.match(line.strip())
        if not m:
            continue
        inner = m.group(1).strip()
        if not inner:
            continue
        for raw_item in inner.split(","):
            val = raw_item.strip()
            if len(val) >= 2 and val[0] == val[-1] and val[0] in ("'", '"'):
                val = val[1:-1]
            val = val.strip()
            if val:
                hints.add(val)

print(json.dumps({
    "scope_type": scope_type,
    "epic_ids": epic_ids,
    "story_ids": story_ids,
    "task_ids": task_ids,
    "owned_path_hints": sorted(hints)
}))
sys.exit(0)
PY

set +e
python3 "$PY_SCRIPT" "$RAW_ARG" "$IS_RANGE" "$RESOLVE_OUT" "$JENGA_PROJECT_DIR" <<< "$BOARD_JSON"
RC=$?
set -e
exit "$RC"
