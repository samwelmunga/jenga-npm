#!/usr/bin/env bats
#
# E86_S04_T02: add_trivial_task.sh and write-backfilled-epics.sh obtain the next board number from the one allocator
# (scripts/next-board-id.sh, formatted by scripts/lib/board-ids.sh) instead of carrying their own copy of the
# allocation and width rules. Every test runs the real, current scripts end to end in a throwaway fixture git repo
# under $BATS_TEST_TMPDIR with their runtime dependencies (the allocator and its library included) copied alongside,
# never against this repository's own board (same fixture-tree convention as tests/add-trivial-task-root-climb.bats).
# Output below 100 must stay byte-identical to what the scripts printed before (T07, E07); from 100 up the plain
# number is used (T100, E100). Assertions use `[ ]`, never a bare `[[ ]]`: see tests/helpers/assertions.bash.
load helpers/assertions

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
TRIVIAL_REL="skills/j-todo/scripts/add_trivial_task.sh"
BACKFILL_REL="skills/j-uncharted/scripts/write-backfilled-epics.sh"

setup() {
  FIXTURE_REPO="$BATS_TEST_TMPDIR/fixture-repo"
  mkdir -p "$FIXTURE_REPO"
  git -C "$FIXTURE_REPO" init -q
  git -C "$FIXTURE_REPO" config user.email "test@example.com"
  git -C "$FIXTURE_REPO" config user.name "Test"

  mkdir -p "$FIXTURE_REPO/project/board/epics" "$FIXTURE_REPO/project/board/stories" "$FIXTURE_REPO/project/board/tasks"
  mkdir -p "$FIXTURE_REPO/scripts/lib"
  mkdir -p "$FIXTURE_REPO/skills/j-todo/scripts" "$FIXTURE_REPO/skills/j-todo/assets"
  mkdir -p "$FIXTURE_REPO/skills/j-uncharted/scripts"

  # Real runtime dependencies, copied verbatim: the allocator and its shared library, plus what add_trivial_task.sh
  # shells out to.
  cp "$REPO_ROOT/scripts/next-board-id.sh" "$FIXTURE_REPO/scripts/next-board-id.sh"
  cp "$REPO_ROOT/scripts/lib/board-ids.sh" "$FIXTURE_REPO/scripts/lib/board-ids.sh"
  cp "$REPO_ROOT/scripts/with-lock.sh" "$FIXTURE_REPO/scripts/with-lock.sh"
  cp "$REPO_ROOT/scripts/todo_manager.sh" "$FIXTURE_REPO/scripts/todo_manager.sh"
  cp "$REPO_ROOT/skills/j-todo/scripts/update_story_tasks.py" "$FIXTURE_REPO/skills/j-todo/scripts/update_story_tasks.py"
  cp "$REPO_ROOT/skills/j-todo/assets/todo_template.md" "$FIXTURE_REPO/skills/j-todo/assets/todo_template.md"
  chmod +x "$FIXTURE_REPO/scripts/with-lock.sh" "$FIXTURE_REPO/scripts/todo_manager.sh"
  cp "$REPO_ROOT/$TRIVIAL_REL" "$FIXTURE_REPO/$TRIVIAL_REL"
  cp "$REPO_ROOT/$BACKFILL_REL" "$FIXTURE_REPO/$BACKFILL_REL"

  cat > "$FIXTURE_REPO/project/board/stories/E99_S01_sample-story.md" <<'EOF'
---
id: E99_S01
epic_id: E99
status: In Progress
tasks: []
---

# Sample story
EOF

  git -C "$FIXTURE_REPO" add -A
  git -C "$FIXTURE_REPO" commit -q -m "fixture: sample story"
}

# mk_tasks <from> <to>: task files for E99_S01, numbered like the board does (minimum two digits, no maximum).
mk_tasks() {
  local i n
  for i in $(seq "$1" "$2"); do
    n="$i"
    [ "$i" -ge 10 ] || n="0$i"
    : > "$FIXTURE_REPO/project/board/tasks/E99_S01_T${n}_existing.md"
  done
}

# mk_epics <dir> <from> <to>: epic files in <dir>, numbered like the board does.
mk_epics() {
  local dir="$1" i n
  mkdir -p "$dir"
  for i in $(seq "$2" "$3"); do
    n="$i"
    [ "$i" -ge 10 ] || n="0$i"
    : > "$dir/E${n}_existing.md"
  done
}

# add_task: add_trivial_task.sh run from its fixture location.
add_task() {
  run bash "$FIXTURE_REPO/$TRIVIAL_REL" \
    --story E99_S01 --title "Adopter task" \
    --description "A description." \
    --criteria "First criterion" \
    --computed-tier task --est-files 1 --est-lines 5
}

# cap_report <count>: an apply-subsystem-cap.sh style report with <count> kept subsystems, written to $CAP.
cap_report() {
  local count="$1" i sep=""
  CAP="$BATS_TEST_TMPDIR/cap.json"
  printf '{"script":"apply-subsystem-cap.sh","root":"app","kept":[' > "$CAP"
  for i in $(seq 1 "$count"); do
    printf '%s{"rank":%s,"path":"src/mod%s","score":50,"files":3,"lines":120}' "$sep" "$i" "$i" >> "$CAP"
    sep=","
  done
  printf ']}\n' >> "$CAP"
}

# backfill <epics-dir> [extra-args...]: write-backfilled-epics.sh run from its fixture location against $CAP.
backfill() {
  local dir="$1"
  shift
  run bash "$FIXTURE_REPO/$BACKFILL_REL" --epics-dir "$dir" "$@" "$CAP"
}

# --- add_trivial_task.sh ----------------------------------------------------------------------------------------

@test "add_trivial_task: T01..T06 gives T07 (two-digit output unchanged)" {
  mk_tasks 1 6
  add_task
  [ "$status" -eq 0 ]
  assert_output_contains "E99_S01_T07"
  [ -f "$FIXTURE_REPO/project/board/tasks/E99_S01_T07_adopter-task.md" ]
  grep -q "^id: E99_S01_T07$" "$FIXTURE_REPO/project/board/tasks/E99_S01_T07_adopter-task.md"
}

@test "add_trivial_task: T01..T99 gives T100 (plain number from 100 up)" {
  mk_tasks 1 99
  add_task
  [ "$status" -eq 0 ]
  assert_output_contains "E99_S01_T100"
  [ -f "$FIXTURE_REPO/project/board/tasks/E99_S01_T100_adopter-task.md" ]
  [ ! -f "$FIXTURE_REPO/project/board/tasks/E99_S01_T0100_adopter-task.md" ]
}

@test "add_trivial_task: the printed last line is exactly the new task ID" {
  mk_tasks 1 6
  add_task
  [ "$status" -eq 0 ]
  [ "${lines[$((${#lines[@]} - 1))]}" = "E99_S01_T07" ]
}

@test "add_trivial_task: a story with no tasks gets T01, and gaps are ignored (T01 and T03 give T04)" {
  add_task
  [ "$status" -eq 0 ]
  [ "${lines[$((${#lines[@]} - 1))]}" = "E99_S01_T01" ]
  rm -f "$FIXTURE_REPO"/project/board/tasks/E99_S01_T01_*.md
  : > "$FIXTURE_REPO/project/board/tasks/E99_S01_T01_a.md"
  : > "$FIXTURE_REPO/project/board/tasks/E99_S01_T03_b.md"
  add_task
  [ "$status" -eq 0 ]
  [ "${lines[$((${#lines[@]} - 1))]}" = "E99_S01_T04" ]
}

@test "add_trivial_task: works with and without a project/board/epics directory" {
  rmdir "$FIXTURE_REPO/project/board/epics"
  mk_tasks 1 6
  add_task
  [ "$status" -eq 0 ]
  [ "${lines[$((${#lines[@]} - 1))]}" = "E99_S01_T07" ]
}

@test "add_trivial_task: another story's tasks do not move the number" {
  : > "$FIXTURE_REPO/project/board/tasks/E99_S02_T40_other.md"
  mk_tasks 1 2
  add_task
  [ "$status" -eq 0 ]
  [ "${lines[$((${#lines[@]} - 1))]}" = "E99_S01_T03" ]
}

@test "add_trivial_task: an allocator failure aborts with exit 1 and writes no task file" {
  # An unparseable story (not E<digits>_S<digits>) cannot reach the allocator, so make the allocator itself fail by
  # replacing it with a failing stand-in.
  printf '#!/usr/bin/env bash\necho boom >&2\nexit 2\n' > "$FIXTURE_REPO/scripts/next-board-id.sh"
  add_task
  [ "$status" -eq 1 ]
  assert_output_contains "allocator"
  [ -z "$(ls "$FIXTURE_REPO/project/board/tasks")" ]
}

# --- write-backfilled-epics.sh ----------------------------------------------------------------------------------

@test "write-backfilled-epics: E01..E06 in a scratch --epics-dir gives E07 (two-digit output unchanged)" {
  SCRATCH="$FIXTURE_REPO/project/scratch-epics"
  mk_epics "$SCRATCH" 1 6
  cap_report 1
  backfill "$SCRATCH"
  [ "$status" -eq 0 ]
  assert_output_contains '"id": "E07"'
  [ -f "$SCRATCH/E07_src-mod1.md" ]
  grep -q "^id: E07$" "$SCRATCH/E07_src-mod1.md"
}

@test "write-backfilled-epics: E01..E99 in a scratch --epics-dir gives E100 (plain number from 100 up)" {
  SCRATCH="$FIXTURE_REPO/project/scratch-epics"
  mk_epics "$SCRATCH" 1 99
  cap_report 1
  backfill "$SCRATCH"
  [ "$status" -eq 0 ]
  assert_output_contains '"id": "E100"'
  [ -f "$SCRATCH/E100_src-mod1.md" ]
  grep -q "^id: E100$" "$SCRATCH/E100_src-mod1.md"
}

@test "write-backfilled-epics: several epics in one run take consecutive numbers across the 99 to 100 boundary" {
  SCRATCH="$FIXTURE_REPO/project/scratch-epics"
  mk_epics "$SCRATCH" 1 98
  cap_report 3
  backfill "$SCRATCH"
  [ "$status" -eq 0 ]
  [ -f "$SCRATCH/E99_src-mod1.md" ]
  [ -f "$SCRATCH/E100_src-mod2.md" ]
  [ -f "$SCRATCH/E101_src-mod3.md" ]
}

@test "write-backfilled-epics: --dry-run allocates the same IDs and writes no epic file" {
  SCRATCH="$FIXTURE_REPO/project/scratch-epics"
  mk_epics "$SCRATCH" 1 99
  cap_report 2
  backfill "$SCRATCH" --dry-run
  [ "$status" -eq 0 ]
  assert_output_contains '"id": "E100"'
  assert_output_contains '"id": "E101"'
  [ ! -f "$SCRATCH/E100_src-mod1.md" ]
  [ ! -f "$SCRATCH/E101_src-mod2.md" ]
}

@test "write-backfilled-epics: a scratch --epics-dir still continues past the canonical board's highest epic" {
  mk_epics "$FIXTURE_REPO/project/board/epics" 1 6
  SCRATCH="$FIXTURE_REPO/project/scratch-epics"
  mkdir -p "$SCRATCH"
  cap_report 1
  backfill "$SCRATCH"
  [ "$status" -eq 0 ]
  assert_output_contains '"id": "E07"'
}

@test "write-backfilled-epics: story and task files on the real board do not count toward a scratch directory" {
  # The scratch directory is isolated: only its own epic files (and the canonical epics directory's) set the number.
  : > "$FIXTURE_REPO/project/board/stories/E50_S01_x.md"
  SCRATCH="$FIXTURE_REPO/project/scratch-epics"
  mk_epics "$SCRATCH" 1 6
  cap_report 1
  backfill "$SCRATCH"
  [ "$status" -eq 0 ]
  assert_output_contains '"id": "E07"'
}

@test "write-backfilled-epics: refuses with exit 4 and writes nothing when the allocator is not deployed" {
  rm -f "$FIXTURE_REPO/scripts/next-board-id.sh"
  SCRATCH="$FIXTURE_REPO/project/scratch-epics"
  mkdir -p "$SCRATCH"
  cap_report 1
  backfill "$SCRATCH"
  [ "$status" -eq 4 ]
  assert_output_contains "allocator"
  [ -z "$(ls "$SCRATCH")" ]
}

# --- one source of truth ----------------------------------------------------------------------------------------

@test "neither adopter script carries its own two-digit formatting" {
  run grep -n '%02d' "$REPO_ROOT/$TRIVIAL_REL" "$REPO_ROOT/$BACKFILL_REL"
  [ "$status" -eq 1 ]
  [ -z "$output" ]
}
