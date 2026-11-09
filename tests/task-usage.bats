#!/usr/bin/env bats
#
# E76_S01_T06: scripts/task-usage.sh attributes transcript token usage to board tasks.
# Public interface only (--report, --usage, --list-transcripts, --task, --story, --projects-dir, --project-dir),
# run against the synthetic transcripts in tests/fixtures/task-usage/. Every expected number below is the
# hand-computed value in tests/fixtures/task-usage/README.md ("case N" comments point at its sections).
# Nothing here reads ~/.claude/projects or writes outside $BATS_TEST_TMPDIR.

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
SCRIPT="$REPO_ROOT/scripts/task-usage.sh"
FIX="$REPO_ROOT/tests/fixtures/task-usage"
PROJECT_DIR="/fixture/proj"   # slug -fixture-proj; the path does not need to exist

setup() {
  unset JENGA_PROJECTS_DIR
}

# report [extra args...]: --report against the fixture tree; JSON on $output, stderr dropped
report() {
  run bash -c '"$@" 2>/dev/null' _ "$SCRIPT" --report --projects-dir "$FIX/projects" --project-dir "$PROJECT_DIR" "$@"
}

# task_is <id> <input> <output> <cache_write> <cache_read> <total> <transcripts>: exact record check on $output
task_is() {
  echo "$output" | jq -e --arg id "$1" \
    --argjson i "$2" --argjson o "$3" --argjson w "$4" --argjson r "$5" --argjson t "$6" --argjson n "$7" '
    .tasks[$id] as $x
    | $x.input == $i and $x.output == $o and $x.cache_write == $w and $x.cache_read == $r
      and $x.usage_total_tokens == $t and $x.usage_transcripts == $n' >/dev/null
}

# ---------------------------------------------------------------------------------------------------------------
# case 1: streaming trap (last line per requestId)
# ---------------------------------------------------------------------------------------------------------------

@test "streaming trap: --usage counts 2 calls on 5 usage lines and sums the LAST line per requestId" {
  run bash "$SCRIPT" --usage "$FIX/projects/-fixture-proj/sess-0001/subagents/agent-a0001.jsonl"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.calls == 2 and .usage_lines == 5 and .calls_without_request_id == 0' >/dev/null
  # last line per requestId: output 700 + 200 = 900. First line would give 150, every line 1350.
  echo "$output" | jq -e '.input == 30 and .output == 900 and .cache_write == 1000 and .cache_read == 11000' >/dev/null
}

@test "streaming trap: the report's task total is the last-line figure, not first-line or every-line" {
  report
  [ "$status" -eq 0 ]
  task_is E99_S01_T01 30 900 1000 11000 12930 1
  # the two wrong rules give 12180 (first line) and 31420 (every line)
  echo "$output" | jq -e '.tasks.E99_S01_T01 | .usage_total_tokens != 12180 and .usage_total_tokens != 31420 and .output != 150 and .output != 1350' >/dev/null
}

# ---------------------------------------------------------------------------------------------------------------
# cases 2 and 3: rework across transcripts and sessions, and the -tester suffix
# ---------------------------------------------------------------------------------------------------------------

@test "rework and tester suffix: three transcripts in two sessions sum into the one task" {
  report
  [ "$status" -eq 0 ]
  task_is E99_S01_T02 17 1700 3500 31000 36217 3
  echo "$output" | jq -e '.tasks.E99_S01_T02.transcripts | length == 3' >/dev/null
  # the -tester transcript (agent-b0003) is one of the three, mapped to the same task
  echo "$output" | jq -e '[.tasks.E99_S01_T02.transcripts[] | select(endswith("agent-b0003.jsonl"))] | length == 1' >/dev/null
  # the rework in the other session (sess-0003) is included
  echo "$output" | jq -e '[.tasks.E99_S01_T02.transcripts[] | select(contains("/sess-0003/"))] | length == 1' >/dev/null
}

@test "tester suffix: no separate E99_S01_T02-tester task exists" {
  report
  echo "$output" | jq -e '[.tasks | keys[] | select(test("tester"))] | length == 0' >/dev/null
}

# ---------------------------------------------------------------------------------------------------------------
# case 4: unmapped
# ---------------------------------------------------------------------------------------------------------------

@test "unmapped: verify-group5 is listed with its numbers and a reason, and is in no task" {
  report
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.unmapped | length == 1' >/dev/null
  echo "$output" | jq -e '.unmapped[0] | .name == "verify-group5" and .kind == "subagent"
      and .input == 6 and .output == 60 and .cache_write == 300 and .cache_read == 1500
      and (.reason | test("no board ID"))' >/dev/null
  echo "$output" | jq -e '[.tasks[].transcripts[] | select(contains("agent-c0001"))] | length == 0' >/dev/null
  echo "$output" | jq -e '.tasks | keys == ["E99_S01_T01","E99_S01_T02","E99_S01_T03","E99_S02_T01"]' >/dev/null
}

@test "unmapped: a transcript with no meta.json is listed unmapped with a 'no meta.json' reason, and --report now fails loudly (E76_S02_T01)" {
  # Stage 1 stays a lenient diagnostic: the record carries the reason.
  run bash -c '"$@" 2>/dev/null' _ "$SCRIPT" --list-transcripts --projects-dir "$FIX/projects-no-meta" --project-dir "$PROJECT_DIR"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e 'length == 1 and .[0].level == "none" and (.[0].reason | startswith("no meta.json"))' >/dev/null
  # --report refuses to print a result built on a transcript it cannot map: exit 6, nothing on stdout.
  run bash -c '"$@" 2>/dev/null' _ "$SCRIPT" --report --projects-dir "$FIX/projects-no-meta" --project-dir "$PROJECT_DIR"
  [ "$status" -eq 6 ]
  [ -z "$output" ]
}

# ---------------------------------------------------------------------------------------------------------------
# case 5: overhead
# ---------------------------------------------------------------------------------------------------------------

@test "overhead: the main session and the story-level scrum-master are listed with their numbers" {
  report
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.overhead | length == 2' >/dev/null
  echo "$output" | jq -e '.overhead[] | select(.kind == "session")
      | .agent_type == null and .id == null and .level == "none"
        and .input == 7 and .output == 70 and .cache_write == 400 and .cache_read == 2000' >/dev/null
  echo "$output" | jq -e '.overhead[] | select(.kind == "subagent")
      | .agent_type == "scrum-master" and .id == "E99_S01" and .level == "story"
        and .input == 8 and .output == 80 and .cache_write == 600 and .cache_read == 2500' >/dev/null
}

@test "overhead: nothing is allocated, the story-level entry is in no task and task totals exclude it" {
  report
  echo "$output" | jq -e '[.tasks[].transcripts[] | select(contains("agent-d0001") or endswith("sess-0001.jsonl"))] | length == 0' >/dev/null
  # E99_S01's tasks (T01+T02+T03) sum to total 56700 on their own; adding the story overhead (3188) would change it
  echo "$output" | jq -e '[.tasks | to_entries[] | select(.value.story_id == "E99_S01") | .value.usage_total_tokens] | add == 56700' >/dev/null
  # every transcript lands in exactly one bucket: 9 transcripts = 6 in tasks + 2 overhead + 1 unmapped
  echo "$output" | jq -e '([.tasks[].usage_transcripts] | add) == 6 and (.overhead | length) == 2 and (.unmapped | length) == 1' >/dev/null
}

# ---------------------------------------------------------------------------------------------------------------
# case 6: worktree-sibling slug and the prefix decoy
# ---------------------------------------------------------------------------------------------------------------

@test "worktree slug: the transcript under the --claude-worktrees- sibling slug is in its task's total" {
  report
  [ "$status" -eq 0 ]
  task_is E99_S02_T01 10 100 700 6700 7510 1
  echo "$output" | jq -e '.tasks.E99_S02_T01.transcripts[0] | contains("-fixture-proj--claude-worktrees-E99-S02-T01/")' >/dev/null
}

@test "worktree slug: the -fixture-proj-public decoy (a shared prefix, not a sibling) is never read" {
  report
  echo "$output" | jq -e 'tostring | (contains("E99_S09_T09") or contains("agent-z0001")) | not' >/dev/null
  run bash "$SCRIPT" --list-transcripts --projects-dir "$FIX/projects" --project-dir "$PROJECT_DIR"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e 'map(select(.slug_dir == "-fixture-proj-public")) | length == 0' >/dev/null
  echo "$output" | jq -e 'map(.slug_dir) | unique == ["-fixture-proj","-fixture-proj--claude-worktrees-E99-S02-T01"]' >/dev/null
}

# ---------------------------------------------------------------------------------------------------------------
# case 7: cache_creation breakdown is a part of the total
# ---------------------------------------------------------------------------------------------------------------

@test "cache split: the ephemeral breakdown is not added on top of cache_creation_input_tokens" {
  report
  task_is E99_S01_T03 3 150 1200 6200 7553 1
  echo "$output" | jq -e '.tasks.E99_S01_T03.cache_write != 2200' >/dev/null
}

# ---------------------------------------------------------------------------------------------------------------
# filters
# ---------------------------------------------------------------------------------------------------------------

@test "--task keeps only that task, with its full unfiltered numbers; overhead and unmapped stay complete" {
  report --task E99_S01_T02
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.tasks | keys == ["E99_S01_T02"]' >/dev/null
  task_is E99_S01_T02 17 1700 3500 31000 36217 3
  echo "$output" | jq -e '(.overhead | length) == 2 and (.unmapped | length) == 1' >/dev/null
}

@test "--task is repeatable and the filters are OR-ed" {
  report --task E99_S01_T01 --task=E99_S02_T01
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.tasks | keys == ["E99_S01_T01","E99_S02_T01"]' >/dev/null
}

@test "--story keeps only the tasks of that story" {
  report --story E99_S02
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.tasks | keys == ["E99_S02_T01"]' >/dev/null
  report --story E99_S01
  echo "$output" | jq -e '.tasks | keys == ["E99_S01_T01","E99_S01_T02","E99_S01_T03"]' >/dev/null
}

@test "--task with an ID that has no transcripts: exit 8 and nothing on stdout; in a bulk run it is a no-transcripts-for-task warning" {
  report --task E99_S05_T05
  [ "$status" -eq 8 ]
  [ -z "$output" ]
  report --task E99_S05_T05 --task E99_S01_T01
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.tasks | keys == ["E99_S01_T01"]' >/dev/null
  echo "$output" | jq -e '(.warnings | length == 1) and .warnings[0].code == "no-transcripts-for-task" and .warnings[0].id == "E99_S05_T05"' >/dev/null
}

# ---------------------------------------------------------------------------------------------------------------
# report shape
# ---------------------------------------------------------------------------------------------------------------

@test "usage_total_tokens equals input + output + cache_write + cache_read for every task" {
  report
  echo "$output" | jq -e '[.tasks[] | .usage_total_tokens == (.input + .output + .cache_write + .cache_read)] | length == 4 and all' >/dev/null
  echo "$output" | jq -e '.tasks | to_entries | map(.value.usage_total_tokens) == [12930, 36217, 7553, 7510]' >/dev/null
}

@test "report is valid JSON with the documented top-level keys and no warnings on the clean fixture" {
  report
  [ "$status" -eq 0 ]
  echo "$output" | jq -e . >/dev/null
  echo "$output" | jq -e '.schema_version == 1 and (.generated_at | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]+Z$")) and .warnings == []' >/dev/null
  echo "$output" | jq -e 'keys == ["generated_at","overhead","schema_version","tasks","unmapped","warnings"]' >/dev/null
  echo "$output" | jq -e '.tasks.E99_S01_T01 | .story_id == "E99_S01" and .epic_id == "E99"' >/dev/null
}

@test "tokens only: no key at any depth matches cost, price or usd" {
  report
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '[paths | map(strings) | .[] | select(test("cost|price|usd"; "i"))] | length == 0' >/dev/null
  run jq -e '[paths | map(strings) | .[] | select(test("cost|price|usd"; "i"))] | length == 0' <<<"$(bash "$SCRIPT" --usage "$FIX/projects/-fixture-proj/sess-0001.jsonl")"
  [ "$status" -eq 0 ]
}

@test "the projects directory can come from JENGA_PROJECTS_DIR, and the option wins over it" {
  JENGA_PROJECTS_DIR="$FIX/projects" run bash -c '"$@" 2>/dev/null' _ "$SCRIPT" --report --project-dir "$PROJECT_DIR"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.tasks | length == 4' >/dev/null
  # The option wins: the no-meta tree is read (exit 6, layout check 3), not the good tree the variable points at.
  JENGA_PROJECTS_DIR="$FIX/projects" run bash -c '"$@" 2>/dev/null' _ "$SCRIPT" --report --projects-dir "$FIX/projects-no-meta" --project-dir "$PROJECT_DIR"
  [ "$status" -eq 6 ]
}

# ---------------------------------------------------------------------------------------------------------------
# bad arguments and environment
# ---------------------------------------------------------------------------------------------------------------

@test "no mode given: exit 2, usage on stderr, nothing on stdout" {
  run bash -c '"$@" 2>"$0"' "$BATS_TEST_TMPDIR/err" "$SCRIPT"
  [ "$status" -eq 2 ]
  [ -z "$output" ]
  grep -q -- '--report' "$BATS_TEST_TMPDIR/err"
}

@test "bad arguments exit 2 and print nothing on stdout" {
  local args
  for args in "--bogus" "--report extra" "--report --list-transcripts" "--usage" "--task E99_S01_T01" "--story E99_S01" \
              "--report --task" "--report --task not-an-id" "--report --task E99_S01" "--report --story E99_S01_T01" \
              "--report --story=nope" "--report --projects-dir"; do
    run bash -c '"$@" 2>/dev/null' _ "$SCRIPT" $args --projects-dir "$FIX/projects"
    [ "$status" -eq 2 ] || { echo "expected exit 2 for: $args (got $status)"; return 1; }
    [ -z "$output" ] || { echo "expected empty stdout for: $args"; return 1; }
  done
}

@test "--help prints the usage on stdout and exits 0" {
  run bash "$SCRIPT" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"--report"* ]]
}

@test "environment errors exit 3: absent projects directory for --list-transcripts, missing or unreadable --usage file" {
  run bash -c '"$@" 2>/dev/null' _ "$SCRIPT" --list-transcripts --projects-dir "$BATS_TEST_TMPDIR/nope" --project-dir "$PROJECT_DIR"
  [ "$status" -eq 3 ]
  [ -z "$output" ]
  run bash -c '"$@" 2>/dev/null' _ "$SCRIPT" --usage "$BATS_TEST_TMPDIR/missing.jsonl"
  [ "$status" -eq 3 ]
  [ -z "$output" ]
}

@test "a project with no transcripts: --report fails with exit 4 and no stdout instead of an empty report (E76_S02_T01)" {
  mkdir -p "$BATS_TEST_TMPDIR/empty"
  run bash -c '"$@" 2>/dev/null' _ "$SCRIPT" --report --projects-dir "$BATS_TEST_TMPDIR/empty" --project-dir "$PROJECT_DIR"
  [ "$status" -eq 4 ]
  [ -z "$output" ]
  # the diagnostic list mode still prints an empty array
  run bash -c '"$@" 2>/dev/null' _ "$SCRIPT" --list-transcripts --projects-dir "$BATS_TEST_TMPDIR/empty" --project-dir "$PROJECT_DIR"
  [ "$status" -eq 0 ]
  [ "$output" = "[]" ]
}
