#!/usr/bin/env bats
#
# E76_S01_T02: scripts/task-usage.sh stage 1 - transcript discovery and task mapping (--list-transcripts).
#
# All fixtures are synthetic and built under $BATS_TEST_TMPDIR; no real ~/.claude/projects data is read.
# E76 ships publicly (decided 2026-11-07), so this file ships and must not depend on anything private.

bats_require_minimum_version 1.5.0

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
SCRIPT="$REPO_ROOT/scripts/task-usage.sh"

# The fixture project path and its Claude Code slug ("/" "." "_" and " " all become "-").
PROJ="/fake/work/My.Proj_x"
SLUG="-fake-work-My-Proj-x"

setup() {
  PROJECTS="$BATS_TEST_TMPDIR/projects"
  mkdir -p "$PROJECTS/$SLUG"
}

# mk_sub <slug-dir> <session> <agent-id> <meta-json-or-"-"> <first-user-prompt-text>
mk_sub() {
  local d="$PROJECTS/$1/$2/subagents"
  mkdir -p "$d"
  [ "$4" = "-" ] || printf '%s\n' "$4" > "$d/agent-$3.meta.json"
  jq -n -c --arg t "$5" '{type:"user",isSidechain:true,cwd:"/fake/work/My.Proj_x",message:{role:"user",content:$t}}' > "$d/agent-$3.jsonl"
  jq -n -c '{type:"assistant",message:{role:"assistant",usage:{input_tokens:1,output_tokens:2}}}' >> "$d/agent-$3.jsonl"
}

list() { bash "$SCRIPT" --list-transcripts --projects-dir "$PROJECTS" --project-dir "$PROJ" "$@"; }

# rec <agent-id> <jq-field-expression>: the field of the subagent record with that agent id
rec() { printf '%s' "$output" | jq -r --arg a "$1" ".[] | select(.agent_id == \$a) | $2"; }

@test "a meta name that is an exact task ID resolves to that task" {
  mk_sub "$SLUG" s1 a1 '{"agentType":"developer","name":"E72_S01_T05","description":"x"}' "hello"
  run list
  [ "$status" -eq 0 ]
  [ "$(rec a1 .id)" = "E72_S01_T05" ]
  [ "$(rec a1 .level)" = "task" ]
  [ "$(rec a1 .source)" = "name" ]
  [ "$(rec a1 .agent_type)" = "developer" ]
}

@test "a trailing role suffix on the name still maps to the task" {
  mk_sub "$SLUG" s1 a1 '{"agentType":"tester","name":"E72_S05_T02-tester"}' "hello"
  mk_sub "$SLUG" s1 a2 '{"agentType":"tester","name":"E85_S01_T06-tester-r2"}' "hello"
  mk_sub "$SLUG" s1 a3 '{"agentType":"tester","name":"retest-E85_S01_T06"}' "hello"
  run list
  [ "$(rec a1 .id)" = "E72_S05_T02" ]
  [ "$(rec a2 .id)" = "E85_S01_T06" ]
  [ "$(rec a3 .id)" = "E85_S01_T06" ]
}

@test "a name with no ID falls through to the description" {
  mk_sub "$SLUG" s1 a1 '{"agentType":"developer","name":"verify-group5","description":"Implement E72_S03_T01 now"}' "hello"
  run list
  [ "$(rec a1 .id)" = "E72_S03_T01" ]
  [ "$(rec a1 .source)" = "description" ]
}

@test "with no name or description ID the first prompt line decides, and only its first line" {
  mk_sub "$SLUG" s1 a1 '{"agentType":"developer","description":"do the work"}' "$(printf 'Work on E10_S02_T03 please\nsee also E99_S99_T99')"
  mk_sub "$SLUG" s1 a2 '{"agentType":"developer","description":"do the work"}' "$(printf 'You are a developer\nWork on E10_S02_T04')"
  run list
  [ "$(rec a1 .id)" = "E10_S02_T03" ]
  [ "$(rec a1 .source)" = "prompt" ]
  [ "$(rec a2 .id)" = "null" ]
  [ "$(rec a2 .level)" = "none" ]
}

@test "a transcript with no resolvable ID is unmapped with a reason and no ID" {
  mk_sub "$SLUG" s1 a1 '{"agentType":"scrum-master","name":"verify-group5","description":"no ids here"}' "nothing to see"
  run list
  [ "$(rec a1 .id)" = "null" ]
  [ "$(rec a1 .level)" = "none" ]
  [ "$(rec a1 .source)" = "null" ]
  [ -n "$(rec a1 .reason)" ]
  [ "$(rec a1 .reason)" != "null" ]
}

@test "the most specific ID in the deciding source wins" {
  mk_sub "$SLUG" s1 a1 '{"agentType":"developer","name":"rollup-E72-then-E72_S01-and-E72_S01_T05"}' "x"
  mk_sub "$SLUG" s1 a2 '{"agentType":"developer","name":"E72-and-E72_S01"}' "x"
  run list
  [ "$(rec a1 .id)" = "E72_S01_T05" ]
  [ "$(rec a1 .level)" = "task" ]
  [ "$(rec a2 .id)" = "E72_S01" ]
  [ "$(rec a2 .level)" = "story" ]
  [ "$(rec a1 '.candidates | length')" = "3" ]
}

@test "an ID must stand alone: embedded in a longer token it is not an ID" {
  mk_sub "$SLUG" s1 a1 '{"agentType":"developer","name":"TYPE12","description":"E72_S05_T02x"}' "x"
  run list
  [ "$(rec a1 .id)" = "null" ]
}

@test "a missing meta file falls back to the prompt and records why when that fails" {
  mk_sub "$SLUG" s1 a1 - "Implement E33_S01_T02"
  mk_sub "$SLUG" s1 a2 - "nothing"
  run list
  [ "$(rec a1 .id)" = "E33_S01_T02" ]
  [ "$(rec a1 .source)" = "prompt" ]
  [ "$(rec a2 .id)" = "null" ]
  [[ "$(rec a2 .reason)" == *"no meta.json"* ]]
}

@test "the transcript cwd is never used for mapping" {
  local d="$PROJECTS/$SLUG/s1/subagents"
  mkdir -p "$d"
  printf '%s\n' '{"agentType":"developer","name":"verify"}' > "$d/agent-a1.meta.json"
  jq -n -c '{type:"user",cwd:"/x/E99_S99_T99",message:{role:"user",content:"hello"}}' > "$d/agent-a1.jsonl"
  run list
  [ "$(rec a1 .id)" = "null" ]
}

@test "sibling ...--claude-worktrees-... slug dirs are discovered and mapped the same way" {
  mk_sub "$SLUG" s1 a1 '{"agentType":"developer","name":"E01_S01_T01"}' "x"
  mk_sub "$SLUG--claude-worktrees-bundle-E73-S01" s2 a2 '{"agentType":"developer","name":"E73_S01_T04"}' "x"
  mk_sub "$SLUG--claude-worktrees-other" s3 a3 '{"agentType":"tester","name":"E73_S01_T04-tester"}' "x"
  run list
  [ "$(rec a2 .id)" = "E73_S01_T04" ]
  [ "$(rec a2 .slug_dir)" = "$SLUG--claude-worktrees-bundle-E73-S01" ]
  [ "$(rec a3 .id)" = "E73_S01_T04" ]
  [ "$(printf '%s' "$output" | jq 'length')" = "3" ]
}

@test "a slug dir that only shares a prefix is not a sibling" {
  mk_sub "$SLUG" s1 a1 '{"agentType":"developer","name":"E01_S01_T01"}' "x"
  mk_sub "$SLUG-public" s2 a2 '{"agentType":"developer","name":"E02_S01_T01"}' "x"
  mk_sub "$SLUG-claude-worktrees-x" s3 a3 '{"agentType":"developer","name":"E03_S01_T01"}' "x"
  run list
  [ "$(printf '%s' "$output" | jq 'length')" = "1" ]
  [ "$(rec a1 .id)" = "E01_S01_T01" ]
}

@test "the main session transcript is listed as session-level and not mapped" {
  mk_sub "$SLUG" s1 a1 '{"agentType":"developer","name":"E01_S01_T01"}' "x"
  jq -n -c '{type:"user",message:{role:"user",content:"Work on E01_S01_T01"}}' > "$PROJECTS/$SLUG/s1.jsonl"
  run list
  [ "$(printf '%s' "$output" | jq -r '.[] | select(.kind == "session") | .session_id')" = "s1" ]
  [ "$(printf '%s' "$output" | jq -r '.[] | select(.kind == "session") | .id')" = "null" ]
  [ "$(printf '%s' "$output" | jq -r '.[] | select(.kind == "session") | .level')" = "none" ]
}

@test "every record carries the documented keys" {
  mk_sub "$SLUG" s1 a1 '{"agentType":"developer","name":"E01_S01_T01"}' "x"
  jq -n -c '{type:"user",message:{role:"user",content:"x"}}' > "$PROJECTS/$SLUG/s1.jsonl"
  run list
  [ "$(printf '%s' "$output" | jq -r 'map(keys | join(",")) | unique | .[]')" = "agent_id,agent_type,candidates,id,kind,level,name,path,reason,session_id,slug_dir,source" ]
}

@test "--projects-dir overrides JENGA_PROJECTS_DIR, which is used when the option is absent" {
  mk_sub "$SLUG" s1 a1 '{"agentType":"developer","name":"E01_S01_T01"}' "x"
  mkdir -p "$BATS_TEST_TMPDIR/empty"
  JENGA_PROJECTS_DIR="$BATS_TEST_TMPDIR/empty" run list
  [ "$(printf '%s' "$output" | jq 'length')" = "1" ]
  JENGA_PROJECTS_DIR="$PROJECTS" run --separate-stderr bash "$SCRIPT" --list-transcripts --project-dir "$PROJ" --projects-dir="$BATS_TEST_TMPDIR/empty"
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq 'length')" = "0" ]
  JENGA_PROJECTS_DIR="$PROJECTS" run bash "$SCRIPT" --list-transcripts --project-dir "$PROJ"
  [ "$(printf '%s' "$output" | jq 'length')" = "1" ]
}

@test "bad arguments print usage on stderr and exit non-zero with nothing on stdout" {
  run --separate-stderr bash "$SCRIPT" --bogus
  [ "$status" -eq 2 ]
  [ -z "$output" ]
  [[ "$stderr" == *"unknown option"* && "$stderr" == *"usage:"* ]]
  run --separate-stderr bash "$SCRIPT"
  [ "$status" -eq 2 ]
  [ -z "$output" ]
  run --separate-stderr bash "$SCRIPT" --list-transcripts --projects-dir
  [ "$status" -eq 2 ]
  run --separate-stderr bash "$SCRIPT" --list-transcripts stray
  [ "$status" -eq 2 ]
}

@test "a missing projects directory is an environment error, not usage" {
  run --separate-stderr bash "$SCRIPT" --list-transcripts --projects-dir "$BATS_TEST_TMPDIR/nope"
  [ "$status" -eq 3 ]
  [[ "$stderr" == *"projects directory not found"* ]]
}

@test "--help prints usage on stdout and exits 0" {
  run bash "$SCRIPT" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"usage:"* ]]
}
