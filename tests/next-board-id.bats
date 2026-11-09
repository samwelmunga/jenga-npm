#!/usr/bin/env bats
#
# E86_S04_T01: scripts/next-board-id.sh prints the next epic / story / task ID as the numeric maximum plus one, with
# a minimum of two digits and no maximum, and the width rule lives only in board_id_format_number
# (scripts/lib/board-ids.sh). Every test runs against a throwaway board under $BATS_TEST_TMPDIR (the three
# --*-dir overrides, or JENGA_PROJECT_ROOT for the resolve-root path), never against this repository's own board, and
# needs no network. Assertions use `[ ]` (a simple command), never a bare `[[ ]]`: see tests/helpers/assertions.bash.
load helpers/assertions

setup() {
  REPO="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  SCRIPT="$REPO/scripts/next-board-id.sh"
  LIB="$REPO/scripts/lib/board-ids.sh"
  B="$BATS_TEST_TMPDIR/board"
  mkdir -p "$B/epics" "$B/stories" "$B/tasks"
}

# mk <dir> <id>...: one board file named <id>_x.md per ID in <dir>.
mk() {
  local dir="$1" id
  shift
  for id in "$@"; do : > "$dir/${id}_x.md"; done
}

# mk_epics <from> <to>: epic files E<from> ... E<to> in the epics directory, formatted like the board does.
mk_epics() {
  local i
  for i in $(seq "$1" "$2"); do : > "$B/epics/E$(printf '%02d' "$i")_x.md"; done
}

# alloc <args...>: the allocator pointed at the scratch board.
alloc() {
  bash "$SCRIPT" --epics-dir "$B/epics" --stories-dir "$B/stories" --tasks-dir "$B/tasks" "$@"
}

# --- epics -----------------------------------------------------------------------------------------------------

@test "epic: E01..E99 gives E100" {
  mk_epics 1 99
  run alloc epic
  [ "$status" -eq 0 ]
  [ "$output" = "E100" ]
}

@test "epic: E01, E99, E100 and E1001 give E1002 (numeric maximum, not a count or a text sort)" {
  mk "$B/epics" E01 E99 E100 E1001
  run alloc epic
  [ "$status" -eq 0 ]
  [ "$output" = "E1002" ]
}

@test "epic: highest E85 gives E86" {
  mk_epics 1 85
  run alloc epic
  [ "$status" -eq 0 ]
  [ "$output" = "E86" ]
}

@test "epic: an empty board gives E01 and E07 keeps its two-digit minimum" {
  run alloc epic
  [ "$status" -eq 0 ]
  [ "$output" = "E01" ]
  mk_epics 1 6
  run alloc epic
  [ "$status" -eq 0 ]
  [ "$output" = "E07" ]
}

@test "epic: gaps are ignored, the maximum wins" {
  mk "$B/epics" E01 E03 E40
  run alloc epic
  [ "$output" = "E41" ]
}

@test "epic: E9, E10 and E100 coexist without collision, next is E101" {
  mk "$B/epics" E9 E10 E100
  run alloc epic
  [ "$status" -eq 0 ]
  [ "$output" = "E101" ]
}

@test "epic: a wide epic number does not hide behind a lexically larger short one" {
  mk "$B/epics" E9 E1001 E2
  run alloc epic
  [ "$output" = "E1002" ]
}

# --- stories and tasks -------------------------------------------------------------------------------------------

@test "story: S99 gives S100 under the same epic" {
  mk "$B/stories" E100_S01 E100_S99
  run alloc story E100
  [ "$status" -eq 0 ]
  [ "$output" = "E100_S100" ]
}

@test "task: T99 gives T100 under the same story" {
  mk "$B/tasks" E100_S02_T01 E100_S02_T99
  run alloc task E100_S02
  [ "$status" -eq 0 ]
  [ "$output" = "E100_S02_T100" ]
}

@test "task: a gap (T01, T03) yields T04, not T02" {
  mk "$B/tasks" E05_S01_T01 E05_S01_T03
  run alloc task E05_S01
  [ "$status" -eq 0 ]
  [ "$output" = "E05_S01_T04" ]
}

@test "story and task with nothing under the parent start at 01" {
  run alloc story E07
  [ "$output" = "E07_S01" ]
  run alloc task E07_S03
  [ "$output" = "E07_S03_T01" ]
}

@test "story: only the named epic counts (E10 is not E100, E1 is not E10)" {
  mk "$B/stories" E10_S05 E100_S40 E1_S02 E11_S77
  run alloc story E10
  [ "$output" = "E10_S06" ]
  run alloc story E100
  [ "$output" = "E100_S41" ]
  run alloc story E1
  [ "$output" = "E1_S03" ]
}

@test "task: only the named story counts, not a sibling story or another epic" {
  mk "$B/tasks" E01_S02_T05 E01_S03_T09 E02_S02_T09 E01_S20_T30
  run alloc task E01_S02
  [ "$output" = "E01_S02_T06" ]
}

@test "a parent is matched by numeric value across widths and echoed as given" {
  mk "$B/stories" E01_S05
  run alloc story E1
  [ "$status" -eq 0 ]
  [ "$output" = "E1_S06" ]
}

# --- the three directories, untracked files and non-ID names ---------------------------------------------------------

@test "all three directories count: a task file proves its story and its epic are taken" {
  mk "$B/tasks" E50_S07_T01
  run alloc epic
  [ "$output" = "E51" ]
  run alloc story E50
  [ "$output" = "E50_S08" ]
}

@test "all three directories count: a story file proves its epic number is taken" {
  mk "$B/stories" E60_S01
  run alloc epic
  [ "$output" = "E61" ]
}

@test "task allocation is not misled by story or epic files of the same parent" {
  mk "$B/epics" E03
  mk "$B/stories" E03_S02
  run alloc task E03_S02
  [ "$output" = "E03_S02_T01" ]
}

@test "an untracked file counts (the scan is of the filesystem, not git)" {
  git -C "$BATS_TEST_TMPDIR" init -q board-repo
  mkdir -p "$BATS_TEST_TMPDIR/board-repo/epics" "$BATS_TEST_TMPDIR/board-repo/stories" "$BATS_TEST_TMPDIR/board-repo/tasks"
  R="$BATS_TEST_TMPDIR/board-repo"
  : > "$R/epics/E01_x.md"
  git -C "$R" add epics/E01_x.md
  git -C "$R" -c user.email=t@example.com -c user.name=T commit -q -m "fixture"
  : > "$R/epics/E02_untracked.md"
  run git -C "$R" status --porcelain
  assert_output_contains "?? epics/E02_untracked.md"
  run bash "$SCRIPT" --epics-dir "$R/epics" --stories-dir "$R/stories" --tasks-dir "$R/tasks" epic
  [ "$status" -eq 0 ]
  [ "$output" = "E03" ]
}

@test "non-ID names are ignored" {
  mk "$B/epics" E04
  : > "$B/epics/README.md"
  : > "$B/epics/.gitkeep"
  : > "$B/epics/E_x.md"
  : > "$B/epics/Exx_foo.md"
  : > "$B/epics/E99x_foo.md"
  : > "$B/epics/e99_lower.md"
  : > "$B/epics/S99_x.md"
  : > "$B/epics/T99_x.md"
  : > "$B/epics/notes-E99_x.md"
  mkdir "$B/epics/E500_directory"
  run alloc epic
  [ "$status" -eq 0 ]
  [ "$output" = "E05" ]
}

@test "a two-digit-only board allocates exactly what the counting rule would have" {
  mk_epics 1 12
  mk "$B/stories" E12_S01 E12_S02 E12_S03
  mk "$B/tasks" E12_S03_T01 E12_S03_T02 E12_S03_T03 E12_S03_T04 E12_S03_T05 E12_S03_T06
  run alloc epic
  [ "$output" = "E13" ]
  run alloc story E12
  [ "$output" = "E12_S04" ]
  run alloc task E12_S03
  [ "$output" = "E12_S03_T07" ]
}

# --- directory resolution ------------------------------------------------------------------------------------------

@test "--epics-dir / --stories-dir / --tasks-dir (and the = form) redirect the scan to a scratch directory" {
  mkdir -p "$BATS_TEST_TMPDIR/scratch-e" "$BATS_TEST_TMPDIR/scratch-s" "$BATS_TEST_TMPDIR/scratch-t"
  mk "$BATS_TEST_TMPDIR/scratch-e" E70
  mk "$BATS_TEST_TMPDIR/scratch-s" E70_S04
  mk "$BATS_TEST_TMPDIR/scratch-t" E70_S04_T08
  mk_epics 1 5
  run bash "$SCRIPT" --epics-dir "$BATS_TEST_TMPDIR/scratch-e" --stories-dir "$BATS_TEST_TMPDIR/scratch-s" --tasks-dir "$BATS_TEST_TMPDIR/scratch-t" epic
  [ "$output" = "E71" ]
  run bash "$SCRIPT" "--epics-dir=$BATS_TEST_TMPDIR/scratch-e" "--stories-dir=$BATS_TEST_TMPDIR/scratch-s" "--tasks-dir=$BATS_TEST_TMPDIR/scratch-t" story E70
  [ "$output" = "E70_S05" ]
  run bash "$SCRIPT" --tasks-dir "$BATS_TEST_TMPDIR/scratch-t" --epics-dir "$BATS_TEST_TMPDIR/scratch-e" --stories-dir "$BATS_TEST_TMPDIR/scratch-s" task E70_S04
  [ "$output" = "E70_S04_T09" ]
}

# mk_root <dir>: a project root whose registry uses the default board paths.
mk_root() {
  mkdir -p "$1/project/configs" "$1/project/board/epics" "$1/project/board/stories" "$1/project/board/tasks"
  cat > "$1/project/configs/workflow.json" <<'JSON'
{"paths": {"epics": "project/board/epics", "stories": "project/board/stories", "tasks": "project/board/tasks"}}
JSON
}

@test "with no overrides the directories come from resolve-root.sh (JENGA_PROJECT_ROOT)" {
  ROOT="$BATS_TEST_TMPDIR/proj"
  mk_root "$ROOT"
  mk "$ROOT/project/board/epics" E01 E08
  mk "$ROOT/project/board/tasks" E08_S03_T02
  JENGA_PROJECT_ROOT="$ROOT" run bash "$SCRIPT" epic
  [ "$status" -eq 0 ]
  [ "$output" = "E09" ]
  JENGA_PROJECT_ROOT="$ROOT" run bash "$SCRIPT" task E08_S03
  [ "$output" = "E08_S03_T03" ]
}

@test "the legacy project/epics|stories|tasks paths count beside the canonical ones" {
  ROOT="$BATS_TEST_TMPDIR/proj"
  mk_root "$ROOT"
  mkdir -p "$ROOT/project/epics" "$ROOT/project/stories" "$ROOT/project/tasks"
  mk "$ROOT/project/board/epics" E05
  mk "$ROOT/project/epics" E200
  mk "$ROOT/project/stories" E05_S11
  mk "$ROOT/project/tasks" E05_S11_T20
  JENGA_PROJECT_ROOT="$ROOT" run bash "$SCRIPT" epic
  [ "$output" = "E201" ]
  JENGA_PROJECT_ROOT="$ROOT" run bash "$SCRIPT" story E05
  [ "$output" = "E05_S12" ]
  JENGA_PROJECT_ROOT="$ROOT" run bash "$SCRIPT" task E05_S11
  [ "$output" = "E05_S11_T21" ]
}

# --- usage errors (exit 2) -----------------------------------------------------------------------------------------

@test "a bad or missing type exits 2 with a usage message" {
  run alloc feature
  [ "$status" -eq 2 ]
  assert_output_contains "Usage:"
  run alloc
  [ "$status" -eq 2 ]
  assert_output_contains "Usage:"
}

@test "story and task without a parent exit 2" {
  run alloc story
  [ "$status" -eq 2 ]
  assert_output_contains "Usage:"
  run alloc task
  [ "$status" -eq 2 ]
  assert_output_contains "Usage:"
}

@test "a malformed parent exits 2 (wrong level, lowercase, junk, trailing text)" {
  local p
  for p in e01 E1x E_S01 E01_S02 E01_T01 "E01 " E01_S02_T03; do
    run alloc story "$p"
    [ "$status" -eq 2 ]
  done
  for p in E01 s01 E01_S x_E01_S02 E01_S02_T03 E01_S02x "E01_S02 "; do
    run alloc task "$p"
    [ "$status" -eq 2 ]
  done
  assert_output_contains "Usage:"
}

@test "epic with a parent, an unknown option and extra arguments exit 2" {
  run alloc epic E01
  [ "$status" -eq 2 ]
  run alloc --bogus epic
  [ "$status" -eq 2 ]
  run alloc story E01 E02
  [ "$status" -eq 2 ]
  run alloc --epics-dir
  [ "$status" -eq 2 ]
}

@test "an unresolvable board exits 2: an override that is not a directory, or no board directory at all" {
  run bash "$SCRIPT" --epics-dir "$BATS_TEST_TMPDIR/nope" --stories-dir "$B/stories" --tasks-dir "$B/tasks" epic
  [ "$status" -eq 2 ]
  assert_output_contains "not a directory"
  ROOT="$BATS_TEST_TMPDIR/empty-proj"
  mkdir -p "$ROOT/project/configs"
  echo '{"paths": {}}' > "$ROOT/project/configs/workflow.json"
  JENGA_PROJECT_ROOT="$ROOT" run bash "$SCRIPT" epic
  [ "$status" -eq 2 ]
  assert_output_contains "unresolvable board"
}

@test "a number too large for 64-bit arithmetic is refused (exit 1), never wrapped" {
  mk "$B/epics" E99999999999999999999
  run alloc epic
  [ "$status" -eq 1 ]
  assert_output_contains "too large"
}

@test "the allocator creates and changes nothing on the board" {
  mk_epics 1 3
  before="$(ls -R "$B")"
  run alloc epic
  [ "$status" -eq 0 ]
  [ "$(ls -R "$B")" = "$before" ]
}

# --- the width formatter ---------------------------------------------------------------------------------------------

fmt() { bash -c '. "$1"; board_id_format_number "$2"' _ "$LIB" "$1"; }

@test "board_id_format_number: minimum two digits, no maximum, base 10" {
  run fmt 7
  [ "$output" = "07" ]
  run fmt 99
  [ "$output" = "99" ]
  run fmt 100
  [ "$output" = "100" ]
  run fmt 1001
  [ "$output" = "1001" ]
  run fmt 007
  [ "$output" = "07" ]
  run fmt 08
  [ "$output" = "08" ]
  run fmt 09
  [ "$output" = "09" ]
}

@test "board_id_format_number rejects anything that is not a run of digits" {
  run fmt abc
  [ "$status" -eq 1 ]
  run fmt ""
  [ "$status" -eq 1 ]
  run fmt -5
  [ "$status" -eq 1 ]
}

@test "the %02d width rule lives in the shared library, not in the allocator" {
  run grep -n '%02d' "$SCRIPT"
  [ "$status" -eq 1 ]
  run grep -n "%02d" "$LIB"
  [ "$status" -eq 0 ]
}

@test "sourcing the library prints nothing and the allocator needs it (missing library is an error, no fallback)" {
  run bash -c '. "$1"' _ "$LIB"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  COPY="$BATS_TEST_TMPDIR/lonely"
  mkdir -p "$COPY"
  cp "$SCRIPT" "$COPY/next-board-id.sh"
  run bash "$COPY/next-board-id.sh" epic
  [ "$status" -eq 1 ]
  assert_output_contains "shared board-ID library not found"
}
