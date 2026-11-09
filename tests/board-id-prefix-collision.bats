#!/usr/bin/env bats
#
# E86_S02_T07: pin the trailing-underscore prefix invariant (epic E86, Decisions item 4 and the "related
# invariants" paragraph of project/documentation/board-ids.md).
#
# With width-agnostic IDs `E10` is a string prefix of `E100` and `E1001`, so a lookup of a board file by ID is
# only safe when it globs `<id>_*.md` (the trailing underscore ends the ID). A bare `<id>*` is the bug class.
#
# Part (a) is behavioural: in a throwaway board a shell glob, `find -name` and a Python glob for `E10_*`,
# `E10_S1_*` and `E10_S1_T1_*` never return a wider ID's file, and a bare `E10*` does (the negative control, so
# the assertions above cannot pass vacuously).
#
# Part (b) is a guard: each known `<id>_*.md` lookup site keeps its trailing underscore. Sites are located by
# content (an anchor regex), never by line number, so line drift does not fail the test. The guard reads from a
# root directory, so the mutation cases run the very same guard over a temporary copy of the files with one
# underscore removed and assert that it fails; nothing outside $BATS_TEST_TMPDIR is ever modified.
#
# Sites that appear in the E86_S02_T06 audit as "<id>_*.md lookups returning one file" but are not in the
# original 10 of this task are listed under "also guarded".

setup() {
  REPO="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  BOARD="$BATS_TEST_TMPDIR/board"
  mkdir -p "$BOARD"
  local f
  for f in E10_a.md E100_b.md E1001_c.md E10_S1_x.md E10_S10_y.md E10_S1_T1_z.md E10_S1_T10_w.md; do
    : > "$BOARD/$f"
  done
  define_sites
}

# ---------------------------------------------------------------------------
# Part (a): behaviour of the lookup patterns on a mixed-width board
# ---------------------------------------------------------------------------

# glob_names <pattern>: names a shell glob returns for the pattern in $BOARD, space separated, sorted.
glob_names() {
  ( cd "$BOARD" && shopt -s nullglob && local out="" f
    for f in $1; do out="$out $f"; done
    printf '%s' "$out" | tr ' ' '\n' | LC_ALL=C sort | tr '\n' ' ' | sed 's/ *$//; s/^ *//' )
}

find_names() {
  ( cd "$BOARD" && find . -maxdepth 1 -name "$1" -type f | sed 's|^\./||' | LC_ALL=C sort | tr '\n' ' ' | sed 's/ *$//' )
}

py_names() {
  python3 - "$BOARD" "$1" <<'PY'
import glob, os, sys
print(" ".join(sorted(os.path.basename(p) for p in glob.glob(os.path.join(sys.argv[1], sys.argv[2])))))
PY
}

@test "a: shell glob E10_*.md returns the E10 family and never E100 or E1001" {
  # `E10_*.md` also reaches E10's own story and task files, because they begin with the epic ID and an underscore;
  # board lookups run it inside one board directory, where only the epic file lives. What it must never reach is
  # a wider epic: E100_b.md and E1001_c.md.
  run glob_names 'E10_*.md'
  [ "$output" = "E10_S10_y.md E10_S1_T10_w.md E10_S1_T1_z.md E10_S1_x.md E10_a.md" ]
}

@test "a: an epic lookup with the epic file shape never returns E100 or E1001" {
  # the shape the lookups use: <id>_<slug>.md where the slug has no story segment
  run glob_names 'E10_a*.md'
  [ "$output" = "E10_a.md" ]
}

@test "a: shell glob E10_S1_*.md does not return E10_S10_" {
  run glob_names 'E10_S1_*.md'
  [[ "$output" == *E10_S1_x.md* ]]
  [[ "$output" != *E10_S10_y.md* ]]
}

@test "a: shell glob E10_S1_T1_*.md does not return E10_S1_T10_" {
  run glob_names 'E10_S1_T1_*.md'
  [ "$output" = "E10_S1_T1_z.md" ]
}

@test "a: find -name returns no wider ID for E10_*, E10_S1_* and E10_S1_T1_*" {
  run find_names 'E10_*'
  [[ "$output" != *E100_b.md* ]]
  [[ "$output" != *E1001_c.md* ]]
  [[ "$output" == *E10_a.md* ]]
  run find_names 'E10_S1_*'
  [[ "$output" == *E10_S1_x.md* ]]
  [[ "$output" != *E10_S10_y.md* ]]
  run find_names 'E10_S1_T1_*'
  [ "$output" = "E10_S1_T1_z.md" ]
}

@test "a: python glob (the form bundle-resume.sh uses) returns no wider ID" {
  run py_names 'E10_*.md'
  [[ "$output" != *E100_b.md* ]]
  [[ "$output" != *E1001_c.md* ]]
  run py_names 'E10_S1_*.md'
  [[ "$output" != *E10_S10_y.md* ]]
  run py_names 'E10_S1_T1_*.md'
  [ "$output" = "E10_S1_T1_z.md" ]
}

@test "a: negative control, a bare prefix glob does collide" {
  run glob_names 'E10*.md'
  [[ "$output" == *E100_b.md* ]]
  [[ "$output" == *E1001_c.md* ]]
  run glob_names 'E10_S1*.md'
  [[ "$output" == *E10_S10_y.md* ]]
  run glob_names 'E10_S1_T1*.md'
  [[ "$output" == *E10_S1_T10_w.md* ]]
  run find_names 'E10*'
  [[ "$output" == *E100_b.md* ]]
}

# ---------------------------------------------------------------------------
# Part (b): the lookup sites keep their trailing underscore
# ---------------------------------------------------------------------------

# One entry per lookup. SITE_FILE is repo-relative; SITE_RE is a grep -E (and Perl) pattern for the lookup text,
# located by content. SITE_NOTE names the original task site (line numbers are from 2026-10-25 and are only a hint).
define_sites() {
  SITE_FILE=(); SITE_RE=(); SITE_NOTE=()
  add_site hooks/on_session_end.sh \
    '-iname "\$\{task_id\}_\*\.md"' "on_session_end.sh is_task_terminal (was :219)"
  add_site skills/j-check-in/scripts/collect-liveness.sh \
    'tasks/"\$id"_\*\.md' "collect-liveness.sh board_status_of, tasks glob (was :639)"
  add_site skills/j-check-in/scripts/collect-liveness.sh \
    'stories/"\$id"_\*\.md' "collect-liveness.sh board_status_of, stories glob (was :639)"
  add_site skills/j-check-in/scripts/collect-liveness.sh \
    'epics/"\$id"_\*\.md' "collect-liveness.sh board_status_of, epics glob (was :639)"
  add_site scripts/render-ranked-list.sh \
    '"\$dir"/"\$id"_\*\.md' "render-ranked-list.sh status_of (was :163)"
  add_site scripts/link-external-ref.sh \
    '"\$dir/\$\{ID\}"_\*\.md' "link-external-ref.sh board file lookup (was :281)"
  add_site skills/j-close-story/scripts/check-story-closeable.sh \
    '-name "\$\{STORY_ID\}_\*\.md"' "check-story-closeable.sh story lookup (was :64)"
  add_site skills/j-close-story/scripts/check-story-closeable.sh \
    '-name "\$\{task_id\}_\*\.md"' "check-story-closeable.sh task lookup (was :153)"
  add_site skills/j-do/scripts/bundle-resume.sh \
    'story_id \+ "_\*\.md"' "bundle-resume.sh story file glob (was :141)"
  add_site skills/j-do/scripts/bundle-resume.sh \
    'tid \+ "_\*\.md"' "bundle-resume.sh task file glob (was :148)"
  add_site skills/j-todo/scripts/add_trivial_task.sh \
    '"\$\{STORIES_DIR\}/\$\{story_id\}_"\*\.md' "add_trivial_task.sh parent story lookup (was :110)"
  add_site skills/j-todo/scripts/add_trivial_task.sh \
    '"\$\{TASKS_DIR\}/\$\{task_id\}_"\*\.md' "add_trivial_task.sh ID collision check (was :129, now the existing_matches glob)"
  # also guarded: the same lookup shape, listed as "<id>_*.md lookups returning one file" in the T06 audit
  add_site skills/j-todo/scripts/add_trivial_task.sh \
    '"\$\{TASKS_DIR\}/\$\{story_id\}_T"\*\.md' "also guarded: add_trivial_task.sh degraded-mode numeric maximum"
  add_site scripts/resolve-commit-ref.sh \
    '"\$TASK_DIR/\$\{ID\}"_\*\.md' "also guarded: resolve-commit-ref.sh task lookup"
  add_site skills/j-close-story/scripts/extract-diff-stats.sh \
    '/stories/\$\{STORY_ID\}_"\*\.md' "also guarded: extract-diff-stats.sh story lookup"
  add_site skills/j-test/scripts/scope-test-gate.sh \
    '"\$dir/\$\{id\}_"\*\.md' "also guarded: scope-test-gate.sh board_file"
  add_site skills/j-close-task/scripts/close-task-context.sh \
    '"\$1/\$2"_\*\.md' "also guarded: close-task-context.sh one-file lookup"
  add_site skills/j-verify/scripts/verify-context.sh \
    '"\$1/\$2"_\*\.md' "also guarded: verify-context.sh one-file lookup"
  # landed after the T06 audit (E76_S02/E76_S03), same lookup shape
  add_site scripts/task-usage.sh \
    '"\$TASKS_DIR/\$1"_\*\.md' "also guarded: task-usage.sh tu_board_file one-file lookup"
  add_site scripts/task-usage.sh \
    '"\$TASKS_DIR/\$id"_T\*_\*\.md' "also guarded: task-usage.sh story to task expansion"
}

add_site() {
  SITE_FILE+=("$1"); SITE_RE+=("$2"); SITE_NOTE+=("$3")
}

# Bare forms: an ID-ish variable immediately followed by a glob star (no underscore), in shell or Python.
BARE_RE='\$\{?[A-Za-z0-9_]*[Ii][Dd]\}?"?\*|[Ii][Dd] \+ "\*'

# guard_root <root>: every site found with its trailing underscore, and no bare ID glob in any guarded file.
# Prints one line per failure; returns the number of failures.
guard_root() {
  local root="$1" i n=0 f
  for i in "${!SITE_FILE[@]}"; do
    f="$root/${SITE_FILE[$i]}"
    if [ ! -f "$f" ]; then
      echo "MISSING FILE: ${SITE_FILE[$i]} (${SITE_NOTE[$i]})"; n=$((n + 1)); continue
    fi
    if ! grep -qE -e "${SITE_RE[$i]}" "$f"; then
      echo "NOT FOUND: ${SITE_NOTE[$i]} in ${SITE_FILE[$i]}"; n=$((n + 1))
    fi
  done
  for f in $(printf '%s\n' "${SITE_FILE[@]}" | sort -u); do
    [ -f "$root/$f" ] || continue
    if grep -nE -e "$BARE_RE" "$root/$f" | grep -vE '^[0-9]+:[[:space:]]*#' > "$BATS_TEST_TMPDIR/bare.out"; then
      sed "s|^|BARE ID GLOB in $f:|" "$BATS_TEST_TMPDIR/bare.out"; n=$((n + 1))
    fi
  done
  return "$n"
}

@test "b: every listed lookup site is found by content with its trailing underscore" {
  run guard_root "$REPO"
  echo "$output"
  [ "$status" -eq 0 ]
}

@test "b: the 10 sites named by the task are all covered (12 lookups, 3 in collect-liveness.sh)" {
  # the first 12 entries are the task's 10 sites (collect-liveness.sh holds three lookups on one line)
  [ "${#SITE_FILE[@]}" -ge 12 ]
  local named="hooks/on_session_end.sh skills/j-check-in/scripts/collect-liveness.sh scripts/render-ranked-list.sh scripts/link-external-ref.sh skills/j-close-story/scripts/check-story-closeable.sh skills/j-do/scripts/bundle-resume.sh skills/j-todo/scripts/add_trivial_task.sh"
  local f
  for f in $named; do
    printf '%s\n' "${SITE_FILE[@]}" | grep -qxF "$f"
  done
}

@test "b: each site matches the live file at least once (anchors are not vacuous)" {
  local i c
  for i in "${!SITE_FILE[@]}"; do
    c="$(grep -cE -e "${SITE_RE[$i]}" "$REPO/${SITE_FILE[$i]}")"
    [ "$c" -ge 1 ] || { echo "no match: ${SITE_NOTE[$i]}"; false; }
  done
}

# mutate_site <root> <index>: in the temporary copy, drop the underscore from the lookup that anchor <index> matches.
mutate_site() {
  RE="${SITE_RE[$2]}" perl -pi -e 'BEGIN { $re = $ENV{RE} } s/($re)/my $m = $1; $m =~ s{_(T?"?)\*}{$1*}; $m/e' "$1/${SITE_FILE[$2]}"
}

@test "b: mutation, the guard fails when any one site drops its trailing underscore" {
  local i root
  for i in "${!SITE_FILE[@]}"; do
    root="$BATS_TEST_TMPDIR/mut-$i"
    mkdir -p "$root/$(dirname "${SITE_FILE[$i]}")"
    cp "$REPO/${SITE_FILE[$i]}" "$root/${SITE_FILE[$i]}"
    # the other files are copied unmodified so the only defect is the one under test
    local g
    for g in $(printf '%s\n' "${SITE_FILE[@]}" | sort -u); do
      [ -f "$root/$g" ] && continue
      mkdir -p "$root/$(dirname "$g")"; cp "$REPO/$g" "$root/$g"
    done
    # sanity: the unmutated copy passes
    run guard_root "$root"
    [ "$status" -eq 0 ] || { echo "unmutated copy already failing for ${SITE_NOTE[$i]}: $output"; false; }
    mutate_site "$root" "$i"
    run guard_root "$root"
    [ "$status" -ne 0 ] || { echo "guard did NOT fail for ${SITE_NOTE[$i]}"; false; }
    [[ "$output" == *"${SITE_NOTE[$i]}"* ]] || { echo "failure did not name ${SITE_NOTE[$i]}: $output"; false; }
  done
}

@test "b: mutation, a bare \${id}* glob (not just a missing underscore) is rejected" {
  local root="$BATS_TEST_TMPDIR/bare-root" f
  for f in $(printf '%s\n' "${SITE_FILE[@]}" | sort -u); do
    mkdir -p "$root/$(dirname "$f")"; cp "$REPO/$f" "$root/$f"
  done
  # append a bare lookup, as a careless edit elsewhere in a guarded file would
  printf '%s\n' 'for f in "$dir"/"${id}"*.md; do :; done' >> "$root/scripts/render-ranked-list.sh"
  run guard_root "$root"
  [ "$status" -ne 0 ]
  [[ "$output" == *"BARE ID GLOB in scripts/render-ranked-list.sh"* ]]
}
