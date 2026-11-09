"""Shared board-ID shapes (epic E86, task E86_S01_T01).

The single Python definition of the scrum-board ID shapes (E##, E##_S##, E##_S##_T##).
The shell twin is scripts/lib/board-ids.sh; tests/board-ids-parity.bats keeps the two in agreement.

Rules: parsers accept any digit width (E1, E01, E100, E0100 all parse); the two-digit minimum is a
generation rule owned by the allocator, not a parsing rule. IDs are case-sensitive (E, S, T uppercase).
Digits are ASCII only and the end anchor is \\Z, so a trailing newline or space is rejected.

Standard library only; importing this module prints nothing and has no side effects.
"""
import re

_F = re.ASCII

# Unanchored fragments, for embedding in larger patterns.
EPIC_FRAGMENT = r"E\d+"
STORY_FRAGMENT = r"E\d+_S\d+"
TASK_FRAGMENT = r"E\d+_S\d+_T\d+"
ANY_FRAGMENT = r"E\d+(?:_S\d+(?:_T\d+)?)?"
# Story-or-task fragment (what plan/summary files and todo references name).
STORY_OR_TASK_FRAGMENT = r"E\d+_S\d+(?:_T\d+)?"
# Optional leading prefix (for example a project code) as used by the board-graph extractor.
PREFIX_FRAGMENT = r"(?:[A-Z0-9]+_)?"

# Anchored, compiled.
EPIC_ID_RE = re.compile(rf"^{EPIC_FRAGMENT}\Z", _F)
STORY_ID_RE = re.compile(rf"^{STORY_FRAGMENT}\Z", _F)
TASK_ID_RE = re.compile(rf"^{TASK_FRAGMENT}\Z", _F)
BOARD_ID_RE = re.compile(rf"^{ANY_FRAGMENT}\Z", _F)

# Plan / summary file stems and a trailing todo reference (skills/index/scripts/board_index.py).
PLAN_RE = re.compile(rf"^({STORY_OR_TASK_FRAGMENT})-plan\Z", _F)
SUMMARY_RE = re.compile(rf"^({STORY_OR_TASK_FRAGMENT})-summary\Z", _F)
TODO_REF_AT_END_RE = re.compile(rf"({STORY_OR_TASK_FRAGMENT})\s*$", _F)

# Optional-prefix variants (scripts/e25_s01_extract_board_graph.py).
PREFIXED_EPIC_ID_RE = re.compile(rf"^{PREFIX_FRAGMENT}{EPIC_FRAGMENT}\Z", _F)
PREFIXED_STORY_ID_RE = re.compile(rf"^{PREFIX_FRAGMENT}{STORY_FRAGMENT}\Z", _F)
PREFIXED_TASK_ID_RE = re.compile(rf"^{PREFIX_FRAGMENT}{TASK_FRAGMENT}\Z", _F)
PREFIXED_TARGET_REF_RE = re.compile(
    rf"^({PREFIX_FRAGMENT}{STORY_OR_TASK_FRAGMENT})-(plan|summary)\.md\Z", _F)
PREFIXED_TODO_REF_RE = re.compile(rf"\b({PREFIX_FRAGMENT}{STORY_OR_TASK_FRAGMENT})\b", _F)


# Leading board ID of a name (bare ID or filename). The ID must end at the end of the name, at "_" or at "." so that
# E10x.md is not read as epic 10; a deeper segment that is not followed by one of those falls back to the shallower ID
# (E10_S1x.md is epic 10, E10_S1_Tx.md is story E10_S1).
_END = r"(?=[_.]|\Z)"
_SORT_ID_RE = re.compile(
    rf"^E(\d+)(?:_S(\d+)(?:_T(\d+){_END})?{_END})?{_END}", _F)


def board_id_sort_key(name):
    """Sort key giving numeric natural order for board IDs and names that start with one (epic E86, E86_S02_T01).

    Accepts a bare ID or a filename (E10_S2_T3_some-slug.md); the slug never decides order between different numbers.
    Epic, story and task numbers compare as integers; a missing deeper segment sorts before a present one (the epic
    file before its stories); ties are broken by the full name's text; a name that is not a board ID sorts after
    every board ID, then by text. Python's sort is stable. The shell twin is board_id_sort in board-ids.sh and
    tests/fixtures/board-id-sort-cases.json is the case list both must reproduce.
    """
    name = str(name)
    m = _SORT_ID_RE.match(name)
    if not m:
        return (1, 0, 0, 0, name)
    epic, story, task = (int(g) if g is not None else -1 for g in m.groups())
    return (0, epic, story, task, name)


def classify(board_id):
    """Return 'epic', 'story' or 'task' for a well-formed board ID, else None."""
    if not isinstance(board_id, str):
        return None
    if EPIC_ID_RE.match(board_id):
        return "epic"
    if STORY_ID_RE.match(board_id):
        return "story"
    if TASK_ID_RE.match(board_id):
        return "task"
    return None
