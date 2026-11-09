# shellcheck shell=bash
# scripts/lib/board-ids.sh - shared board-ID shapes, shell side (epic E86, task E86_S01_T01).
#
# Source this file; do not execute it. Python twin: scripts/lib/board_ids.py (tests/board-ids-parity.bats keeps
# the two in agreement). bash 3.2 compatible. Sourcing prints nothing, sets no shell options and runs no command.
#
# The shapes are ERE strings, usable unquoted on the right of [[ $x =~ $BOARD_ID_STORY_RE ]] and with grep -E.
# Any digit width parses (E1, E01, E100); the two-digit minimum is a generation rule, not a parsing rule.
# Case-sensitive uppercase E/S/T. Anchored with ^ and $; there is no newline tolerance.

BOARD_ID_EPIC_FRAGMENT='E[0-9]+'
BOARD_ID_STORY_FRAGMENT='E[0-9]+_S[0-9]+'
BOARD_ID_TASK_FRAGMENT='E[0-9]+_S[0-9]+_T[0-9]+'
BOARD_ID_ANY_FRAGMENT='E[0-9]+(_S[0-9]+(_T[0-9]+)?)?'

BOARD_ID_EPIC_RE="^${BOARD_ID_EPIC_FRAGMENT}\$"
BOARD_ID_STORY_RE="^${BOARD_ID_STORY_FRAGMENT}\$"
BOARD_ID_TASK_RE="^${BOARD_ID_TASK_FRAGMENT}\$"
# shellcheck disable=SC2034  # public API for sourcing callers; unused inside this file
BOARD_ID_ANY_RE="^${BOARD_ID_ANY_FRAGMENT}\$"

# board_id_sort: reads names (bare IDs or filenames, one per line) on stdin and writes them in numeric natural order,
# the same order as board_id_sort_key in board_ids.py (tests/fixtures/board-id-sort-cases.json is the shared case list).
# Epic, story and task numbers compare as integers; a missing deeper segment sorts first; ties break by the full name's
# byte order; a name that is not a board ID sorts after every board ID, then by byte order. The ID must end at the end
# of the name, at "_" or at "." (E10x.md is not epic 10; E10_S1x.md is epic 10). awk emits integer columns and a plain
# sort -n orders them; no version-sort option and no GNU-only flags, so it runs on bash 3.2 and BSD awk/sort. Names containing a tab
# are not supported.
board_id_sort() {
  LC_ALL=C awk '
    function idend(r) { return (r == "" || substr(r, 1, 1) == "_" || substr(r, 1, 1) == ".") }
    {
      s = $0; kind = 1; e = 0; st = 0; t = 0
      if (match(s, /^E[0-9]+/)) {
        en = substr(s, 2, RLENGTH - 1); rest = substr(s, RLENGTH + 1)
        if (idend(rest)) {
          kind = 0; e = en; st = -1; t = -1
          if (match(rest, /^_S[0-9]+/)) {
            sn = substr(rest, 3, RLENGTH - 2); rest2 = substr(rest, RLENGTH + 1)
            if (idend(rest2)) {
              st = sn
              if (match(rest2, /^_T[0-9]+/)) {
                tn = substr(rest2, 3, RLENGTH - 2); rest3 = substr(rest2, RLENGTH + 1)
                if (idend(rest3)) t = tn
              }
            }
          }
        }
      }
      printf "%s\t%s\t%s\t%s\t%s\n", kind, e, st, t, s
    }' | LC_ALL=C sort -t "$(printf '\t')" -k1,1n -k2,2n -k3,3n -k4,4n -k5 | LC_ALL=C cut -f5-
}

# board_id_kind <id>: prints epic|story|task and returns 0, or prints nothing and returns 1 when malformed.
board_id_kind() {
  local _id="${1-}"
  if [[ $_id =~ $BOARD_ID_EPIC_RE ]]; then printf 'epic\n'
  elif [[ $_id =~ $BOARD_ID_STORY_RE ]]; then printf 'story\n'
  elif [[ $_id =~ $BOARD_ID_TASK_RE ]]; then printf 'task\n'
  else return 1
  fi
}

# board_id_format_number <n>: prints the number as it is written in a newly generated board ID - a MINIMUM of two
# digits and NO maximum (07, 99, 100, 1001). This is the only place that width rule lives; generators call it
# instead of carrying their own printf. Leading zeros on <n> are read as base 10 (007 is 7, never octal). Returns 1
# and prints nothing when <n> is not a plain run of digits.
board_id_format_number() {
  local _n="${1-}"
  [[ $_n =~ ^[0-9]+$ ]] || return 1
  printf '%02d\n' "$((10#$_n))"
}
