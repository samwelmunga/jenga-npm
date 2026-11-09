#!/usr/bin/env bats
#
# E76_S03_T01: j.close-story persists per-task token usage next to the diff stats, through
# skills/j-close-story/scripts/persist-task-usage.sh, which calls scripts/task-usage.sh --persist --story <id>.
#
# Covered: the call path (and that SKILL.md Step 2 / Step 5 document it with the skill's script-lookup idiom), the
# silent skip when scripts/task-usage.sh exists in neither location (public-mirror guard), the installed-package
# fallback, non-blocking behaviour on a failing script (exit 0, task statuses untouched, a WARNING naming the
# reason), the "not measured" wording (never a zero), the usage_possibly_incomplete flag, and that a persisted task
# still passes scripts/validate-board.sh.
#
# Everything is built under $BATS_TEST_TMPDIR: a throwaway project root (its own git repository, so the transcript
# slug is the fixture's own path) with synthetic subagent transcripts; no real ~/.claude/projects data is read.
# E76 ships publicly (decided 2026-11-07), so this file ships and must not depend on anything private.

bats_require_minimum_version 1.5.0

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
HELPER="$REPO_ROOT/skills/j-close-story/scripts/persist-task-usage.sh"
SKILL_MD="$REPO_ROOT/skills/j-close-story/SKILL.md"
VALIDATE="$REPO_ROOT/scripts/validate-board.sh"

setup() {
  unset JENGA_PROJECT_ROOT JENGA_PROJECTS_DIR
  export TASK_USAGE_TODAY=2026-11-06
  export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
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

# mk_transcript <task-id>: one task-mapped subagent transcript: input 1, output 10, cache write 100, cache read 1000
# (usage_total_tokens 1111)
mk_transcript() {
  local d="$PROJECTS/$SLUG/sess-1/subagents"
  mkdir -p "$d"
  printf '{"agentType":"developer","name":"%s","description":"fixture"}\n' "$1" >"$d/agent-$1.meta.json"
  {
    printf '{"type":"user","isSidechain":true,"message":{"role":"user","content":"hello"}}\n'
    printf '{"type":"assistant","requestId":"r1","message":{"role":"assistant","usage":{"input_tokens":1,"output_tokens":10,"cache_creation_input_tokens":100,"cache_read_input_tokens":1000}}}\n'
  } >"$d/agent-$1.jsonl"
}

# fm <task-id> <key>: the key's frontmatter value of the task's board file
fm() {
  sed -n "s/^$2:[[:space:]]*//p" "$ROOT/project/board/tasks/${1}_fixture.md" | head -n 1
}

# ---------------------------------------------------------------------------------------------------------------
# call path
# ---------------------------------------------------------------------------------------------------------------

@test "call path: the helper persists the measured task and reports its totals" {
  mk_root "$BATS_TEST_TMPDIR/proj" linked
  mk_transcript E99_S01_T01
  cd "$ROOT"

  run --separate-stderr bash "$HELPER" E99_S01
  [ "$status" -eq 0 ]
  [[ "$output" == *"Usage (task-usage.sh --persist --story E99_S01):"* ]]
  [[ "$output" == *"E99_S01_T01: total=1111 tokens (input=1, output=10, cache_write=100, cache_read=1000), transcripts=1"* ]]

  # the numbers were written by task-usage.sh into the task's own frontmatter
  [ "$(fm E99_S01_T01 usage_total_tokens)" = 1111 ]
  [ "$(fm E99_S01_T01 usage_input_tokens)" = 1 ]
  [ "$(fm E99_S01_T01 usage_output_tokens)" = 10 ]
  [ "$(fm E99_S01_T01 usage_cache_write_tokens)" = 100 ]
  [ "$(fm E99_S01_T01 usage_cache_read_tokens)" = 1000 ]
  [ "$(fm E99_S01_T01 usage_transcripts)" = 1 ]
  [ "$(fm E99_S01_T01 usage_measured_on)" = 2026-11-06 ]
}

@test "a persisted task still passes scripts/validate-board.sh" {
  mk_root "$BATS_TEST_TMPDIR/proj" linked
  mk_transcript E99_S01_T01
  cd "$ROOT"
  run bash "$HELPER" E99_S01
  [ "$status" -eq 0 ]

  run bash "$VALIDATE" "$ROOT/project/board/tasks/E99_S01_T01_fixture.md"
  [ "$status" -eq 0 ]
  [[ "$output" == *"board frontmatter valid (task)"* ]]
}

@test "the installed-package fallback is used when scripts/task-usage.sh is not in the project" {
  mk_root "$BATS_TEST_TMPDIR/proj" package
  mk_transcript E99_S01_T01
  cd "$ROOT"
  [ ! -e "$ROOT/scripts/task-usage.sh" ]

  run bash "$HELPER" E99_S01
  [ "$status" -eq 0 ]
  [[ "$output" == *"E99_S01_T01: total=1111 tokens"* ]]
  [ "$(fm E99_S01_T01 usage_total_tokens)" = 1111 ]
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

@test "silent skip: no task-usage.sh in either location prints nothing and exits 0" {
  mk_root "$BATS_TEST_TMPDIR/proj" none
  mk_transcript E99_S01_T01
  cd "$ROOT"
  [ ! -e "$ROOT/scripts/task-usage.sh" ]
  [ ! -e "$ROOT/node_modules/@jenga-ai/agent/scripts/task-usage.sh" ]

  run --separate-stderr bash "$HELPER" E99_S01
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ -z "$stderr" ]
  # and it wrote nothing to the board
  [ -z "$(fm E99_S01_T01 usage_total_tokens)" ]
}

# ---------------------------------------------------------------------------------------------------------------
# non-blocking, "not measured"
# ---------------------------------------------------------------------------------------------------------------

@test "not measured: a task with no transcripts is reported with a reason, never as zero" {
  mk_root "$BATS_TEST_TMPDIR/proj" linked
  mk_transcript E99_S01_T01
  cd "$ROOT"

  run bash "$HELPER" E99_S01
  [ "$status" -eq 0 ]
  [[ "$output" == *"E99_S01_T02: not measured: "* ]]
  [[ "$output" != *"E99_S01_T02: total="* ]]
  [[ "$output" != *"total=0"* ]]
  [ -z "$(fm E99_S01_T02 usage_total_tokens)" ]
  [ -z "$(fm E99_S01_T02 usage_transcripts)" ]
}

@test "non-blocking: a failing task-usage.sh is reported as a WARNING, exit 0, no status touched" {
  mk_root "$BATS_TEST_TMPDIR/proj" linked
  # a projects directory that does not exist: task-usage.sh fails its layout check 1 with exit 4
  export JENGA_PROJECTS_DIR="$BATS_TEST_TMPDIR/does-not-exist"
  cd "$ROOT"

  run --separate-stderr bash "$HELPER" E99_S01
  [ "$status" -eq 0 ]
  [[ "$output" == *"WARNING: usage measurement exited 4"* ]]
  [[ "$output" == *"the close continues and no task status was changed"* ]]
  [[ "$output" == *"E99_S01_T01: not measured: usage measurement failed (exit 4)"* ]]
  [[ "$output" == *"E99_S01_T02: not measured: usage measurement failed (exit 4)"* ]]
  [ "$(fm E99_S01_T01 status)" = Passed ]
  [ "$(fm E99_S01_T02 status)" = Passed ]
  [ -z "$(fm E99_S01_T01 usage_total_tokens)" ]
}

@test "non-blocking: a stub task-usage.sh exiting 9 with a failed result names the task and the reason" {
  mk_root "$BATS_TEST_TMPDIR/proj" none
  mkdir -p "$ROOT/scripts"
  cat >"$ROOT/scripts/task-usage.sh" <<'EOF'
#!/usr/bin/env bash
echo 'task-usage.sh: E99_S01_T01: could not acquire the lock: write skipped' >&2
printf '%s\n' '{"schema_version":1,"results":[{"id":"E99_S01_T01","status":"failed","message":"lock on the board file not acquired; write skipped"}]}'
exit 9
EOF
  cd "$ROOT"

  run --separate-stderr bash "$HELPER" E99_S01
  [ "$status" -eq 0 ]
  [[ "$output" == *"WARNING: usage measurement exited 9"* ]]
  [[ "$output" == *"E99_S01_T01: not measured: lock on the board file not acquired; write skipped"* ]]
  [[ "$output" == *"WARNING: E99_S01_T01: lock on the board file not acquired; write skipped"* ]]
  [ "$(fm E99_S01_T01 status)" = Passed ]
}

@test "possibly incomplete: a task whose persisted total is flagged is shown as such" {
  mk_root "$BATS_TEST_TMPDIR/proj" linked
  # persisted totals above what the transcript still shows: --persist keeps them and sets the flag
  mk_task T01 "First task" 'usage_input_tokens: 5
usage_output_tokens: 50
usage_cache_write_tokens: 500
usage_cache_read_tokens: 5000
usage_total_tokens: 5555
usage_transcripts: 2
usage_measured_on: 2026-10-30'
  mk_transcript E99_S01_T01
  cd "$ROOT"

  run bash "$HELPER" E99_S01
  [ "$status" -eq 0 ]
  [[ "$output" == *"E99_S01_T01: total=5555 tokens"* ]]
  [[ "$output" == *"usage_possibly_incomplete"* ]]
  [ "$(fm E99_S01_T01 usage_possibly_incomplete)" = true ]
}

# ---------------------------------------------------------------------------------------------------------------
# the skill documents it
# ---------------------------------------------------------------------------------------------------------------

@test "SKILL.md Step 2 calls the helper, with the skill's script-lookup idiom, and states the silent skip" {
  step2="$(sed -n '/^### Step 2/,/^### Step 3/p' "$SKILL_MD")"
  [[ "$step2" == *'skills/j-close-story/scripts/persist-task-usage.sh'* ]]
  [[ "$step2" == *'node_modules/@jenga-ai/agent/skills/j-close-story/scripts/persist-task-usage.sh'* ]]
  [[ "$step2" == *'--persist --story <story-id>'* ]]
  [[ "$step2" == *'[ -f scripts/task-usage.sh ] && echo scripts/task-usage.sh || echo node_modules/@jenga-ai/agent/scripts/task-usage.sh'* ]]
  [[ "$step2" == *'Non-blocking'* ]]
  [[ "$step2" == *'Silent when absent'* ]]
}

@test "SKILL.md Step 5 reports per-task totals or 'not measured: <reason>' and flags usage_possibly_incomplete" {
  step5="$(sed -n '/^### Step 5/,/^## Scripts Reference/p' "$SKILL_MD")"
  [[ "$step5" == *'#### Usage'* ]]
  [[ "$step5" == *'not measured: <reason>'* ]]
  [[ "$step5" == *'usage_possibly_incomplete'* ]]
  [[ "$step5" == *'omit the section'* ]]
}

@test "the existing diff-stat and scope-divergence steps are still in SKILL.md" {
  grep -q 'extract-task-diff-stats.sh' "$SKILL_MD"
  grep -q 'compute-scope-divergence.sh' "$SKILL_MD"
  grep -q 'scope_divergence_flag' "$SKILL_MD"
}
