#!/usr/bin/env bats
# bats file_tags=tier:integration
#
# E92_S04_T01: scripts/pipeline-stage.sh, the derivation of which pipeline stages (todo, do, test, rollup) have work.
# Every test builds its own throwaway root under $BATS_TEST_TMPDIR (a registry of `{}`, so the conventional
# project/{board,queue} layout resolves by default) and passes it with --root; the live board, queue and todo.md are
# never read. tests/helpers/progress-fixture.bash is deliberately not used or edited.

bats_require_minimum_version 1.5.0

SCRIPT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)/scripts/pipeline-stage.sh"
BOARD_PROGRESS="$(cd "$BATS_TEST_DIRNAME/.." && pwd)/scripts/board-progress.sh"

setup() {
  FIX="$BATS_TEST_TMPDIR/fixture"
  mkdir -p "$FIX/project/configs" "$FIX/project/board/epics" "$FIX/project/board/stories" \
    "$FIX/project/board/tasks" "$FIX/project/queue"
  printf '{}\n' > "$FIX/project/configs/workflow.json"
}

# task <id> <status>: one task file in the fixture board.
task() {
  local id="$1" status="$2" story epic
  story="${id%_T*}"; epic="${id%%_*}"
  printf -- '---\nid: %s\nstory_id: %s\nepic_id: %s\ntitle: "Fixture %s"\nstatus: %s\n---\n\n# Fixture %s\n' \
    "$id" "$story" "$epic" "$id" "$status" "$id" > "$FIX/project/board/tasks/${id}_fixture.md"
}

# todo_entries <n>: a todo.md with a header, a comment and n real entries.
todo_entries() {
  local i
  { printf '# Todo\n\n<!-- a comment is not an entry -->\n\n'
    i=1
    while [ "$i" -le "$1" ]; do printf -- '- [ ] mission %s: E01_S01\n' "$i"; i=$((i + 1)); done
  } > "$FIX/project/todo.md"
}

queue_line() { # <file> <json>
  printf '%s\n' "$2" >> "$FIX/project/queue/$1"
}

run_script() { OUT="$("$SCRIPT" --root "$FIX")"; }
field() { printf '%s' "$OUT" | jq -c "$1"; }

tree_checksum() {
  (cd "$FIX" && find . | LC_ALL=C sort && find . -type f | LC_ALL=C sort | while IFS= read -r f; do shasum "$f"; done) | shasum
}

@test "an empty board and empty queues are idle with every count 0" {
  run_script
  [ "$(field '.schema_version')" = "1" ]
  [ "$(field '[.stages[].id]')" = '["todo","do","test","rollup"]' ]
  [ "$(field '[.stages[].count]')" = "[0,0,0,0]" ]
  [ "$(field '[.stages[].active]')" = "[false,false,false,false]" ]
  [ "$(field '.active')" = "[]" ]
  [ "$(field '.idle')" = "true" ]
  [ "$(field '.skipped')" = "0" ]
}

@test "the output is exactly the documented shape, stage labels included" {
  run_script
  [ "$OUT" = '{"schema_version":1,"stages":[{"id":"todo","label":"To do","count":0,"active":false},{"id":"do","label":"Do","count":0,"active":false},{"id":"test","label":"Test","count":0,"active":false},{"id":"rollup","label":"Rollup","count":0,"active":false}],"active":[],"idle":true,"skipped":0}' ]
}

@test "only todo.md entries light todo; the header and comments are not entries" {
  todo_entries 3
  run_script
  [ "$(field '.stages[0].count')" = "3" ]
  [ "$(field '.active')" = '["todo"]' ]
  [ "$(field '.idle')" = "false" ]
}

@test "one task in the in-progress bucket lights do" {
  task E01_S01_T01 "In Progress"
  task E01_S01_T02 "Pending"
  run_script
  [ "$(field '.stages[1].count')" = "1" ]
  [ "$(field '.active')" = '["do"]' ]
}

@test "one test_assignment line lights test" {
  queue_line tester_triggers.jsonl '{"type":"test_assignment","task_id":"E01_S01_T01"}'
  run_script
  [ "$(field '.stages[2].count')" = "1" ]
  [ "$(field '.active')" = '["test"]' ]
}

@test "one story_rollup line lights rollup" {
  queue_line scrum_triggers.jsonl '{"type":"story_rollup","story_id":"E01_S01"}'
  run_script
  [ "$(field '.stages[3].count')" = "1" ]
  [ "$(field '.active')" = '["rollup"]' ]
}

@test "several stages at once are all listed, in stage order" {
  todo_entries 2
  task E01_S01_T01 "In Progress"
  task E01_S01_T02 "In Progress"
  queue_line tester_triggers.jsonl '{"type":"test_assignment"}'
  queue_line scrum_triggers.jsonl '{"type":"story_rollup"}'
  queue_line scrum_triggers.jsonl '{"type":"story_rollup"}'
  run_script
  [ "$(field '[.stages[].count]')" = "[2,2,1,2]" ]
  [ "$(field '.active')" = '["todo","do","test","rollup"]' ]
  [ "$(field '.idle')" = "false" ]
}

@test "two stages active keep stage order, not the order the work arrived" {
  queue_line scrum_triggers.jsonl '{"type":"story_rollup"}'
  todo_entries 1
  run_script
  [ "$(field '.active')" = '["todo","rollup"]' ]
}

@test "status_review and rapport_review lines in scrum_triggers do not light rollup" {
  queue_line scrum_triggers.jsonl '{"type":"status_review"}'
  queue_line scrum_triggers.jsonl '{"type":"rapport_review"}'
  queue_line scrum_triggers.jsonl '{"type":"status_review"}'
  run_script
  [ "$(field '.stages[3].count')" = "0" ]
  [ "$(field '.active')" = '[]' ]
  [ "$(field '.idle')" = "true" ]
}

@test "only story_rollup lines are counted when other trigger types are mixed in" {
  queue_line scrum_triggers.jsonl '{"type":"status_review"}'
  queue_line scrum_triggers.jsonl '{"type":"story_rollup"}'
  queue_line scrum_triggers.jsonl '{"type":"rapport_review"}'
  queue_line tester_triggers.jsonl '{"type":"something_else"}'
  run_script
  [ "$(field '[.stages[].count]')" = "[0,0,0,1]" ]
}

@test "a malformed queue line is skipped, counted in skipped, and does not fail the run" {
  queue_line scrum_triggers.jsonl '{"type":"story_rollup"}'
  queue_line scrum_triggers.jsonl '{this is not json'
  queue_line scrum_triggers.jsonl '{"type":"story_rollup"}'
  queue_line tester_triggers.jsonl 'garbage'
  queue_line tester_triggers.jsonl '{"type":"test_assignment"}'
  run_script
  [ "$(field '.stages[3].count')" = "2" ]
  [ "$(field '.stages[2].count')" = "1" ]
  [ "$(field '.skipped')" = "2" ]
}

@test "a line that is valid JSON but not an object is skipped too; blank lines are ignored" {
  queue_line scrum_triggers.jsonl '42'
  queue_line scrum_triggers.jsonl ''
  queue_line scrum_triggers.jsonl '   '
  queue_line scrum_triggers.jsonl '{"type":"story_rollup"}'
  run_script
  [ "$(field '.stages[3].count')" = "1" ]
  [ "$(field '.skipped')" = "1" ]
}

@test "a missing queue file is count 0, and a missing queue directory is too" {
  rmdir "$FIX/project/queue"
  run_script
  [ "$(field '[.stages[].count]')" = "[0,0,0,0]" ]
  [ "$(field '.skipped')" = "0" ]
}

@test "the do count equals levels.tasks.totals.in_progress of board-progress.sh --all for the same fixture" {
  task E01_S01_T01 "In Progress"
  task E01_S01_T02 "In Progress"
  task E01_S01_T03 "Passed"
  task E02_S01_T01 "In Progress"
  task E02_S01_T02 "Blocked"
  run_script
  want="$("$BOARD_PROGRESS" --all --root "$FIX" | jq -r '.levels.tasks.totals.in_progress')"
  [ "$want" = "3" ]
  [ "$(field '.stages[1].count')" = "$want" ]
}

@test "the script names no board status" {
  run grep -n -E 'In Progress|Pending|Passed|Failed|Rejected|Blocked|Backlog|Deployed|Publicized|Privatized|Merged|Done' "$SCRIPT"
  [ "$status" -eq 1 ]
}

@test "two runs on the same fixture are byte-identical" {
  todo_entries 2
  task E01_S01_T01 "In Progress"
  queue_line scrum_triggers.jsonl '{"type":"story_rollup"}'
  queue_line scrum_triggers.jsonl 'bad line'
  a="$("$SCRIPT" --root "$FIX")"
  b="$("$SCRIPT" --root "$FIX")"
  [ -n "$a" ]
  [ "$a" = "$b" ]
}

@test "the script writes nothing: the fixture tree checksum is unchanged" {
  todo_entries 2
  task E01_S01_T01 "In Progress"
  queue_line scrum_triggers.jsonl '{"type":"story_rollup"}'
  queue_line tester_triggers.jsonl 'bad line'
  before="$(tree_checksum)"
  run_script
  after="$(tree_checksum)"
  [ -n "$before" ]
  [ "$before" = "$after" ]
}

@test "the JENGA_PROJECT_ROOT environment variable selects the root when --root is absent" {
  todo_entries 4
  OUT="$(cd "$BATS_TEST_TMPDIR" && JENGA_PROJECT_ROOT="$FIX" "$SCRIPT")"
  [ "$(field '.stages[0].count')" = "4" ]
}

@test "a missing jq exits 2 with a message that names jq" {
  stub="$BATS_TEST_TMPDIR/stubbin"
  mkdir -p "$stub"
  ln -s "$(command -v dirname)" "$stub/dirname"
  run -2 --separate-stderr env PATH="$stub" "$(command -v bash)" "$SCRIPT" --root "$FIX"
  [ "$status" -eq 2 ]
  [ -z "$output" ]
  case "$stderr" in *jq*) : ;; *) echo "stderr does not name jq: $stderr"; return 1 ;; esac
}

@test "usage errors exit 2 and leave stdout empty" {
  run -2 --separate-stderr "$SCRIPT" --nope
  [ "$status" -eq 2 ]
  [ -z "$output" ]
  run -2 --separate-stderr "$SCRIPT" --root "$BATS_TEST_TMPDIR/does-not-exist"
  [ "$status" -eq 2 ]
  [ -z "$output" ]
  run -2 --separate-stderr "$SCRIPT" --root
  [ "$status" -eq 2 ]
  [ -z "$output" ]
}
