#!/usr/bin/env bats
#
# E76_S01_T04: scripts/task-usage.sh stage 3 - per-task aggregation, overhead and unmapped buckets, filters and the
# machine-readable output (--report).
#
# All fixtures are synthetic and built under $BATS_TEST_TMPDIR; no real ~/.claude/projects data is read.
# E76 ships publicly (decided 2026-11-07), so this file ships and must not depend on anything private.

bats_require_minimum_version 1.5.0

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
SCRIPT="$REPO_ROOT/scripts/task-usage.sh"

PROJ="/fake/work/proj"
SLUG="-fake-work-proj"

setup() {
  PROJECTS="$BATS_TEST_TMPDIR/projects"
  mkdir -p "$PROJECTS/$SLUG"
}

# ln_usage <requestId> <input> <output> <cache_write> <cache_read>: one assistant line with usage
ln_usage() {
  jq -n -c --arg r "$1" --argjson i "$2" --argjson o "$3" --argjson cw "$4" --argjson cr "$5" \
    '{type:"assistant",requestId:$r,message:{role:"assistant",usage:{input_tokens:$i,output_tokens:$o,cache_creation_input_tokens:$cw,cache_read_input_tokens:$cr}}}'
}

# mk_sub <slug-dir> <session> <agent-id> <meta-json> <usage-line>...: a subagent transcript plus its meta
mk_sub() {
  local d="$PROJECTS/$1/$2/subagents" slug="$1" sid="$2" aid="$3" meta="$4"
  mkdir -p "$d"
  shift 4
  printf '%s\n' "$meta" > "$d/agent-$aid.meta.json"
  { jq -n -c '{type:"user",isSidechain:true,message:{role:"user",content:"hello"}}'
    local l; for l in "$@"; do printf '%s\n' "$l"; done; } > "$d/agent-$aid.jsonl"
}

# mk_session <session> <usage-line>...: a main-session transcript
mk_session() {
  local sid="$1"
  shift
  { jq -n -c '{type:"user",message:{role:"user",content:"hello"}}'
    local l; for l in "$@"; do printf '%s\n' "$l"; done; } > "$PROJECTS/$SLUG/$sid.jsonl"
}

report() { bash "$SCRIPT" --report --projects-dir "$PROJECTS" --project-dir "$PROJ" "$@"; }

# task <id> <jq-field>: a field of one task record in $output
task() { printf '%s' "$output" | jq -r --arg t "$1" ".tasks[\$t] | $2"; }

@test "two transcripts mapped to the same task are summed into one record with usage_transcripts 2" {
  mk_sub "$SLUG" s1 a1 '{"agentType":"developer","name":"E72_S01_T05"}' "$(ln_usage r1 1 10 100 1000)"
  mk_sub "$SLUG" s2 a2 '{"agentType":"developer","name":"E72_S01_T05"}' "$(ln_usage r2 2 20 200 2000)"
  run report
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq '.tasks | length')" = "1" ]
  [ "$(task E72_S01_T05 .input)" = "3" ]
  [ "$(task E72_S01_T05 .output)" = "30" ]
  [ "$(task E72_S01_T05 .cache_write)" = "300" ]
  [ "$(task E72_S01_T05 .cache_read)" = "3000" ]
  [ "$(task E72_S01_T05 .usage_transcripts)" = "2" ]
  [ "$(task E72_S01_T05 .story_id)" = "E72_S01" ]
  [ "$(task E72_S01_T05 .epic_id)" = "E72" ]
}

@test "a -tester transcript is summed into its task along with the developer's" {
  mk_sub "$SLUG" s1 a1 '{"agentType":"developer","name":"E72_S05_T02"}' "$(ln_usage r1 1 10 100 1000)"
  mk_sub "$SLUG" s1 a2 '{"agentType":"tester","name":"E72_S05_T02-tester"}' "$(ln_usage r2 4 40 400 4000)"
  run report
  [ "$status" -eq 0 ]
  [ "$(task E72_S05_T02 .output)" = "50" ]
  [ "$(task E72_S05_T02 .usage_transcripts)" = "2" ]
}

@test "within a transcript only the last line per requestId counts" {
  mk_sub "$SLUG" s1 a1 '{"agentType":"developer","name":"E72_S01_T01"}' \
    "$(ln_usage rA 1 10 0 0)" "$(ln_usage rB 2 5 0 0)" "$(ln_usage rA 1 50 0 0)" "$(ln_usage rA 1 200 0 0)"
  run report
  [ "$status" -eq 0 ]
  [ "$(task E72_S01_T01 .output)" = "205" ]
  [ "$(task E72_S01_T01 .input)" = "3" ]
}

@test "usage_total_tokens equals the sum of the four fields for every task" {
  mk_sub "$SLUG" s1 a1 '{"agentType":"developer","name":"E72_S01_T01"}' "$(ln_usage r1 1 10 100 1000)"
  mk_sub "$SLUG" s1 a2 '{"agentType":"developer","name":"E72_S01_T02"}' "$(ln_usage r2 7 8 9 10)"
  mk_sub "$SLUG" s2 a3 '{"agentType":"tester","name":"E72_S01_T02-tester"}' "$(ln_usage r3 1 1 1 1)"
  run report
  [ "$status" -eq 0 ]
  [ "$(task E72_S01_T01 .usage_total_tokens)" = "1111" ]
  [ "$(task E72_S01_T02 .usage_total_tokens)" = "38" ]
  run jq -e '[.tasks[] | (.input + .output + .cache_write + .cache_read) == .usage_total_tokens] | all' <<<"$(report)"
  [ "$status" -eq 0 ]
}

@test "transcripts with no task ID appear only in overhead or unmapped, never in tasks, and are not allocated" {
  mk_sub "$SLUG" s1 a1 '{"agentType":"developer","name":"E72_S01_T05"}' "$(ln_usage r1 1 1 1 1)"
  mk_sub "$SLUG" s1 a2 '{"agentType":"scrum-master","name":"E72_S01"}' "$(ln_usage r2 10 20 30 40)"
  mk_sub "$SLUG" s1 a3 '{"agentType":"developer","name":"verify-group5","description":"no id here"}' "$(ln_usage r3 5 5 5 5)"
  mk_session s1 "$(ln_usage r4 100 200 300 400)"
  run report
  [ "$status" -eq 0 ]
  # tasks holds exactly the one task, and its numbers are untouched by the story-level and session overhead
  [ "$(printf '%s' "$output" | jq -c '.tasks | keys')" = '["E72_S01_T05"]' ]
  [ "$(task E72_S01_T05 .usage_total_tokens)" = "4" ]
  [ "$(printf '%s' "$output" | jq '.overhead | length')" = "2" ]
  [ "$(printf '%s' "$output" | jq '.unmapped | length')" = "1" ]
  # the story-level subagent: kind, agent_type, resolved id and level, the four sums, the path
  run jq -c '.overhead[] | select(.kind == "subagent") | {kind, agent_type, id, level, input, output, cache_write, cache_read}' <<<"$(report)"
  [ "$output" = '{"kind":"subagent","agent_type":"scrum-master","id":"E72_S01","level":"story","input":10,"output":20,"cache_write":30,"cache_read":40}' ]
  # the session transcript: kind session, no id
  run jq -c '.overhead[] | select(.kind == "session") | {agent_type, id, level, output}' <<<"$(report)"
  [ "$output" = '{"agent_type":null,"id":null,"level":"none","output":200}' ]
  # the unmapped subagent carries the mapper's reason and its own sums, and is in no other list
  run jq -r '.unmapped[0] | "\(.name)|\(.output)|\(.reason | length > 0)"' <<<"$(report)"
  [ "$output" = "verify-group5|5|true" ]
  run jq -e '[.overhead[].path, .unmapped[].path] | unique | length == 3' <<<"$(report)"
  [ "$status" -eq 0 ]
}

@test "an epic-level subagent is overhead with level epic" {
  mk_sub "$SLUG" s1 a1 '{"agentType":"scrum-master","name":"plan-E72"}' "$(ln_usage r1 1 2 3 4)"
  run report
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r '.overhead[0] | "\(.id)|\(.level)"')" = "E72|epic" ]
  [ "$(printf '%s' "$output" | jq '.tasks | length')" = "0" ]
}

@test "a transcript under a ...--claude-worktrees-... sibling slug is included in its task's total" {
  mk_sub "$SLUG" s1 a1 '{"agentType":"developer","name":"E73_S01_T02"}' "$(ln_usage r1 1 10 0 0)"
  mk_sub "$SLUG--claude-worktrees-bundle-E73-S01" s9 a2 '{"agentType":"developer","name":"E73_S01_T02"}' "$(ln_usage r2 2 20 0 0)"
  run report
  [ "$status" -eq 0 ]
  [ "$(task E73_S01_T02 .output)" = "30" ]
  [ "$(task E73_S01_T02 .usage_transcripts)" = "2" ]
}

@test "--task keeps only that task" {
  mk_sub "$SLUG" s1 a1 '{"agentType":"developer","name":"E72_S01_T01"}' "$(ln_usage r1 1 1 1 1)"
  mk_sub "$SLUG" s1 a2 '{"agentType":"developer","name":"E72_S01_T02"}' "$(ln_usage r2 2 2 2 2)"
  run report --task E72_S01_T02
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -c '.tasks | keys')" = '["E72_S01_T02"]' ]
  [ "$(printf '%s' "$output" | jq -c '.warnings')" = '[]' ]
}

@test "--story keeps only the tasks of that story" {
  mk_sub "$SLUG" s1 a1 '{"agentType":"developer","name":"E72_S01_T01"}' "$(ln_usage r1 1 1 1 1)"
  mk_sub "$SLUG" s1 a2 '{"agentType":"developer","name":"E72_S01_T02"}' "$(ln_usage r2 2 2 2 2)"
  mk_sub "$SLUG" s1 a3 '{"agentType":"developer","name":"E72_S02_T01"}' "$(ln_usage r3 3 3 3 3)"
  run report --story E72_S01
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -c '.tasks | keys')" = '["E72_S01_T01","E72_S01_T02"]' ]
}

@test "an ID with no transcripts is a warning, never a record of zeros, and the note goes to stderr" {
  mk_sub "$SLUG" s1 a1 '{"agentType":"developer","name":"E72_S01_T01"}' "$(ln_usage r1 1 1 1 1)"
  # Within one option the IDs are OR-ed; across --task and --story a task must satisfy both (documented in the
  # script header and task-usage.md), so the unknown task and the unknown story are checked in separate runs.
  run --separate-stderr report --task E72_S01_T09 --task E72_S01_T01
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -c '.tasks | keys')" = '["E72_S01_T01"]' ]
  [ "$(printf '%s' "$output" | jq -r '[.warnings[] | "\(.code):\(.id)"] | join(",")')" = "no-transcripts-for-task:E72_S01_T09" ]
  [ "$(printf '%s' "$output" | jq '.tasks | has("E72_S01_T09")')" = "false" ]
  [[ "$stderr" == *"E72_S01_T09"* ]]
  # when every requested ID is absent (here the only one) nothing is reported at all: exit 8, no stdout (E76_S02_T01)
  run --separate-stderr report --story E72_S07
  [ "$status" -eq 8 ]
  [ -z "$output" ]
  [[ "$stderr" == *"E72_S07"* ]]
}

@test "filters leave overhead and unmapped complete" {
  mk_sub "$SLUG" s1 a1 '{"agentType":"developer","name":"E72_S01_T01"}' "$(ln_usage r1 1 1 1 1)"
  mk_sub "$SLUG" s1 a2 '{"agentType":"scrum-master","name":"E72_S01"}' "$(ln_usage r2 1 1 1 1)"
  mk_sub "$SLUG" s1 a3 '{"agentType":"x","name":"verify-group5"}' "$(ln_usage r3 1 1 1 1)"
  run report --task E72_S01_T01
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq '.overhead | length')" = "1" ]
  [ "$(printf '%s' "$output" | jq '.unmapped | length')" = "1" ]
}

@test "stdout is valid JSON with the documented keys, schema_version 1, and no price or cost field" {
  mk_sub "$SLUG" s1 a1 '{"agentType":"developer","name":"E72_S01_T01"}' "$(ln_usage r1 1 2 3 4)"
  mk_session s1 "$(ln_usage r2 1 1 1 1)"
  run --separate-stderr report
  [ "$status" -eq 0 ]
  printf '%s' "$output" | jq . >/dev/null
  [ "$(printf '%s' "$output" | jq -c 'keys')" = '["generated_at","overhead","schema_version","tasks","unmapped","warnings"]' ]
  [ "$(printf '%s' "$output" | jq '.schema_version')" = "1" ]
  printf '%s' "$output" | jq -e '.generated_at | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$")' >/dev/null
  # no key anywhere in the document is price-like, and no dollar sign appears in the output
  [ "$(printf '%s' "$output" | jq '[.. | objects | keys[] | select(test("price|cost|usd|dollar|eur|currency"; "i"))] | length')" = "0" ]
  [[ "$output" != *'$'* ]]
}

@test "a slug directory with no subagent transcripts is exit 5 with nothing on stdout, not an empty report (E76_S02_T01)" {
  run --separate-stderr report
  [ "$status" -eq 5 ]
  [ -z "$output" ]
  [[ "$stderr" == *"$SLUG"* ]]
}

@test "--task or --story with a malformed ID exits 2 with nothing on stdout" {
  run --separate-stderr report --task E72_S01
  [ "$status" -eq 2 ]
  [ -z "$output" ]
  run --separate-stderr report --story E72_S01_T01
  [ "$status" -eq 2 ]
  [ -z "$output" ]
  run --separate-stderr report --task
  [ "$status" -eq 2 ]
}

@test "--task and --story are rejected outside --report, and modes cannot be combined" {
  run --separate-stderr bash "$SCRIPT" --list-transcripts --task E72_S01_T01 --projects-dir "$PROJECTS" --project-dir "$PROJ"
  [ "$status" -eq 2 ]
  [ -z "$output" ]
  run --separate-stderr bash "$SCRIPT" --report --usage /dev/null
  [ "$status" -eq 2 ]
  [ -z "$output" ]
}
