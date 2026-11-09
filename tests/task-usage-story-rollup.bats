#!/usr/bin/env bats
#
# E76_S03_T05: j.close-story rolls a story's task totals plus its allocated overhead up into the story record,
# through skills/j-close-story/scripts/write-story-usage.sh, which takes the numbers from
# scripts/task-usage.sh --report --stories <id> (the overhead allocation of E76_S03_T03) and writes the story fields
# of templates/SCRUM_BOARD_SCHEMA.md ("Usage fields on stories").
#
# Covered: the story file carries the task part, the overhead part and the total, equal to the task-usage.sh --stories
# output, and total = task part + overhead part; the closing report block; unallocated overhead of the story's session;
# the not-measured paths (nothing written, a reason given, exit 0); the silent skip when scripts/task-usage.sh exists
# in neither lookup location (public-mirror guard, epic decision 6); the installed-package fallback; the
# usage_possibly_incomplete propagation; a persisted task part is never lowered; the story still passes
# scripts/validate-board.sh and scripts/validate-story-format.sh; and that SKILL.md documents the step while leaving the
# existing status / date_completed / privatized behaviour in place.
#
# Everything is built under $BATS_TEST_TMPDIR (which is also TMPDIR for the run): a throwaway project root (its own git
# repository, so the transcript slug is the fixture's own path) with synthetic transcripts; no real ~/.claude/projects
# data and no real board is read. E76 ships publicly (decided 2026-11-07), so this file ships and must not depend on
# anything private.

bats_require_minimum_version 1.5.0

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
HELPER="$REPO_ROOT/skills/j-close-story/scripts/write-story-usage.sh"
SKILL_MD="$REPO_ROOT/skills/j-close-story/SKILL.md"
VALIDATE="$REPO_ROOT/scripts/validate-board.sh"
VALIDATE_STORY="$REPO_ROOT/scripts/validate-story-format.sh"

setup() {
  unset JENGA_PROJECT_ROOT JENGA_PROJECTS_DIR JENGA_BOARD_STORIES_DIR
  export TASK_USAGE_TODAY=2026-11-06
  export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
  mkdir -p "$BATS_TEST_TMPDIR/tmp"
  export TMPDIR="$BATS_TEST_TMPDIR/tmp"
}

# mk_root <dir> <scripts-mode>: a project root with a board (story E99_S01: T01, T02), a workflow.json and, per
# <scripts-mode>: "linked" (scripts/ and skills/ point at the repository), "package" (only
# node_modules/@jenga-ai/agent points at it) or "none" (neither: the public-mirror shape).
mk_root() {
  ROOT="$1"
  mkdir -p "$ROOT/project/configs" "$ROOT/project/board/tasks" "$ROOT/project/board/stories"
  cp "$REPO_ROOT/project/configs/workflow.json" "$ROOT/project/configs/workflow.json"
  git init -q "$ROOT"
  ROOT="$(cd "$ROOT" && pwd -P)"
  case "$2" in
    linked) ln -s "$REPO_ROOT/scripts" "$ROOT/scripts"; ln -s "$REPO_ROOT/skills" "$ROOT/skills" ;;
    package) mkdir -p "$ROOT/node_modules/@jenga-ai"; ln -s "$REPO_ROOT" "$ROOT/node_modules/@jenga-ai/agent" ;;
    none) ;;
  esac
  mk_task T01 "First task"
  mk_task T02 "Second task"
  mk_story
  PROJECTS="$BATS_TEST_TMPDIR/projects"
  SLUG="$(printf '%s' "$ROOT" | LC_ALL=C sed 's/[^A-Za-z0-9-]/-/g')"
  mkdir -p "$PROJECTS/$SLUG"
  export JENGA_PROJECTS_DIR="$PROJECTS"
}

# mk_task <T01|T02> <title> [<extra frontmatter lines>]: a minimal valid, already Passed task of story E99_S01
mk_task() {
  local n="$1" f="$ROOT/project/board/tasks/E99_S01_${1}_fixture.md"
  {
    printf '%s\n' '---' "id: E99_S01_$n" 'story_id: E99_S01' 'epic_id: E99' "title: $2" 'status: Passed' \
      'date_created: 2026-10-25' 'assigned_to: developer' 'execution_scope: task' 'scope_rationale: "touches 1 file"' \
      'jenga_assigned: true'
    [ -z "${3:-}" ] || printf '%s\n' "$3"
    printf '%s\n' '---' '' "# Task: $2" '' '## Description' '' 'Fixture.'
  } >"$f"
}

# mk_story [<extra frontmatter lines>]: the story, already closed (Done, date_completed set), valid story format
mk_story() {
  local f="$ROOT/project/board/stories/E99_S01_fixture.md"
  {
    printf '%s\n' '---' 'id: E99_S01' 'epic_id: E99' 'title: Fixture story' 'status: Done' 'date_created: 2026-10-25' \
      'date_completed: 2026-11-06' 'tasks:' '  - E99_S01_T01' '  - E99_S01_T02'
    [ -z "${1:-}" ] || printf '%s\n' "$1"
    printf '%s\n' '---' '' '# Story: Fixture story' '' '## Acceptance Criteria' '' '- [x] Fixture' '' \
      '## Definition of Done' '' '- [x] Fixture'
  } >"$f"
}

# mk_transcript <task-id> <input> <output> <cache_write> <cache_read> [<session>]: one task-mapped subagent transcript
mk_transcript() {
  local sess="${6:-sess-1}" d="$PROJECTS/$SLUG/${6:-sess-1}/subagents"
  mkdir -p "$d"
  printf '{"agentType":"developer","name":"%s","description":"fixture"}\n' "$1" >"$d/agent-$1.meta.json"
  {
    printf '{"type":"user","isSidechain":true,"message":{"role":"user","content":"hello"}}\n'
    printf '{"type":"assistant","requestId":"r-%s","message":{"role":"assistant","usage":{"input_tokens":%s,"output_tokens":%s,"cache_creation_input_tokens":%s,"cache_read_input_tokens":%s}}}\n' \
      "$1" "$2" "$3" "$4" "$5"
  } >"$d/agent-$1.jsonl"
}

# mk_session <session> <input> <output> <cache_write> <cache_read>: a main-session (orchestrator overhead) transcript
mk_session() {
  {
    printf '{"type":"user","message":{"role":"user","content":"hello"}}\n'
    printf '{"type":"assistant","requestId":"s-%s","message":{"role":"assistant","usage":{"input_tokens":%s,"output_tokens":%s,"cache_creation_input_tokens":%s,"cache_read_input_tokens":%s}}}\n' \
      "$1" "$2" "$3" "$4" "$5"
  } >"$PROJECTS/$SLUG/$1.jsonl"
}

# the standard measurement: T01 1/10/100/1000, T02 2/20/200/2000, one orchestrator session 3/7/20/500
# => task part 3/30/300/3000 (3333), overhead 3/7/20/500 (530), story total 6/37/320/3500 (3863)
mk_standard() {
  mk_transcript E99_S01_T01 1 10 100 1000
  mk_transcript E99_S01_T02 2 20 200 2000
  mk_session sess-1 3 7 20 500
}

# sfm <key>: the key's frontmatter value in the story's board file
sfm() { sed -n "s/^$1:[[:space:]]*//p" "$ROOT/project/board/stories/E99_S01_fixture.md" | head -n 1; }

# the story file's usage_* lines (count)
usage_lines() { grep -c '^usage_' "$ROOT/project/board/stories/E99_S01_fixture.md" || true; }

# ---------------------------------------------------------------------------------------------------------------
# the numbers: task part, overhead part and total
# ---------------------------------------------------------------------------------------------------------------

@test "the story file carries the task part, the overhead part and the total of task-usage.sh --stories" {
  mk_root "$BATS_TEST_TMPDIR/proj" linked
  mk_standard
  cd "$ROOT"
  bash scripts/task-usage.sh --report --stories E99_S01 >"$BATS_TEST_TMPDIR/report.json"

  run --separate-stderr bash "$HELPER" E99_S01
  [ "$status" -eq 0 ]

  for f in input output cache_write cache_read; do
    k_t="usage_tasks_${f}_tokens"; k_o="usage_overhead_${f}_tokens"
    [ "$(sfm "$k_t")" = "$(jq -r --arg f "$f" '.stories.E99_S01.tasks[$f]' "$BATS_TEST_TMPDIR/report.json")" ]
    [ "$(sfm "$k_o")" = "$(jq -r --arg f "$f" '.stories.E99_S01.allocated_overhead[$f]' "$BATS_TEST_TMPDIR/report.json")" ]
  done
  [ "$(sfm usage_tasks_total_tokens)" = "$(jq -r '.stories.E99_S01.tasks.total_tokens' "$BATS_TEST_TMPDIR/report.json")" ]
  [ "$(sfm usage_overhead_total_tokens)" = "$(jq -r '.stories.E99_S01.allocated_overhead.total_tokens' "$BATS_TEST_TMPDIR/report.json")" ]
  [ "$(sfm usage_total_tokens)" = "$(jq -r '.stories.E99_S01.total.total_tokens' "$BATS_TEST_TMPDIR/report.json")" ]
  [ "$(sfm usage_measured_on)" = 2026-11-06 ]

  # the fixture's known numbers
  [ "$(sfm usage_tasks_total_tokens)" = 3333 ]
  [ "$(sfm usage_overhead_total_tokens)" = 530 ]
  [ "$(sfm usage_total_tokens)" = 3863 ]
  [ "$(usage_lines)" -eq 12 ]
}

@test "the story total equals the task part plus the overhead part" {
  mk_root "$BATS_TEST_TMPDIR/proj" linked
  mk_standard
  cd "$ROOT"
  run bash "$HELPER" E99_S01
  [ "$status" -eq 0 ]
  [ "$(sfm usage_total_tokens)" -eq "$(( $(sfm usage_tasks_total_tokens) + $(sfm usage_overhead_total_tokens) ))" ]
  # and each part is the sum of its own four fields
  [ "$(sfm usage_tasks_total_tokens)" -eq "$(( $(sfm usage_tasks_input_tokens) + $(sfm usage_tasks_output_tokens) + $(sfm usage_tasks_cache_write_tokens) + $(sfm usage_tasks_cache_read_tokens) ))" ]
  [ "$(sfm usage_overhead_total_tokens)" -eq "$(( $(sfm usage_overhead_input_tokens) + $(sfm usage_overhead_output_tokens) + $(sfm usage_overhead_cache_write_tokens) + $(sfm usage_overhead_cache_read_tokens) ))" ]
}

@test "the closing report prints the task part, the overhead part and the total" {
  mk_root "$BATS_TEST_TMPDIR/proj" linked
  mk_standard
  cd "$ROOT"
  run bash "$HELPER" E99_S01
  [ "$status" -eq 0 ]
  [[ "$output" == *"Story usage (task-usage.sh --report --stories E99_S01):"* ]]
  [[ "$output" == *"tasks:    total=3333 tokens (input=3, output=30, cache_write=300, cache_read=3000)"* ]]
  [[ "$output" == *"overhead: total=530 tokens (input=3, output=7, cache_write=20, cache_read=500)"* ]]
  [[ "$output" == *"story:    total=3863 tokens (tasks 3333 + overhead 530)"* ]]
  [[ "$output" == *"unallocated overhead in this story's session: none"* ]]
  [[ "$output" == *"recorded in "*"E99_S01_fixture.md"* ]]
}

@test "a story with no overhead records an explicit zero overhead part, not a missing one" {
  mk_root "$BATS_TEST_TMPDIR/proj" linked
  mk_transcript E99_S01_T01 1 10 100 1000
  mk_transcript E99_S01_T02 2 20 200 2000
  cd "$ROOT"
  run bash "$HELPER" E99_S01
  [ "$status" -eq 0 ]
  [ "$(sfm usage_overhead_total_tokens)" = 0 ]
  [ "$(sfm usage_total_tokens)" = 3333 ]
}

@test "a task of the story without a measurement is named, and the story still records the measured part" {
  mk_root "$BATS_TEST_TMPDIR/proj" linked
  mk_transcript E99_S01_T01 1 10 100 1000
  mk_session sess-1 3 7 20 500
  cd "$ROOT"
  run bash "$HELPER" E99_S01
  [ "$status" -eq 0 ]
  [[ "$output" == *"note: tasks without a measurement: E99_S01_T02"* ]]
  [ "$(sfm usage_tasks_total_tokens)" = 1111 ]
  [ "$(sfm usage_total_tokens)" = 1641 ]
}

@test "unallocated overhead of the story's own session is reported, one from another session is not" {
  mk_root "$BATS_TEST_TMPDIR/proj" linked
  # both tasks only read the cache: weight 0, so the session's overhead cannot be placed (reason zero-weight)
  mk_transcript E99_S01_T01 0 0 0 1000
  mk_transcript E99_S01_T02 0 0 0 2000
  mk_session sess-1 3 7 20 500
  # an unrelated session with no task in it: unallocated too (no-candidate-story), but not this story's
  mk_session sess-other 100 100 100 100
  cd "$ROOT"
  run bash "$HELPER" E99_S01
  [ "$status" -eq 0 ]
  [[ "$output" == *"unallocated overhead in this story's session (charged to no story): total=530 tokens (input=3, output=7, cache_write=20, cache_read=500), entries=1 (zero-weight)"* ]]
  [[ "$output" != *"no-candidate-story"* ]]
  # the unallocated tokens are in no story field
  [ "$(sfm usage_overhead_total_tokens)" = 0 ]
  [ "$(sfm usage_total_tokens)" = 3000 ]
}

# ---------------------------------------------------------------------------------------------------------------
# validators and unchanged behaviour
# ---------------------------------------------------------------------------------------------------------------

@test "the story file still passes validate-board.sh and validate-story-format.sh" {
  mk_root "$BATS_TEST_TMPDIR/proj" linked
  mk_standard
  cd "$ROOT"
  run bash "$HELPER" E99_S01
  [ "$status" -eq 0 ]

  run bash "$VALIDATE" "$ROOT/project/board/stories/E99_S01_fixture.md"
  [ "$status" -eq 0 ]
  [[ "$output" == *"board frontmatter valid (story)"* ]]
  run bash "$VALIDATE_STORY" "$ROOT/project/board/stories/E99_S01_fixture.md"
  [ "$status" -eq 0 ]
}

@test "the helper leaves the story's status, date_completed, tasks and body untouched" {
  mk_root "$BATS_TEST_TMPDIR/proj" linked
  mk_standard
  cd "$ROOT"
  cp "$ROOT/project/board/stories/E99_S01_fixture.md" "$BATS_TEST_TMPDIR/before.md"
  run bash "$HELPER" E99_S01
  [ "$status" -eq 0 ]
  [ "$(sfm status)" = Done ]
  [ "$(sfm date_completed)" = 2026-11-06 ]
  # nothing but the added usage_* lines differs
  run diff <(grep -v '^usage_' "$ROOT/project/board/stories/E99_S01_fixture.md") "$BATS_TEST_TMPDIR/before.md"
  [ "$status" -eq 0 ]
  # and no task file was touched
  [ -z "$(grep -l '^usage_' "$ROOT"/project/board/tasks/*.md || true)" ]
}

@test "the story file mode and the lock/temporary files are left as found" {
  mk_root "$BATS_TEST_TMPDIR/proj" linked
  mk_standard
  cd "$ROOT"
  chmod 640 "$ROOT/project/board/stories/E99_S01_fixture.md"
  run bash "$HELPER" E99_S01
  [ "$status" -eq 0 ]
  [ "$(stat -c %a "$ROOT/project/board/stories/E99_S01_fixture.md" 2>/dev/null || stat -f %Lp "$ROOT/project/board/stories/E99_S01_fixture.md")" = 640 ]
  [ -z "$(ls "$ROOT/project/board/stories" | grep -v '^E99_S01_fixture.md$' || true)" ]
}

# ---------------------------------------------------------------------------------------------------------------
# rerun, incompleteness
# ---------------------------------------------------------------------------------------------------------------

@test "a rerun with the same transcripts writes the same numbers (idempotent)" {
  mk_root "$BATS_TEST_TMPDIR/proj" linked
  mk_standard
  cd "$ROOT"
  run bash "$HELPER" E99_S01
  cp "$ROOT/project/board/stories/E99_S01_fixture.md" "$BATS_TEST_TMPDIR/first.md"
  run bash "$HELPER" E99_S01
  [ "$status" -eq 0 ]
  run diff "$ROOT/project/board/stories/E99_S01_fixture.md" "$BATS_TEST_TMPDIR/first.md"
  [ "$status" -eq 0 ]
}

@test "possibly incomplete: a task flagged usage_possibly_incomplete flags the story" {
  mk_root "$BATS_TEST_TMPDIR/proj" linked
  mk_task T01 "First task" 'usage_possibly_incomplete: true'
  mk_standard
  cd "$ROOT"
  run bash "$HELPER" E99_S01
  [ "$status" -eq 0 ]
  [ "$(sfm usage_possibly_incomplete)" = true ]
  [[ "$output" == *"usage_possibly_incomplete: true"* ]]
}

@test "no flag on the story when no task is flagged (never written as false)" {
  mk_root "$BATS_TEST_TMPDIR/proj" linked
  mk_standard
  cd "$ROOT"
  run bash "$HELPER" E99_S01
  [ "$status" -eq 0 ]
  [ -z "$(sfm usage_possibly_incomplete)" ]
}

@test "a persisted task part is never lowered: stored values are kept and the story is flagged" {
  mk_root "$BATS_TEST_TMPDIR/proj" linked
  mk_story 'usage_tasks_input_tokens: 9
usage_tasks_output_tokens: 90
usage_tasks_cache_write_tokens: 900
usage_tasks_cache_read_tokens: 9000
usage_tasks_total_tokens: 9999
usage_overhead_input_tokens: 0
usage_overhead_output_tokens: 0
usage_overhead_cache_write_tokens: 0
usage_overhead_cache_read_tokens: 0
usage_overhead_total_tokens: 0
usage_total_tokens: 9999
usage_measured_on: 2026-10-30'
  # only one of the two tasks' transcripts is left now: the recomputed task part (1111) is below the stored 9999
  mk_transcript E99_S01_T01 1 10 100 1000
  cd "$ROOT"

  run bash "$HELPER" E99_S01
  [ "$status" -eq 0 ]
  [[ "$output" == *"kept: the recomputed task part (1111 tokens) is below the persisted 9999 tokens"* ]]
  [ "$(sfm usage_tasks_total_tokens)" = 9999 ]
  [ "$(sfm usage_total_tokens)" = 9999 ]
  [ "$(sfm usage_measured_on)" = 2026-10-30 ]
  [ "$(sfm usage_possibly_incomplete)" = true ]
}

# ---------------------------------------------------------------------------------------------------------------
# not measured: nothing is written, the reason is reported, the close goes on
# ---------------------------------------------------------------------------------------------------------------

@test "not measured: no transcript for any task writes no field and reports the reason" {
  mk_root "$BATS_TEST_TMPDIR/proj" linked
  # a subagent transcript of ANOTHER story's task: task-usage.sh finds a subagents/ layout (its layout check needs one)
  # but no transcript of E99_S01's tasks
  mk_transcript E98_S01_T01 1 1 1 1
  mk_session sess-1 3 7 20 500
  cd "$ROOT"
  cp "$ROOT/project/board/stories/E99_S01_fixture.md" "$BATS_TEST_TMPDIR/before.md"

  run --separate-stderr bash "$HELPER" E99_S01
  [ "$status" -eq 0 ]
  [[ "$output" == *"Story usage (task-usage.sh --report --stories E99_S01):"* ]]
  [[ "$output" == *"not measured: no task of the story has a transcript"* ]]
  [[ "$output" != *"total="* ]]
  [ "$(usage_lines)" -eq 0 ]
  run diff "$ROOT/project/board/stories/E99_S01_fixture.md" "$BATS_TEST_TMPDIR/before.md"
  [ "$status" -eq 0 ]
}

@test "not measured: no subagents/ directory at all (layout check fails) writes no field and reports a reason" {
  mk_root "$BATS_TEST_TMPDIR/proj" linked
  mk_session sess-1 3 7 20 500
  cd "$ROOT"
  cp "$ROOT/project/board/stories/E99_S01_fixture.md" "$BATS_TEST_TMPDIR/before.md"

  run --separate-stderr bash "$HELPER" E99_S01
  [ "$status" -eq 0 ]
  [[ "$output" == *"not measured: usage measurement failed"* ]]
  [[ "$output" != *"total="* ]]
  [ "$(usage_lines)" -eq 0 ]
  run diff "$ROOT/project/board/stories/E99_S01_fixture.md" "$BATS_TEST_TMPDIR/before.md"
  [ "$status" -eq 0 ]
}

@test "not measured: a failing task-usage.sh is reported, exit 0, no field written, status untouched" {
  mk_root "$BATS_TEST_TMPDIR/proj" linked
  mk_standard
  # a projects directory that does not exist: task-usage.sh fails its layout check 1 with exit 4
  export JENGA_PROJECTS_DIR="$BATS_TEST_TMPDIR/does-not-exist"
  cd "$ROOT"

  run --separate-stderr bash "$HELPER" E99_S01
  [ "$status" -eq 0 ]
  [[ "$output" == *"not measured: usage measurement failed (exit 4)"* ]]
  [ "$(usage_lines)" -eq 0 ]
  [ "$(sfm status)" = Done ]
  [ "$(sfm date_completed)" = 2026-11-06 ]
}

@test "not measured: a report whose story total is not task part plus overhead part writes nothing" {
  mk_root "$BATS_TEST_TMPDIR/proj" none
  mkdir -p "$ROOT/scripts"
  cat >"$ROOT/scripts/task-usage.sh" <<'EOF'
#!/usr/bin/env bash
cat <<'JSON'
{"schema_version":1,"tasks":{},"overhead":[],"unmapped":[],"warnings":[],"unallocated_overhead":[],
 "stories":{"E99_S01":{"epic_id":"E99","measured":true,"weight":1,"board_tasks":null,"measured_tasks":[],"unmeasured_tasks":null,
  "tasks":{"input":1,"output":1,"cache_write":1,"cache_read":1,"total_tokens":4},
  "allocated_overhead":{"input":1,"output":1,"cache_write":1,"cache_read":1,"total_tokens":4},
  "total":{"input":2,"output":2,"cache_write":2,"cache_read":2,"total_tokens":9}}}}
JSON
EOF
  cd "$ROOT"

  run bash "$HELPER" E99_S01
  [ "$status" -eq 0 ]
  [[ "$output" == *"not measured: the report's story total (9) is not the task part (4) plus the overhead part (4)"* ]]
  [ "$(usage_lines)" -eq 0 ]
}

@test "a missing story board file warns, prints the numbers and writes nothing" {
  mk_root "$BATS_TEST_TMPDIR/proj" linked
  mk_standard
  rm "$ROOT/project/board/stories/E99_S01_fixture.md"
  cd "$ROOT"
  run bash "$HELPER" E99_S01
  [ "$status" -eq 0 ]
  [[ "$output" == *"story:    total=3863 tokens"* ]]
  [[ "$output" == *"WARNING: the story usage fields were not written: no board file found for E99_S01"* ]]
}

@test "a bad or missing story id is a usage error (exit 2) and writes nothing" {
  mk_root "$BATS_TEST_TMPDIR/proj" linked
  cd "$ROOT"
  run bash "$HELPER"
  [ "$status" -eq 2 ]
  run bash "$HELPER" 'E99_S01;rm'
  [ "$status" -eq 2 ]
  run bash "$HELPER" E99
  [ "$status" -eq 2 ]
}

# ---------------------------------------------------------------------------------------------------------------
# public-mirror guard: silent when the script exists in neither location
# ---------------------------------------------------------------------------------------------------------------

@test "silent skip: no task-usage.sh in either location prints nothing, writes nothing, exits 0" {
  mk_root "$BATS_TEST_TMPDIR/proj" none
  mk_standard
  cd "$ROOT"
  [ ! -e "$ROOT/scripts/task-usage.sh" ]
  [ ! -e "$ROOT/node_modules/@jenga-ai/agent/scripts/task-usage.sh" ]
  cp "$ROOT/project/board/stories/E99_S01_fixture.md" "$BATS_TEST_TMPDIR/before.md"

  run --separate-stderr bash "$HELPER" E99_S01
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ -z "$stderr" ]
  [ "$(usage_lines)" -eq 0 ]
  run diff "$ROOT/project/board/stories/E99_S01_fixture.md" "$BATS_TEST_TMPDIR/before.md"
  [ "$status" -eq 0 ]
}

@test "the installed-package fallback is used when scripts/task-usage.sh is not in the project" {
  mk_root "$BATS_TEST_TMPDIR/proj" package
  mk_standard
  cd "$ROOT"
  [ ! -e "$ROOT/scripts/task-usage.sh" ]

  run bash "$HELPER" E99_S01
  [ "$status" -eq 0 ]
  [[ "$output" == *"story:    total=3863 tokens"* ]]
  [ "$(sfm usage_total_tokens)" = 3863 ]
}

@test "the helper is a plain script that needs no mode bit" {
  # invoked as `bash <path>` like its siblings, so the missing exec bit (chmod +x is not available here) is harmless
  run bash -n "$HELPER"
  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------------------------------------------
# the skill documents it, and keeps what was there
# ---------------------------------------------------------------------------------------------------------------

@test "SKILL.md Step 4 calls the helper with the skill's dual-path idiom and states the three rules" {
  step4="$(sed -n '/^### Step 4/,/^### Step 5/p' "$SKILL_MD")"
  [[ "$step4" == *'skills/j-close-story/scripts/write-story-usage.sh'* ]]
  [[ "$step4" == *'node_modules/@jenga-ai/agent/skills/j-close-story/scripts/write-story-usage.sh'* ]]
  [[ "$step4" == *'--report --stories <story-id>'* ]]
  [[ "$step4" == *'Non-blocking'* ]]
  [[ "$step4" == *'Never a guess'* ]]
  [[ "$step4" == *'Silent when absent'* ]]
}

@test "SKILL.md Step 5 has a Story usage section and the Scripts Reference and Purpose list the helper" {
  step5="$(sed -n '/^### Step 5/,/^## Scripts Reference/p' "$SKILL_MD")"
  [[ "$step5" == *'#### Story usage'* ]]
  [[ "$step5" == *'not measured: <reason>'* ]]
  [[ "$step5" == *'omit the section'* ]]
  grep -q '`scripts/write-story-usage.sh <story-id>`' "$SKILL_MD"
  sed -n '/^## Purpose/,/^---/p' "$SKILL_MD" | grep -q 'E76_S03_T05'
}

@test "SKILL.md still carries the existing close behaviour: status, date_completed, privatized, per-task usage" {
  step4="$(sed -n '/^### Step 4/,/^### Step 5/p' "$SKILL_MD")"
  [[ "$step4" == *'check-privatized.sh'* ]]
  [[ "$step4" == *'`status: Done`'* ]]
  [[ "$step4" == *'`date_completed: <YYYY-MM-DD>`'* ]]
  grep -q 'persist-task-usage.sh' "$SKILL_MD"
  grep -q 'extract-task-diff-stats.sh' "$SKILL_MD"
  grep -q 'compute-scope-divergence.sh' "$SKILL_MD"
}
