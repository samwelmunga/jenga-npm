#!/usr/bin/env bash
#
# Shared helpers for tests/commits-for-item-differential.bats (epic E79, story E79_S02, task E79_S02_T02).
#
# What this is for
# ----------------
# The differential test proves scripts/commits-for-item.sh (the resolver) is a drop-in replacement for the legacy
# `git log --grep` calls, id by id. The per-id comparison itself lives in E79_S02_T02-differential-worker.sh; this
# file holds everything around it:
#
#   diff_board_ids          which ids to compare (every epic, story and task file under a board directory)
#   diff_history_skip_reason  whether the history is usable at all, and if not, the explicit reason to skip with
#   diff_snapshot           a throwaway mirror clone, so the comparison reads a frozen history
#   diff_run_all            the worker over every id, in parallel
#   diff_summarise          the verdicts folded into counts and a printable report
#
# This file is sourced (bats `load`), never executed. It has no top-level side effects and does not touch shell
# options. Nothing here writes to the repository it is pointed at: the only git commands run against a source
# repository are read-only (`rev-parse`, and `clone --mirror`, which only reads the source).

# The worker sits next to this file. BASH_SOURCE is this file when sourced.
DIFF_WORKER="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/E79_S02_T02-differential-worker.sh"

# diff_board_ids <board-dir>
#   Prints the sorted, de-duplicated ids of the board items under <board-dir>, one per line. The directory decides
#   the level and the file name carries the id: epics/E03_<slug>.md is E03, stories/E74_S01_<slug>.md is E74_S01,
#   tasks/E75_S01_T02_<slug>.md is E75_S01_T02. Only regular files named E*.md directly inside epics/, stories/ and
#   tasks/ count: lock directories (E..._.md.lock.d) and subdirectories such as tasks/_superseded are not items.
#   Prints nothing (and still returns 0) when the directory or a level is missing; the caller decides what that means.
diff_board_ids() {
  local board="$1" level pattern
  for level in epics stories tasks; do
    case "$level" in
      epics) pattern='^(E[0-9]+)(_.*)?\.md$' ;;
      stories) pattern='^(E[0-9]+_S[0-9]+)(_.*)?\.md$' ;;
      tasks) pattern='^(E[0-9]+_S[0-9]+_T[0-9]+)(_.*)?\.md$' ;;
    esac
    [ -d "$board/$level" ] || continue
    find "$board/$level" -maxdepth 1 -type f -name 'E*.md' 2>/dev/null |
      sed -E 's|.*/||' |
      sed -nE "s/$pattern/\\1/p"
  done | LC_ALL=C sort -u
}

# diff_history_skip_reason <repo> <board-dir>
#   Decides whether the this-repository comparison can run at all.
#     returns 0 and prints a one-line reason on stdout  -> the caller must SKIP with that reason
#     returns 1 and prints nothing                      -> history and board are usable, proceed
#   The reasons, in the order they are checked:
#     not a git repository / shallow clone / no commits / no board at <dir> / board has no epic, story or task files
#   A skip is always explicit: the caller passes the reason to bats' `skip`, so it appears in the TAP output.
diff_history_skip_reason() {
  local repo="$1" board="$2"
  if ! git -C "$repo" rev-parse --git-dir >/dev/null 2>&1; then
    printf 'not a git repository: %s, so there is no history to compare' "$repo"
    return 0
  fi
  if [ "$(git -C "$repo" rev-parse --is-shallow-repository 2>/dev/null)" = "true" ]; then
    printf 'shallow clone: history is truncated, so a comparison over it would not cover the real history'
    return 0
  fi
  if ! git -C "$repo" rev-parse --verify -q HEAD >/dev/null 2>&1; then
    printf 'repository has no commits, so there is no history to compare'
    return 0
  fi
  if [ ! -d "$board" ]; then
    printf 'no board at %s (project/board/ is private and is absent from the public mirror), so there are no ids to compare' "$board"
    return 0
  fi
  if [ -z "$(diff_board_ids "$board" | head -1)" ]; then
    printf 'board at %s has no epic, story or task files, so there are no ids to compare' "$board"
    return 0
  fi
  return 1
}

# diff_snapshot <source-repo> <dest-dir>
#   A bare mirror clone of <source-repo> at <dest-dir>. Every ref of the source is copied, so `git log --all` sees the
#   same history in the snapshot as in the source at the instant of the clone, and a commit another agent makes
#   while the comparison runs cannot make the resolver and the legacy calls see different histories. The source is
#   only read: a local clone hard-links objects and writes nothing to the source. Returns non-zero when the clone
#   fails (stderr carries git's message).
diff_snapshot() {
  git clone --mirror --quiet "$1" "$2"
}

# diff_jobs
#   How many workers to run at once: $E79_S02_T02_JOBS when it is a positive integer, else the CPU count, at most 8.
diff_jobs() {
  local n="${E79_S02_T02_JOBS:-}"
  case "$n" in
    '' | *[!0-9]* | 0) n="$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 2)" ;;
  esac
  case "$n" in
    '' | *[!0-9]* | 0) n=2 ;;
  esac
  [ "$n" -le 8 ] || [ -n "${E79_S02_T02_JOBS:-}" ] || n=8
  printf '%s' "$n"
}

# diff_run_all <repo> <outdir> <resolver> <ids-file>
#   Runs the worker once per id in <ids-file> against <repo>, diff_jobs at a time. Each worker writes
#   <outdir>/<id>.res. Returns non-zero only if the runner itself failed (a worker always exits 0 by design).
diff_run_all() {
  local repo="$1" out="$2" resolver="$3" ids="$4"
  mkdir -p "$out" || return 1
  xargs -P "$(diff_jobs)" -I{} bash "$DIFF_WORKER" "$repo" "$out" "$resolver" {} <"$ids"
}

# diff_summarise <outdir> <ids-file>
#   Folds the verdict files into counters and a report. Must be called directly, not under `run`, so the variables
#   survive in the caller's shell. Sets:
#     DIFF_TOTAL     ids in <ids-file>
#     DIFF_OK        resolver identical to both legacy calls
#     DIFF_INTENDED  ids where the unanchored legacy call differs only by prefix over-match (intended differences)
#     DIFF_EXTRA     the sum of the extra commits over all intended differences
#     DIFF_FAIL      unexplained differences, including a verdict line that cannot be read
#     DIFF_MISSING   ids with no verdict file at all (a worker that never ran or crashed); counted in DIFF_FAIL too
#     DIFF_REPORT    one line per intended difference, per failure and per missing id
#   Invariant: DIFF_OK + DIFF_INTENDED + DIFF_FAIL == DIFF_TOTAL.
diff_summarise() {
  local out="$1" ids="$2" id line verdict n
  DIFF_TOTAL=0 DIFF_OK=0 DIFF_INTENDED=0 DIFF_EXTRA=0 DIFF_FAIL=0 DIFF_MISSING=0
  DIFF_REPORT=""
  while IFS= read -r id; do
    [ -n "$id" ] || continue
    DIFF_TOTAL=$((DIFF_TOTAL + 1))
    if [ ! -s "$out/$id.res" ]; then
      DIFF_MISSING=$((DIFF_MISSING + 1))
      DIFF_FAIL=$((DIFF_FAIL + 1))
      DIFF_REPORT="${DIFF_REPORT}MISSING $id: no verdict was written"$'\n'
      continue
    fi
    IFS= read -r line <"$out/$id.res"
    verdict="${line#"$id "}"
    case "$verdict" in
      OK)
        DIFF_OK=$((DIFF_OK + 1))
        ;;
      "INTENDED "*)
        n="${verdict#INTENDED }"
        case "$n" in
          '' | *[!0-9]*)
            DIFF_FAIL=$((DIFF_FAIL + 1))
            DIFF_REPORT="${DIFF_REPORT}FAIL $id: unreadable verdict '$verdict'"$'\n'
            ;;
          *)
            DIFF_INTENDED=$((DIFF_INTENDED + 1))
            DIFF_EXTRA=$((DIFF_EXTRA + n))
            DIFF_REPORT="${DIFF_REPORT}INTENDED $id: the unanchored legacy grep returns $n extra commit(s) that name it only as the prefix of a longer id"$'\n'
            ;;
        esac
        ;;
      "FAIL "*)
        DIFF_FAIL=$((DIFF_FAIL + 1))
        DIFF_REPORT="${DIFF_REPORT}FAIL $id: ${verdict#FAIL }"$'\n'
        ;;
      *)
        DIFF_FAIL=$((DIFF_FAIL + 1))
        DIFF_REPORT="${DIFF_REPORT}FAIL $id: unreadable verdict '$verdict'"$'\n'
        ;;
    esac
  done <"$ids"
  return 0
}
