#!/usr/bin/env bats
#
# E86_S04_T05: allocator-to-validator boundary tests for the E99 to E100 step. scripts/next-board-id.sh allocates the
# next ID on a throwaway board, a minimal valid board file named for that ID is written, and scripts/validate-board.sh
# is run on it, so the width-agnostic ID contract is proven end to end. Every test builds its own board under
# $BATS_TEST_TMPDIR (the three --*-dir overrides), never touches this repository's project/ tree, and needs no network.
# validate-board.sh has no filename-versus-id check (E86_S01_T02): what is asserted is that it accepts files NAMED
# <ID>_<slug>.md whose frontmatter ids match. Assertions use `[ ]`, never a bare `[[ ]]`: see tests/helpers/assertions.bash.
load helpers/assertions

setup() {
  REPO="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  ALLOC="$REPO/scripts/next-board-id.sh"
  VALIDATE="$REPO/scripts/validate-board.sh"
  B="$BATS_TEST_TMPDIR/board"
  mkdir -p "$B/epics" "$B/stories" "$B/tasks"
}

# alloc <args...>: the allocator pointed at the scratch board.
alloc() {
  bash "$ALLOC" --epics-dir "$B/epics" --stories-dir "$B/stories" --tasks-dir "$B/tasks" "$@"
}

# mk <dir> <id>...: one empty board file named <id>_x.md per ID in <dir> (names only, what the allocator scans).
mk() {
  local dir="$1" id
  shift
  for id in "$@"; do : > "$dir/${id}_x.md"; done
}

# mk_run <dir> <prefix> <from> <to>: files <prefix><NN>_x.md for NN from..to, two-digit minimum like the board.
mk_run() {
  local i
  for i in $(seq "$3" "$4"); do : > "$1/$2$(printf '%02d' "$i")_x.md"; done
}

# write_epic <id>: a minimal valid epic file <id>_new.md in the epics directory.
write_epic() {
  cat > "$B/epics/$1_new.md" <<EOF2
---
id: $1
title: Boundary epic
status: Pending
date_created: 2026-10-25
stories: []
docs: []
---

# Epic: Boundary epic
EOF2
}

# write_story <id> <epic_id>: a minimal valid story file <id>_new.md in the stories directory.
write_story() {
  cat > "$B/stories/$1_new.md" <<EOF2
---
id: $1
epic_id: $2
title: Boundary story
status: Pending
date_created: 2026-10-25
tasks: []
docs: []
---

# Story: Boundary story
EOF2
}

# write_task <id> <story_id> <epic_id>: a minimal valid task file <id>_new.md in the tasks directory.
write_task() {
  cat > "$B/tasks/$1_new.md" <<EOF2
---
id: $1
story_id: $2
epic_id: $3
title: Boundary task
status: Pending
date_created: 2026-10-25
assigned_to: developer
docs: []
execution_scope: task
scope_rationale: "touches 1 file"
jenga_assigned: true
---

# Task: Boundary task
EOF2
}

# validates <file>...: validate-board.sh must exit 0; its output is shown when it does not.
validates() {
  run "$VALIDATE" "$@"
  [ "$status" -eq 0 ] || { echo "validate-board.sh exited $status: $output"; return 1; }
}

@test "epic: E01..E99 allocates E100 and a file named E100_<slug>.md validates" {
  mk_run "$B/epics" E 1 99
  run alloc epic
  [ "$status" -eq 0 ]
  [ "$output" = "E100" ]
  write_epic "$output"
  [ -f "$B/epics/E100_new.md" ]
  validates "$B/epics/E100_new.md"
}

@test "story: S01..S99 under E100 allocates E100_S100 and its file validates" {
  mk "$B/epics" E100
  mk_run "$B/stories" E100_S 1 99
  run alloc story E100
  [ "$status" -eq 0 ]
  [ "$output" = "E100_S100" ]
  write_story "$output" E100
  validates "$B/stories/E100_S100_new.md"
}

@test "task: T01..T99 under E100_S100 allocates E100_S100_T100 and its file validates" {
  mk "$B/epics" E100
  mk "$B/stories" E100_S100
  mk_run "$B/tasks" E100_S100_T 1 99
  run alloc task E100_S100
  [ "$status" -eq 0 ]
  [ "$output" = "E100_S100_T100" ]
  write_task "$output" E100_S100 E100
  validates "$B/tasks/E100_S100_T100_new.md"
}

@test "the whole chain: allocate E100, then E100_S01, then E100_S01_T01, each validates" {
  mk_run "$B/epics" E 1 99
  run alloc epic
  [ "$output" = "E100" ]
  write_epic "$output"
  run alloc story E100
  [ "$output" = "E100_S01" ]
  write_story "$output" E100
  run alloc task E100_S01
  [ "$output" = "E100_S01_T01" ]
  write_task "$output" E100_S01 E100
  validates "$B/epics/E100_new.md" "$B/stories/E100_S01_new.md" "$B/tasks/E100_S01_T01_new.md"
}

@test "mixed board: E01, E99, E100 and E1001 allocate E1002 and its file validates" {
  mk "$B/epics" E01 E99 E100 E1001
  run alloc epic
  [ "$status" -eq 0 ]
  [ "$output" = "E1002" ]
  write_epic "$output"
  validates "$B/epics/E1002_new.md"
}

@test "mixed board: files named E1001_S100_T100_<slug>.md with matching wide ids validate" {
  mk "$B/epics" E01 E99 E100 E1001
  mk "$B/stories" E1001_S99
  run alloc story E1001
  [ "$output" = "E1001_S100" ]
  write_story "$output" E1001
  # task files prove their story number is taken, so they are created only after the story was allocated
  mk "$B/tasks" E1001_S100_T99
  run alloc task E1001_S100
  [ "$output" = "E1001_S100_T100" ]
  write_task "$output" E1001_S100 E1001
  validates "$B/stories/E1001_S100_new.md" "$B/tasks/E1001_S100_T100_new.md"
}

@test "two-digit-only board: E01..E85 allocates exactly E86 and a file named E86_<slug>.md validates" {
  mk_run "$B/epics" E 1 85
  run alloc epic
  [ "$status" -eq 0 ]
  [ "$output" = "E86" ]
  write_epic "$output"
  validates "$B/epics/E86_new.md"
}

@test "two-digit-only board: stories and tasks keep their two-digit minimum, not a wider form" {
  mk "$B/epics" E86
  mk_run "$B/stories" E86_S 1 6
  mk_run "$B/tasks" E86_S06_T 1 6
  run alloc story E86
  [ "$output" = "E86_S07" ]
  write_story "$output" E86
  run alloc task E86_S06
  [ "$output" = "E86_S06_T07" ]
  write_task "$output" E86_S06 E86
  validates "$B/stories/E86_S07_new.md" "$B/tasks/E86_S06_T07_new.md"
}
