#!/usr/bin/env bats
#
# E76_S02_T04: scripts/task-usage.sh --persist (E76_S02_T03) and the fail-loud exit codes of E76_S02_T01 as they
# apply to it. Covered: the first write and its exact fields, idempotence (byte-identical second run), persisted values
# surviving pruned transcripts, a further transcript raising the totals, the never-lower rule with its
# usage_possibly_incomplete marker and stderr warning (plain lower, mixed sums, transcript count only), partly pruned
# transcripts, the marker never being cleared, runs without --persist writing nothing, a failed measurement writing
# nothing, a held lock, and exit codes 4 to 8 under --persist (plus --check-layout agreeing).
#
# Every test builds a throwaway project root ($BATS_TEST_TMPDIR/root: project/configs/workflow.json and
# project/board/tasks/) and a throwaway copy of the synthetic transcripts in tests/fixtures/task-usage/projects. The
# script is pointed at them with JENGA_PROJECT_ROOT, --projects-dir and --project-dir, and runs with the temp root as
# its working directory, so the real project/board is never read or written (the test "resolved root" asserts it).
# No real ~/.claude/projects data is read. TASK_USAGE_TODAY pins the date written to usage_measured_on.
#
# TASK_USAGE_SCRIPT_UNDER_TEST: optional path of another copy of task-usage.sh to test (its ../skills/j-close-story
# and its sibling scripts must exist beside it). Used for mutation checks in an isolated copy; unset by default.
#
# Fixture numbers (input/output/cache_write/cache_read, see tests/fixtures/task-usage/README.md):
#   E99_S01_T01  30 / 900 / 1000 / 11000    total 12930   1 transcript
#   E99_S01_T02  17 / 1700 / 3500 / 31000   total 36217   3 transcripts (sess-0002 b0001 + b0003 tester, sess-0003 b0002)
#
# E76 ships publicly (decided 2026-11-07), so this file ships and must not depend on anything private.

bats_require_minimum_version 1.5.0

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
SCRIPT="${TASK_USAGE_SCRIPT_UNDER_TEST:-$REPO_ROOT/scripts/task-usage.sh}"
FIX="$REPO_ROOT/tests/fixtures/task-usage"
VALIDATE="$REPO_ROOT/scripts/validate-board.sh"

T01="E99_S01_T01"
T02="E99_S01_T02"
DAY1="2026-11-06"
DAY2="2026-11-07"

setup() {
  unset JENGA_PROJECTS_DIR JENGA_BOARD_STORIES_DIR TASK_USAGE_TODAY
  ROOT="$BATS_TEST_TMPDIR/root"
  PROJECTS="$BATS_TEST_TMPDIR/projects"
  SCRATCH="$BATS_TEST_TMPDIR/scratch"
  TASKS="$ROOT/project/board/tasks"
  mkdir -p "$ROOT/project/configs" "$TASKS" "$SCRATCH"
  cp "$REPO_ROOT/project/configs/workflow.json" "$ROOT/project/configs/workflow.json"
  cp -R "$FIX/projects" "$PROJECTS"
  TODAY="$DAY1"
}

# ---------------------------------------------------------------------------------------------------------------
# helpers
# ---------------------------------------------------------------------------------------------------------------

# tu <args...>: run the script in the temp root, private temp dir outside the snapshotted trees
tu() {
  (cd "$ROOT" && JENGA_PROJECT_ROOT="$ROOT" TASK_USAGE_TODAY="$TODAY" TMPDIR="$SCRATCH" bash "$SCRIPT" "$@")
}

# persist <extra args...>: --persist against the temp transcripts of project /fixture/proj
persist() { tu --persist --projects-dir "$PROJECTS" --project-dir /fixture/proj "$@"; }

# mk_task <id> [<frontmatter line>...]: a valid task board file in the temp board, mode 0640
mk_task() {
  local id="$1" f
  shift
  f="$TASKS/${id}_demo.md"
  {
    printf '%s\n' '---' "id: $id" "story_id: ${id%_T*}" "epic_id: ${id%%_*}" 'title: Demo task' 'status: Passed' \
      'date_created: 2026-10-15' 'date_started:' 'date_completed:' 'dates_previously_completed:' 'reopened_on:' \
      'reopened_reason:' 'assigned_to: developer' 'docs: []' 'depends_on: []' 'execution_scope: task' 'needs_docs: false'
    local l; for l in "$@"; do printf '%s\n' "$l"; done
    printf '%s\n' '---' '' '# Task: Demo task' '' '## Description' '' 'Body.'
  } > "$f"
  chmod 0640 "$f"
  bash "$VALIDATE" "$f" >/dev/null 2>&1 || { echo "fixture task file is not valid board frontmatter: $f"; return 1; }
}

tf() { printf '%s\n' "$TASKS/${1}_demo.md"; }

# usage_block <id>: every usage_* frontmatter line of the task file, in file order
usage_block() { grep '^usage_' "$(tf "$1")" || true; }

# block_for <input> <output> <cache_write> <cache_read> <transcripts> <date>: the exact seven lines --persist writes
block_for() {
  printf 'usage_input_tokens: %s\nusage_output_tokens: %s\nusage_cache_write_tokens: %s\nusage_cache_read_tokens: %s\nusage_total_tokens: %s\nusage_transcripts: %s\nusage_measured_on: %s' \
    "$1" "$2" "$3" "$4" "$(($1 + $2 + $3 + $4))" "$5" "$6"
}

# snap <id>: remember the task file; same <id>: it is byte-identical to the remembered copy
snap() { cp -p "$(tf "$1")" "$BATS_TEST_TMPDIR/snap-$1"; }
same() { cmp "$BATS_TEST_TMPDIR/snap-$1" "$(tf "$1")"; }

# tree_sum: every path (files, directories, lock dirs, leftovers) and every file's SHA-256 under the temp root and the temp projects
tree_sum() {
  local d
  for d in "$ROOT" "$PROJECTS"; do
    (cd "$d" && find . | LC_ALL=C sort && find . -type f | LC_ALL=C sort | while IFS= read -r f; do shasum -a 256 "$f"; done)
  done
}

mode_of() { stat -c %a "$1" 2>/dev/null || stat -f %Lp "$1"; }

# result_status <id>: the status of the id in the stdout summary
result_status() { printf '%s' "$output" | jq -r --arg id "$1" '.results[] | select(.id == $id) | .status'; }

# ln_usage <requestId> <input> <output> <cache_write> <cache_read>: one assistant line with a complete usage object
ln_usage() {
  jq -n -c --arg r "$1" --argjson i "$2" --argjson o "$3" --argjson cw "$4" --argjson cr "$5" \
    '{type:"assistant",requestId:$r,message:{role:"assistant",usage:{input_tokens:$i,output_tokens:$o,cache_creation_input_tokens:$cw,cache_read_input_tokens:$cr}}}'
}

# add_transcript <session> <agent-id> <task id> <usage line>: one more subagent transcript of the task, with its sidecar
add_transcript() {
  local d="$PROJECTS/-fixture-proj/$1/subagents"
  mkdir -p "$d"
  jq -n -c --arg n "$3" '{agentType:"developer",name:$n}' > "$d/agent-$2.meta.json"
  { jq -n -c '{type:"user",isSidechain:true,message:{role:"user",content:"hello"}}'; printf '%s\n' "$4"; } > "$d/agent-$2.jsonl"
}

# the tester transcript of E99_S01_T02, removed or restored
tester_dir() { printf '%s\n' "$PROJECTS/-fixture-proj/sess-0002/subagents"; }
prune_tester() { rm -f "$(tester_dir)/agent-b0003.jsonl" "$(tester_dir)/agent-b0003.meta.json"; }
restore_tester() {
  cp "$FIX/projects/-fixture-proj/sess-0002/subagents/agent-b0003.jsonl" "$FIX/projects/-fixture-proj/sess-0002/subagents/agent-b0003.meta.json" "$(tester_dir)/"
}

# ---------------------------------------------------------------------------------------------------------------
# the venue itself
# ---------------------------------------------------------------------------------------------------------------

@test "venue: the script resolves the temp root, and every board file it reports lives under it" {
  mk_task "$T01"
  # the resolver the script uses names the temp root, never the repository
  run bash -c 'cd "$1" && JENGA_PROJECT_ROOT="$1" bash "$2/scripts/resolve-root.sh" root' _ "$ROOT" "$REPO_ROOT"
  [ "$status" -eq 0 ]
  [ "$output" = "$ROOT" ]
  run bash -c 'cd "$1" && JENGA_PROJECT_ROOT="$1" bash "$2/scripts/resolve-root.sh" get tasks' _ "$ROOT" "$REPO_ROOT"
  [ "$output" = "$TASKS" ]
  [ "$TASKS" != "$REPO_ROOT/project/board/tasks" ]

  run --separate-stderr persist --task "$T01"
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r '.results | length')" = 1 ]
  [ "$(printf '%s' "$output" | jq -r '.results[0].file')" = "$(tf "$T01")" ]
  # nothing of this test leaked into the repository's board
  [ ! -e "$REPO_ROOT/project/board/tasks/$(basename "$(tf "$T01")")" ]
  ! compgen -G "$REPO_ROOT/project/board/tasks/E99_*" >/dev/null
}

# ---------------------------------------------------------------------------------------------------------------
# first write, idempotence
# ---------------------------------------------------------------------------------------------------------------

@test "persist: writes the seven exact fields into a task lacking them, the file passes validate-board.sh, and the rest of the file and its mode are untouched" {
  mk_task "$T01"
  snap "$T01"
  run --separate-stderr persist --task "$T01"
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -c '[.results[] | [.id, .status]]')" = '[["E99_S01_T01","persisted"]]' ]
  [ "$(usage_block "$T01")" = "$(block_for 30 900 1000 11000 1 "$DAY1")" ]
  # exactly the seven usage lines were added: removing them gives back the original bytes
  grep -v '^usage_' "$(tf "$T01")" | cmp - "$BATS_TEST_TMPDIR/snap-$T01"
  [ "$(mode_of "$(tf "$T01")")" = 640 ]
  run bash "$VALIDATE" "$(tf "$T01")"
  [ "$status" -eq 0 ]
  [[ "$output" == *"board frontmatter valid (task)"* ]]
  # the lock directory was released and no temporary copy was left behind
  [ ! -e "$(tf "$T01").lock.d" ]
  [ "$(ls "$TASKS")" = "${T01}_demo.md" ]
  [ -z "$(ls -A "$SCRATCH")" ]
}

@test "persist: a second run is a no-op, the file is byte-identical even when the date differs" {
  mk_task "$T01"
  run --separate-stderr persist --task "$T01"
  [ "$status" -eq 0 ]
  snap "$T01"
  TODAY="$DAY2"
  run --separate-stderr persist --task "$T01"
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -c '[.results[] | [.id, .status]]')" = '[["E99_S01_T01","unchanged"]]' ]
  same "$T01"
  [ "$(usage_block "$T01")" = "$(block_for 30 900 1000 11000 1 "$DAY1")" ]
}

# ---------------------------------------------------------------------------------------------------------------
# transcripts gone, transcripts added
# ---------------------------------------------------------------------------------------------------------------

@test "persist: deleting the task's transcripts leaves the persisted values byte-identical (requested ID: exit 8, bulk run: not-measured)" {
  mk_task "$T01"
  run --separate-stderr persist --task "$T01"
  [ "$status" -eq 0 ]
  snap "$T01"
  rm -f "$PROJECTS/-fixture-proj/sess-0001/subagents/agent-a0001.jsonl" "$PROJECTS/-fixture-proj/sess-0001/subagents/agent-a0001.meta.json"

  # the task is asked for by ID and has no transcripts any more: exit 8, nothing on stdout, nothing written
  run --separate-stderr persist --task "$T01"
  [ "$status" -eq 8 ]
  [ -z "$output" ]
  [[ "$stderr" == *"not measured (possibly pruned)"* ]]
  same "$T01"

  # a bulk run: the task carries persisted usage, so it is reported as not measured, never as zero, and nothing is written
  TODAY="$DAY2"
  run --separate-stderr persist
  [ "$status" -eq 0 ]
  [ "$(result_status "$T01")" = "not-measured" ]
  [[ "$stderr" == *"$T01: not measured, possibly pruned (no transcripts found, 1 persisted): the persisted values are untouched"* ]]
  same "$T01"
  [ "$(usage_block "$T01")" = "$(block_for 30 900 1000 11000 1 "$DAY1")" ]
}

@test "persist: a further transcript for the same task raises the stored totals and moves usage_measured_on" {
  mk_task "$T02"
  run --separate-stderr persist --task "$T02"
  [ "$status" -eq 0 ]
  [ "$(usage_block "$T02")" = "$(block_for 17 1700 3500 31000 3 "$DAY1")" ]

  add_transcript sess-0006 b0004 "$T02" "$(ln_usage r_new 2 20 300 4000)"
  TODAY="$DAY2"
  run --separate-stderr persist --task "$T02"
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -c '[.results[] | [.id, .status]]')" = '[["E99_S01_T02","updated"]]' ]
  # 17+2, 1700+20, 3500+300, 31000+4000, total 40539, four transcripts
  [ "$(usage_block "$T02")" = "$(block_for 19 1720 3800 35000 4 "$DAY2")" ]
  [ "$(usage_block "$T02" | grep -c possibly_incomplete)" = 0 ]
  run bash "$VALIDATE" "$(tf "$T02")"
  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------------------------------------------
# never lower: stored values kept, marker set, stderr warning
# ---------------------------------------------------------------------------------------------------------------

@test "persist: a recomputed total below the stored one keeps every stored value, sets usage_possibly_incomplete: true and warns on stderr" {
  mk_task "$T01" usage_input_tokens:\ 100 usage_output_tokens:\ 2000 usage_cache_write_tokens:\ 3000 \
    usage_cache_read_tokens:\ 40000 usage_total_tokens:\ 45100 usage_transcripts:\ 1 usage_measured_on:\ 2026-10-01
  snap "$T01"
  run --separate-stderr persist --task "$T01"
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -c '[.results[] | [.id, .status]]')" = '[["E99_S01_T01","kept-stored"]]' ]
  [ "$(usage_block "$T01")" = "$(block_for 100 2000 3000 40000 1 2026-10-01)"$'\n'"usage_possibly_incomplete: true" ]
  # the only change to the file is the marker line
  grep -v '^usage_possibly_incomplete: true$' "$(tf "$T01")" | cmp - "$BATS_TEST_TMPDIR/snap-$T01"
  [[ "$stderr" == *"$T01: recomputed 1 transcript(s) / 12930 tokens is below the persisted 1 / 45100 (possibly pruned): kept the persisted values and set usage_possibly_incomplete: true"* ]]
  run bash "$VALIDATE" "$(tf "$T01")"
  [ "$status" -eq 0 ]

  # a repeat changes nothing more: the marker is already there
  snap "$T01"
  run --separate-stderr persist --task "$T01"
  [ "$status" -eq 0 ]
  [ "$(result_status "$T01")" = "kept-stored" ]
  same "$T01"
}

@test "persist: a mixed result (one sum lower, one higher) is treated as lower: no stored value is lowered and the higher recompute is not folded in" {
  # stored input 40 > recomputed 30, stored output 100 < recomputed 900, the other two equal
  mk_task "$T01" usage_input_tokens:\ 40 usage_output_tokens:\ 100 usage_cache_write_tokens:\ 1000 \
    usage_cache_read_tokens:\ 11000 usage_total_tokens:\ 12140 usage_transcripts:\ 1 usage_measured_on:\ 2026-10-01
  run --separate-stderr persist --task "$T01"
  [ "$status" -eq 0 ]
  [ "$(result_status "$T01")" = "kept-stored" ]
  [ "$(usage_block "$T01")" = "$(block_for 40 100 1000 11000 1 2026-10-01)"$'\n'"usage_possibly_incomplete: true" ]
  [[ "$stderr" == *"kept the persisted values"* ]]
}

@test "persist: fewer transcripts than usage_transcripts is enough on its own to keep the stored values and set the marker" {
  # every stored sum is below the recompute, but 2 transcripts were stored and only 1 is found
  mk_task "$T01" usage_input_tokens:\ 10 usage_output_tokens:\ 100 usage_cache_write_tokens:\ 100 \
    usage_cache_read_tokens:\ 100 usage_total_tokens:\ 310 usage_transcripts:\ 2 usage_measured_on:\ 2026-10-01
  run --separate-stderr persist --task "$T01"
  [ "$status" -eq 0 ]
  [ "$(result_status "$T01")" = "kept-stored" ]
  [ "$(usage_block "$T01")" = "$(block_for 10 100 100 100 2 2026-10-01)"$'\n'"usage_possibly_incomplete: true" ]
  [[ "$stderr" == *"$T01: recomputed 1 transcript(s)"*"below the persisted 2 /"* ]]
}

@test "persist: a task whose transcripts look partly pruned keeps its totals and is marked usage_possibly_incomplete: true (and the marker survives a later upward refresh)" {
  mk_task "$T02"
  run --separate-stderr persist --task "$T02"
  [ "$status" -eq 0 ]
  [ "$(usage_block "$T02")" = "$(block_for 17 1700 3500 31000 3 "$DAY1")" ]

  # the tester's transcript is pruned: 2 of the 3 persisted transcripts are left
  prune_tester
  TODAY="$DAY2"
  run --separate-stderr persist --task "$T02"
  [ "$status" -eq 0 ]
  [ "$(result_status "$T02")" = "kept-stored" ]
  [ "$(usage_block "$T02")" = "$(block_for 17 1700 3500 31000 3 "$DAY1")"$'\n'"usage_possibly_incomplete: true" ]
  [[ "$stderr" == *"$T02: recomputed 2 transcript(s) / 31514 tokens is below the persisted 3 / 36217 (possibly pruned)"* ]]
  snap "$T02"

  # a repeat is a byte-identical no-op
  run --separate-stderr persist --task "$T02"
  [ "$status" -eq 0 ]
  same "$T02"

  # the transcript is back and another one was added: the numbers go up, and the marker is never cleared
  restore_tester
  add_transcript sess-0006 b0004 "$T02" "$(ln_usage r_new 2 20 300 4000)"
  run --separate-stderr persist --task "$T02"
  [ "$status" -eq 0 ]
  [ "$(result_status "$T02")" = "updated" ]
  [ "$(usage_block "$T02")" = "$(block_for 19 1720 3800 35000 4 "$DAY2")"$'\n'"usage_possibly_incomplete: true" ]
}

# ---------------------------------------------------------------------------------------------------------------
# no --persist, no write
# ---------------------------------------------------------------------------------------------------------------

@test "without --persist no mode creates, changes or removes anything under the project root or the transcripts" {
  mk_task "$T01"
  mk_task "$T02" usage_input_tokens:\ 1 usage_output_tokens:\ 2 usage_cache_write_tokens:\ 3 \
    usage_cache_read_tokens:\ 4 usage_total_tokens:\ 10 usage_transcripts:\ 1 usage_measured_on:\ 2026-10-01
  before="$(tree_sum)"
  local transcript="$PROJECTS/-fixture-proj/sess-0001/subagents/agent-a0001.jsonl"

  run --separate-stderr tu --report --projects-dir "$PROJECTS" --project-dir /fixture/proj
  [ "$status" -eq 0 ]
  run --separate-stderr tu --report --projects-dir "$PROJECTS" --project-dir /fixture/proj --task "$T02" --story E99_S01 --allocate
  [ "$status" -eq 0 ]
  run --separate-stderr tu --check-layout --projects-dir "$PROJECTS" --project-dir /fixture/proj
  [ "$status" -eq 0 ]
  run --separate-stderr tu --list-transcripts --projects-dir "$PROJECTS" --project-dir /fixture/proj
  [ "$status" -eq 0 ]
  run --separate-stderr tu --usage "$transcript"
  [ "$status" -eq 0 ]

  [ "$(tree_sum)" = "$before" ]
  [ "$(ls "$TASKS" | LC_ALL=C sort | tr '\n' ' ')" = "${T01}_demo.md ${T02}_demo.md " ]
  [ "$(grep -c '^usage_' "$(tf "$T01")")" = 0 ]
  [ -z "$(ls -A "$SCRATCH")" ]
}

# ---------------------------------------------------------------------------------------------------------------
# failed measurement, held lock
# ---------------------------------------------------------------------------------------------------------------

@test "persist: a transcript with its usage removed fails the measurement (exit 7), nothing on stdout, the persisted values untouched" {
  mk_task "$T01"
  run --separate-stderr persist --task "$T01"
  [ "$status" -eq 0 ]
  snap "$T01"
  # remove every usage object from the task's transcript: its assistant lines are still there
  local t="$PROJECTS/-fixture-proj/sess-0001/subagents/agent-a0001.jsonl"
  jq -c 'del(.message.usage)' "$t" > "$t.new" && mv "$t.new" "$t"
  before="$(tree_sum)"

  TODAY="$DAY2"
  run --separate-stderr persist --task "$T01"
  [ "$status" -eq 7 ]
  [ -z "$output" ]
  [[ "$stderr" == *"layout check 4 failed (exit 7)"* ]]
  [[ "$stderr" == *"agent-a0001.jsonl"*"none carries a message.usage object"* ]]
  [[ "$stderr" == *"nothing was persisted"* ]]
  same "$T01"
  [ "$(tree_sum)" = "$before" ]
  [ "$(usage_block "$T01")" = "$(block_for 30 900 1000 11000 1 "$DAY1")" ]
}

@test "persist: a failed measurement on a task with nothing persisted writes nothing at all, not even zeros" {
  mk_task "$T01"
  snap "$T01"
  local t="$PROJECTS/-fixture-proj/sess-0001/subagents/agent-a0001.jsonl"
  jq -c 'del(.message.usage)' "$t" > "$t.new" && mv "$t.new" "$t"
  before="$(tree_sum)"
  run --separate-stderr persist --task "$T01"
  [ "$status" -eq 7 ]
  [ -z "$output" ]
  same "$T01"
  [ "$(tree_sum)" = "$before" ]
  [ "$(grep -c '^usage_' "$(tf "$T01")")" = 0 ]
}

@test "persist: a held lock makes the write skip with exit 9, the file unchanged, and the lock is neither bypassed nor removed" {
  mk_task "$T01"
  snap "$T01"
  mkdir "$(tf "$T01").lock.d"
  before="$(tree_sum)"
  WITH_LOCK_TIMEOUT_SECONDS=2 run --separate-stderr persist --task "$T01"
  [ "$status" -eq 9 ]
  [ "$(printf '%s' "$output" | jq -c '[.results[] | [.id, .status]]')" = '[["E99_S01_T01","failed"]]' ]
  [[ "$stderr" == *"could not acquire the lock on $(tf "$T01"): write skipped (the lock is never bypassed)"* ]]
  [[ "$stderr" == *"within 2s"* ]]
  same "$T01"
  [ -d "$(tf "$T01").lock.d" ]
  [ "$(tree_sum)" = "$before" ]
  [ "$(grep -c '^usage_' "$(tf "$T01")")" = 0 ]

  # once the holder lets go the very same run succeeds
  rmdir "$(tf "$T01").lock.d"
  run --separate-stderr persist --task "$T01"
  [ "$status" -eq 0 ]
  [ "$(usage_block "$T01")" = "$(block_for 30 900 1000 11000 1 "$DAY1")" ]
}

# ---------------------------------------------------------------------------------------------------------------
# the fail-loud exit codes under --persist
# ---------------------------------------------------------------------------------------------------------------

# A task that already carries persisted values: every failure below must leave it, and the whole tree, untouched
seed_persisted() {
  mk_task "$T02" usage_input_tokens:\ 17 usage_output_tokens:\ 1700 usage_cache_write_tokens:\ 3500 \
    usage_cache_read_tokens:\ 31000 usage_total_tokens:\ 36217 usage_transcripts:\ 3 usage_measured_on:\ 2026-10-01
  snap "$T02"
}

# expect_loud <exit code>: the run ended with that code, wrote nothing on stdout, and left the tree untouched
expect_loud() {
  [ "$status" -eq "$1" ] || { echo "expected exit $1, got $status; stderr: $stderr"; return 1; }
  [ -z "$output" ] || { echo "expected empty stdout, got: $output"; return 1; }
  same "$T02"
  [ "$(tree_sum)" = "$before" ]
  [ -z "$(ls -A "$SCRATCH")" ]
}

@test "exit 4 under --persist: no transcript root, message names the root, nothing written" {
  seed_persisted
  PROJECTS="$BATS_TEST_TMPDIR/does-not-exist"
  run --separate-stderr persist --task "$T02"
  [ "$status" -eq 4 ]
  [ -z "$output" ]
  [[ "$stderr" == *"layout check 1 failed (exit 4): transcript root not found: $PROJECTS"* ]]
  [[ "$stderr" == *"nothing was persisted"* ]]
  same "$T02"
  [ -z "$(ls -A "$SCRATCH")" ]
}

@test "exit 5 under --persist: a project directory with no subagent transcripts, message names the searched path, nothing written" {
  seed_persisted
  PROJECTS="$BATS_TEST_TMPDIR/projects-no-subagents"
  mkdir -p "$PROJECTS/-fixture-proj"
  cp "$FIX/projects/-fixture-proj/sess-0001.jsonl" "$PROJECTS/-fixture-proj/"
  before="$(tree_sum)"
  run --separate-stderr persist --task "$T02"
  expect_loud 5
  [[ "$stderr" == *"layout check 2 failed (exit 5): no subagents/ directory found in any session directory under: $PROJECTS/-fixture-proj"* ]]
  [[ "$stderr" == *"nothing was persisted"* ]]
}

@test "exit 6 under --persist: a transcript with no sidecar meta, message names the missing .meta.json, nothing written" {
  seed_persisted
  PROJECTS="$BATS_TEST_TMPDIR/projects-no-meta"
  cp -R "$FIX/projects-no-meta" "$PROJECTS"
  before="$(tree_sum)"
  run --separate-stderr persist --task "$T02"
  expect_loud 6
  [[ "$stderr" == *"layout check 3 failed (exit 6): 1 of 1 subagent transcript(s) have a missing, unparseable or incomplete .meta.json"* ]]
  [[ "$stderr" == *"$PROJECTS/-fixture-proj/sess-0002/subagents/agent-n0001.meta.json: no sibling .meta.json"* ]]
  [[ "$stderr" == *"nothing was persisted"* ]]
}

@test "exit 7 under --persist: a task transcript with no usage object, message names the file, nothing written" {
  seed_persisted
  PROJECTS="$BATS_TEST_TMPDIR/projects-no-usage"
  cp -R "$FIX/projects-no-usage" "$PROJECTS"
  before="$(tree_sum)"
  run --separate-stderr persist --task "$T02"
  expect_loud 7
  [[ "$stderr" == *"layout check 4 failed (exit 7): 1 of 1 task-mapped transcript(s) have no usable usage data"* ]]
  [[ "$stderr" == *"$PROJECTS/-fixture-proj/sess-0002/subagents/agent-n0002.jsonl: 2 assistant line(s) but none carries a message.usage object"* ]]
  [[ "$stderr" == *"nothing was persisted"* ]]
}

@test "exit 8 under --persist: every requested ID absent, message names the IDs and the searched paths, nothing written" {
  seed_persisted
  before="$(tree_sum)"
  run --separate-stderr persist --task E99_S77_T77 --task E99_S78_T01
  expect_loud 8
  [[ "$stderr" == *"no transcripts found for the requested ID(s): E99_S77_T77, E99_S78_T01 (searched $PROJECTS/-fixture-proj and $PROJECTS/-fixture-proj--claude-worktrees-*)"* ]]
  [[ "$stderr" == *"nothing was persisted and any persisted values are untouched"* ]]

  # with at least one present ID it is a bulk run instead: the absent one is a warning, the present one is persisted
  mk_task "$T01"
  run --separate-stderr persist --task "$T01" --task E99_S77_T77
  [ "$status" -eq 0 ]
  [ "$(result_status "$T01")" = "persisted" ]
  [[ "$stderr" == *"warning: no transcripts map to task E99_S77_T77"* ]]
}

@test "--check-layout reports the same exit codes 4 to 7 as --persist, and writes no board file either" {
  mk_task "$T02"
  before="$(tree_sum)"
  local mode_dir
  for want in 4 5 6 7; do
    case "$want" in
      4) mode_dir="$BATS_TEST_TMPDIR/cl-missing" ;;
      5) mode_dir="$BATS_TEST_TMPDIR/cl-5"; mkdir -p "$mode_dir/-fixture-proj"; cp "$FIX/projects/-fixture-proj/sess-0001.jsonl" "$mode_dir/-fixture-proj/" ;;
      6) mode_dir="$BATS_TEST_TMPDIR/cl-6"; cp -R "$FIX/projects-no-meta" "$mode_dir" ;;
      7) mode_dir="$BATS_TEST_TMPDIR/cl-7"; cp -R "$FIX/projects-no-usage" "$mode_dir" ;;
    esac
    run --separate-stderr tu --check-layout --projects-dir "$mode_dir" --project-dir /fixture/proj
    [ "$status" -eq "$want" ] || { echo "check-layout: expected $want, got $status"; return 1; }
    [ "$(printf '%s' "$output" | jq -r '.exit_code')" = "$want" ]
    [ "$(printf '%s' "$output" | jq -r '.ok')" = false ]
    run --separate-stderr tu --persist --projects-dir "$mode_dir" --project-dir /fixture/proj --task "$T02"
    [ "$status" -eq "$want" ] || { echo "persist: expected $want, got $status"; return 1; }
    [ -z "$output" ]
  done
  [ "$(tree_sum)" = "$before" ]
  [ "$(grep -c '^usage_' "$(tf "$T02")")" = 0 ]
}
