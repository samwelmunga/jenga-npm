#!/usr/bin/env bash
# scripts/next-board-id.sh - the one allocator for the next scrum-board ID (epic E86, task E86_S04_T01).
#
# Usage:
#   next-board-id.sh [--epics-dir D] [--stories-dir D] [--tasks-dir D] epic
#   next-board-id.sh [...] story <epic-id>      e.g. story E100
#   next-board-id.sh [...] task  <story-id>     e.g. task  E100_S02
#
# Prints the bare ID on one line: the numeric MAXIMUM plus one of the matching level, never a count and never a text
# sort. Gaps are ignored (T01 and T03 give T04), non-ID filenames are ignored, and the trailing underscore of the
# name pattern keeps E9, E10 and E100 apart. The scan is of the filesystem, so untracked files count. All three
# board directories are scanned for every request, because a task file proves its story number (and its epic number)
# is taken. Each directory is the override when given, otherwise the path `resolve-root.sh get epics|stories|tasks`
# returns, plus the legacy <root>/<tree>/epics|stories|tasks path when that exists beside it.
#
# Width: the new number has a minimum of two digits and no maximum (E07, E99, E100, E1001), formatted by
# board_id_format_number in scripts/lib/board-ids.sh, the only place that rule lives. A parent is echoed as given and
# matched by numeric value (E1 matches files named E01_...). Nothing is ever renamed.
#
# Exit: 0 ok; 2 usage (bad type, missing or malformed parent, a parent given to `epic`, unknown option, or an
# unresolvable board: an override that is not a directory, or no board directory to scan); 1 internal (shared library
# missing, or a number too large for 64-bit arithmetic). bash 3.2 compatible; creates and changes nothing.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="$SCRIPT_DIR/lib/board-ids.sh"
if [ ! -f "$LIB" ]; then
  echo "next-board-id.sh: shared board-ID library not found: $LIB" >&2
  exit 1
fi
# shellcheck source=lib/board-ids.sh
. "$LIB"

usage() {
  cat >&2 <<'USAGE'
Usage: next-board-id.sh [--epics-dir DIR] [--stories-dir DIR] [--tasks-dir DIR] <epic|story|task> [parent-id]
  epic                 print the next epic ID                 (E100)
  story <epic-id>      print the next story ID of an epic     (story E100    -> E100_S03)
  task  <story-id>     print the next task ID of a story      (task E100_S02 -> E100_S02_T04)
The number is the numeric maximum plus one, minimum two digits, no maximum.
USAGE
}

die_usage() {
  printf 'next-board-id.sh: %s\n' "$1" >&2
  usage
  exit 2
}

epics_dir="" stories_dir="" tasks_dir=""
positional=()
while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --epics-dir|--stories-dir|--tasks-dir)
      [ $# -ge 2 ] || die_usage "$1 needs a directory argument"
      case "$1" in
        --epics-dir) epics_dir="$2" ;;
        --stories-dir) stories_dir="$2" ;;
        --tasks-dir) tasks_dir="$2" ;;
      esac
      shift 2 ;;
    --epics-dir=*) epics_dir="${1#*=}"; shift ;;
    --stories-dir=*) stories_dir="${1#*=}"; shift ;;
    --tasks-dir=*) tasks_dir="${1#*=}"; shift ;;
    --) shift; while [ $# -gt 0 ]; do positional+=("$1"); shift; done ;;
    -*) die_usage "unknown option: $1" ;;
    *) positional+=("$1"); shift ;;
  esac
done

[ "${#positional[@]}" -le 2 ] || die_usage "too many arguments"
type="${positional[0]-}"
parent="${positional[1]-}"

case "$type" in
  epic)
    [ -z "$parent" ] || die_usage "'epic' takes no parent-id (got '$parent')" ;;
  story)
    [ -n "$parent" ] || die_usage "'story' needs an epic-id, for example: story E100"
    [[ $parent =~ $BOARD_ID_EPIC_RE ]] || die_usage "malformed epic-id '$parent' (expected E<digits>)" ;;
  task)
    [ -n "$parent" ] || die_usage "'task' needs a story-id, for example: task E100_S02"
    [[ $parent =~ $BOARD_ID_STORY_RE ]] || die_usage "malformed story-id '$parent' (expected E<digits>_S<digits>)" ;;
  "") die_usage "missing type" ;;
  *) die_usage "bad type '$type' (expected epic, story or task)" ;;
esac

# --- board directories -------------------------------------------------------------------------------------------
scan_dirs=()
root="" tree=""
resolved_root=0

resolve_dir() { # <key> <override> ; appends to scan_dirs
  local key="$1" override="$2" d legacy
  if [ -n "$override" ]; then
    [ -d "$override" ] || die_usage "$key directory is not a directory: $override"
    scan_dirs+=("$override")
    return 0
  fi
  if [ "$resolved_root" -eq 0 ]; then
    root="$(bash "$SCRIPT_DIR/resolve-root.sh" root 2>/dev/null)" || die_usage "cannot resolve the project root (scripts/resolve-root.sh failed)"
    tree="$(bash "$SCRIPT_DIR/resolve-root.sh" tree 2>/dev/null)" || tree="project"
    resolved_root=1
  fi
  d="$(bash "$SCRIPT_DIR/resolve-root.sh" get "$key" 2>/dev/null)" || die_usage "cannot resolve the $key directory (scripts/resolve-root.sh get $key failed)"
  if [ -d "$d" ]; then scan_dirs+=("$d"); fi
  legacy="${root%/}/$tree/$key"
  if [ -d "$legacy" ] && [ "$legacy" != "$d" ]; then
    scan_dirs+=("$legacy")
  fi
  return 0
}

resolve_dir epics "$epics_dir"
resolve_dir stories "$stories_dir"
resolve_dir tasks "$tasks_dir"

if [ "${#scan_dirs[@]}" -eq 0 ]; then
  die_usage "unresolvable board: none of the epics, stories or tasks directories exists"
fi

# --- numeric maximum ---------------------------------------------------------------------------------------------
# A run of digits that cannot be held in 64-bit arithmetic (after stripping leading zeros) is refused, never wrapped.
too_long() { # <digits>
  local s="$1"
  while [ "${#s}" -gt 1 ] && [ "${s#0}" != "$s" ]; do s="${s#0}"; done
  [ "${#s}" -gt 17 ]
}

# Parent numbers, as base-10 values.
want_epic="" want_story=""
if [ "$type" != "epic" ]; then
  _p="${parent#E}"
  want_epic="${_p%%_*}"
  if [ "$type" = "task" ]; then want_story="${_p#*_S}"; fi
fi
for _v in "$want_epic" "$want_story"; do
  if [ -n "$_v" ] && too_long "$_v"; then
    echo "next-board-id.sh: number too large for the allocator: $_v" >&2
    exit 1
  fi
done
if [ -n "$want_epic" ]; then want_epic=$((10#$want_epic)); fi
if [ -n "$want_story" ]; then want_story=$((10#$want_story)); fi

name_re="^(${BOARD_ID_ANY_FRAGMENT})_"
max=0
for dir in "${scan_dirs[@]}"; do
  for f in "$dir"/*; do
    [ -e "$f" ] || continue
    [ -d "$f" ] && continue
    name="${f##*/}"
    [[ $name =~ $name_re ]] || continue
    rest="${BASH_REMATCH[1]#E}"
    e="${rest%%_*}"
    s="" t=""
    case "$rest" in
      *_S*)
        s="${rest#*_S}"
        case "$s" in *_T*) t="${s#*_T}"; s="${s%%_T*}" ;; esac ;;
    esac
    for _v in "$e" "$s" "$t"; do
      if [ -n "$_v" ] && too_long "$_v"; then
        echo "next-board-id.sh: number too large for the allocator in $name" >&2
        exit 1
      fi
    done
    e=$((10#$e))
    case "$type" in
      epic) cand="$e" ;;
      story)
        [ "$e" -eq "$want_epic" ] || continue
        [ -n "$s" ] || continue
        cand=$((10#$s)) ;;
      task)
        [ "$e" -eq "$want_epic" ] || continue
        [ -n "$s" ] && [ -n "$t" ] || continue
        [ $((10#$s)) -eq "$want_story" ] || continue
        cand=$((10#$t)) ;;
    esac
    if [ "$cand" -gt "$max" ]; then max="$cand"; fi
  done
done

if [ "$max" -ge 99999999999999999 ]; then
  echo "next-board-id.sh: the highest existing number is too large to allocate past" >&2
  exit 1
fi
next="$(board_id_format_number $((max + 1)))" || exit 1

case "$type" in
  epic) printf 'E%s\n' "$next" ;;
  story) printf '%s_S%s\n' "$parent" "$next" ;;
  task) printf '%s_T%s\n' "$parent" "$next" ;;
esac
