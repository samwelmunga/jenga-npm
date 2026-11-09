#!/usr/bin/env bats
#
# E76_S02_T01: scripts/task-usage.sh drift protection - --report and --check-layout fail loudly, each failure
# mode with its own exit code (4 transcript root/slug, 5 no subagent transcripts, 6 sidecar meta, 7 usage fields,
# 8 every requested ID absent), a message on stderr naming the missing thing and the searched path, and nothing
# on stdout. Also: zero versus absent, a genuine-zero transcript, and --check-layout.
#
# All fixtures are synthetic and built under $BATS_TEST_TMPDIR (plus the checked-in trees under
# tests/fixtures/task-usage/); no real ~/.claude/projects data is read.
# E76 ships publicly (decided 2026-11-07), so this file ships and must not depend on anything private.

bats_require_minimum_version 1.5.0

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
SCRIPT="$REPO_ROOT/scripts/task-usage.sh"
FIX="$REPO_ROOT/tests/fixtures/task-usage"

PROJ="/fake/work/proj"
SLUG="-fake-work-proj"

setup() {
  unset JENGA_PROJECTS_DIR
  PROJECTS="$BATS_TEST_TMPDIR/projects"
  mkdir -p "$PROJECTS/$SLUG"
}

# ln_usage <requestId> <input> <output> <cache_write> <cache_read>: one assistant line with a complete usage object
ln_usage() {
  jq -n -c --arg r "$1" --argjson i "$2" --argjson o "$3" --argjson cw "$4" --argjson cr "$5" \
    '{type:"assistant",requestId:$r,message:{role:"assistant",usage:{input_tokens:$i,output_tokens:$o,cache_creation_input_tokens:$cw,cache_read_input_tokens:$cr}}}'
}

# ln_nousage <requestId>: an assistant line with no usage object
ln_nousage() {
  jq -n -c --arg r "$1" '{type:"assistant",requestId:$r,message:{role:"assistant",content:[{type:"text",text:"hi"}]}}'
}

# mk_sub <slug-dir> <session> <agent-id> <meta-json or "-" for no sidecar> <transcript-line>...
mk_sub() {
  local d="$PROJECTS/$1/$2/subagents" aid="$3" meta="$4"
  mkdir -p "$d"
  shift 4
  [ "$meta" = "-" ] || printf '%s\n' "$meta" > "$d/agent-$aid.meta.json"
  { jq -n -c '{type:"user",isSidechain:true,message:{role:"user",content:"hello"}}'
    local l; for l in "$@"; do printf '%s\n' "$l"; done; } > "$d/agent-$aid.jsonl"
}

GOOD_META='{"agentType":"developer","name":"E72_S01_T05","description":"x"}'

# mk_good: one healthy task-mapped subagent transcript
mk_good() { mk_sub "$SLUG" s1 a1 "$GOOD_META" "$(ln_usage r1 1 10 100 1000)"; }

report()      { bash "$SCRIPT" --report --projects-dir "$PROJECTS" --project-dir "$PROJ" "$@"; }
checklayout() { bash "$SCRIPT" --check-layout --projects-dir "$PROJECTS" --project-dir "$PROJ" "$@"; }

# run_failing <exit code> <mode args...>: the run exits with that code, stdout is empty, and stderr is in $stderr
expect_loud_failure() {
  local want="$1"
  shift
  run --separate-stderr "$@"
  [ "$status" -eq "$want" ] || { echo "expected exit $want, got $status; stderr: $stderr"; return 1; }
  [ -z "$output" ] || { echo "expected empty stdout, got: $output"; return 1; }
}

# ---------------------------------------------------------------------------------------------------------------
# check 1 - exit 4
# ---------------------------------------------------------------------------------------------------------------

@test "check 1: a missing transcript root exits 4 with no stdout and a message naming the root" {
  expect_loud_failure 4 bash "$SCRIPT" --report --projects-dir "$BATS_TEST_TMPDIR/nope" --project-dir "$PROJ"
  [[ "$stderr" == *"transcript root not found"* ]]
  [[ "$stderr" == *"$BATS_TEST_TMPDIR/nope"* ]]
}

@test "check 1: a root with no directory for this project's slug exits 4 and names the slug and the searched path" {
  rm -rf "$PROJECTS/$SLUG"
  mkdir -p "$PROJECTS/-some-other-project"
  expect_loud_failure 4 report
  [[ "$stderr" == *"no directory for project slug $SLUG"* ]]
  [[ "$stderr" == *"$PROJECTS"* ]]
}

@test "check 1: a sibling that merely shares the slug prefix does not count as the project's directory" {
  rm -rf "$PROJECTS/$SLUG"
  mk_sub "$SLUG-public" s1 a1 "$GOOD_META" "$(ln_usage r1 1 10 100 1000)"
  expect_loud_failure 4 report
}

# ---------------------------------------------------------------------------------------------------------------
# check 2 - exit 5
# ---------------------------------------------------------------------------------------------------------------

@test "check 2: a slug directory with no subagents/ directory exits 5 and says so" {
  jq -n -c '{type:"user"}' > "$PROJECTS/$SLUG/sess.jsonl"
  expect_loud_failure 5 report
  [[ "$stderr" == *"no subagents/ directory"* ]]
  [[ "$stderr" == *"$PROJECTS/$SLUG"* ]]
}

@test "check 2: a subagents/ directory with no agent-*.jsonl exits 5 and says so" {
  mkdir -p "$PROJECTS/$SLUG/s1/subagents"
  printf '%s\n' "$GOOD_META" > "$PROJECTS/$SLUG/s1/subagents/agent-a1.meta.json"
  expect_loud_failure 5 report
  [[ "$stderr" == *"no agent-*.jsonl"* ]]
  [[ "$stderr" == *"$PROJECTS/$SLUG"* ]]
}

# ---------------------------------------------------------------------------------------------------------------
# check 3 - exit 6
# ---------------------------------------------------------------------------------------------------------------

@test "check 3: a transcript without a sibling .meta.json exits 6 and names the expected meta path" {
  mk_sub "$SLUG" s1 a1 - "$(ln_usage r1 1 10 100 1000)"
  expect_loud_failure 6 report
  [[ "$stderr" == *"$PROJECTS/$SLUG/s1/subagents/agent-a1.meta.json"* ]]
  [[ "$stderr" == *"no sibling .meta.json"* ]]
}

@test "check 3: an unparseable .meta.json exits 6" {
  mk_sub "$SLUG" s1 a1 'this is { not json' "$(ln_usage r1 1 10 100 1000)"
  expect_loud_failure 6 report
  [[ "$stderr" == *"agent-a1.meta.json"* ]]
  [[ "$stderr" == *"not parseable"* ]]
}

@test "check 3: a .meta.json that is valid JSON but not an object exits 6" {
  mk_sub "$SLUG" s1 a1 '["agentType","name"]' "$(ln_usage r1 1 10 100 1000)"
  expect_loud_failure 6 report
}

@test "check 3: a meta lacking agentType, or lacking both name and description, exits 6 and names the field" {
  mk_sub "$SLUG" s1 a1 '{"name":"E72_S01_T05","description":"x"}' "$(ln_usage r1 1 10 100 1000)"
  expect_loud_failure 6 report
  [[ "$stderr" == *"lacks the field(s) the mapper reads: agentType"* ]]
  rm -rf "$PROJECTS/$SLUG/s1"
  mk_sub "$SLUG" s1 a1 '{"agentType":"developer","toolUseId":"t"}' "$(ln_usage r1 1 10 100 1000)"
  expect_loud_failure 6 report
  [[ "$stderr" == *"name or description"* ]]
}

@test "check 3: a meta with a description but no name is fine (name is optional in real sidecars)" {
  mk_sub "$SLUG" s1 a1 '{"agentType":"developer","description":"Implement E72_S01_T05 now"}' "$(ln_usage r1 1 10 100 1000)"
  run --separate-stderr report
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -c '.tasks | keys')" = '["E72_S01_T05"]' ]
}

@test "check 3: one bad sidecar among healthy ones still fails the run, and every bad one is listed" {
  mk_good
  mk_sub "$SLUG" s1 a2 - "$(ln_usage r2 1 1 1 1)"
  mk_sub "$SLUG" s1 a3 'broken' "$(ln_usage r3 1 1 1 1)"
  expect_loud_failure 6 report
  [[ "$stderr" == *"2 of 3 subagent transcript(s)"* ]]
  [[ "$stderr" == *"agent-a2.meta.json"* ]]
  [[ "$stderr" == *"agent-a3.meta.json"* ]]
}

# ---------------------------------------------------------------------------------------------------------------
# check 4 - exit 7
# ---------------------------------------------------------------------------------------------------------------

@test "check 4: a task-mapped transcript with assistant lines but no usage object exits 7 and names the transcript" {
  mk_sub "$SLUG" s1 a1 "$GOOD_META" "$(ln_nousage r1)" "$(ln_nousage r2)"
  expect_loud_failure 7 report
  [[ "$stderr" == *"$PROJECTS/$SLUG/s1/subagents/agent-a1.jsonl"* ]]
  [[ "$stderr" == *"none carries a message.usage object"* ]]
}

@test "check 4: a usage object lacking one of the four sum fields exits 7 and names the field" {
  local f field
  for field in input_tokens output_tokens cache_creation_input_tokens cache_read_input_tokens; do
    rm -rf "$PROJECTS/$SLUG/s1"
    mk_sub "$SLUG" s1 a1 "$GOOD_META" "$(ln_usage r1 1 10 100 1000 | jq -c --arg f "$field" 'del(.message.usage[$f])')"
    expect_loud_failure 7 report
    [[ "$stderr" == *"lack numeric field(s): $field"* ]] || { echo "missing field $field not named: $stderr"; return 1; }
  done
}

@test "check 4: a usage field that is present but not a number counts as missing" {
  mk_sub "$SLUG" s1 a1 "$GOOD_META" "$(ln_usage r1 1 10 100 1000 | jq -c '.message.usage.output_tokens = "ten"')"
  expect_loud_failure 7 report
  [[ "$stderr" == *"output_tokens"* ]]
}

@test "check 4 applies to task-mapped transcripts only: an unmapped transcript without usage does not fail the run" {
  mk_good
  mk_sub "$SLUG" s1 a2 '{"agentType":"x","name":"verify-group5"}' "$(ln_nousage r9)"
  run --separate-stderr report
  [ "$status" -eq 0 ]
}

@test "check 4: a final line cut off mid-write is skipped, not treated as a missing field" {
  mk_sub "$SLUG" s1 a1 "$GOOD_META" "$(ln_usage r1 1 10 100 1000)" '{"type":"assistant","requestId":"r2","message":{"usage":{"input_tokens":1,"outpu'
  run --separate-stderr report
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq '.tasks.E72_S01_T05.usage_total_tokens')" = "1111" ]
}

# ---------------------------------------------------------------------------------------------------------------
# zero versus absent
# ---------------------------------------------------------------------------------------------------------------

@test "a transcript that truly reports zero usage on every call is reported with zeros and is not an error" {
  mk_sub "$SLUG" s1 a1 "$GOOD_META" "$(ln_usage r1 0 0 0 0)" "$(ln_usage r2 0 0 0 0)"
  run --separate-stderr report
  [ "$status" -eq 0 ]
  printf '%s' "$output" | jq -e '.tasks.E72_S01_T05 | .input == 0 and .output == 0 and .cache_write == 0 and .cache_read == 0
    and .usage_total_tokens == 0 and .usage_transcripts == 1' >/dev/null
  [ "$(printf '%s' "$output" | jq -c '.warnings')" = '[]' ]
  run --separate-stderr checklayout
  [ "$status" -eq 0 ]
}

@test "--task for an ID with no transcripts exits 8 with a message and nothing on stdout" {
  mk_good
  expect_loud_failure 8 report --task E72_S01_T09
  [[ "$stderr" == *"E72_S01_T09"* ]]
  [[ "$stderr" == *"no transcripts found"* ]]
  [[ "$stderr" == *"$PROJECTS/$SLUG"* ]]
}

@test "--story for an ID with no transcripts exits 8 with a message and nothing on stdout" {
  mk_good
  expect_loud_failure 8 report --story E72_S07
  [[ "$stderr" == *"E72_S07"* ]]
}

@test "every requested ID absent exits 8, even with several IDs" {
  mk_good
  expect_loud_failure 8 report --task E72_S01_T08 --task E72_S01_T09
}

@test "in a bulk run an absent ID is a warning, absent from tasks, and the present IDs are still reported" {
  mk_good
  run --separate-stderr report --task E72_S01_T09 --task E72_S01_T05
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -c '.tasks | keys')" = '["E72_S01_T05"]' ]
  [ "$(printf '%s' "$output" | jq '.tasks | has("E72_S01_T09")')" = "false" ]
  [ "$(printf '%s' "$output" | jq -r '[.warnings[] | "\(.code):\(.id)"] | join(",")')" = "no-transcripts-for-task:E72_S01_T09" ]
  [[ "$stderr" == *"E72_S01_T09"* ]]
}

@test "a task-mapped transcript with no assistant line at all is excluded with a warning, never printed as zeros" {
  mk_good
  mk_sub "$SLUG" s1 a2 '{"agentType":"developer","name":"E72_S01_T06"}'
  run --separate-stderr report
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -c '.tasks | keys')" = '["E72_S01_T05"]' ]
  [ "$(printf '%s' "$output" | jq -r '[.warnings[] | .code] | join(",")')" = "transcript-without-usage" ]
  # and asking for exactly that task is the absent case, not a record of zeros
  expect_loud_failure 8 report --task E72_S01_T06
}

# ---------------------------------------------------------------------------------------------------------------
# no half-written output, distinct codes
# ---------------------------------------------------------------------------------------------------------------

@test "a failing report writes nothing to stdout, whichever check fails, and leaves no temporary files" {
  export TMPDIR="$BATS_TEST_TMPDIR/tmp"
  mkdir -p "$TMPDIR"
  # healthy transcripts first so a stream-as-you-go implementation would already have printed something
  mk_good
  mk_sub "$SLUG" s1 a2 - "$(ln_usage r2 1 1 1 1)"
  expect_loud_failure 6 report
  rm -rf "$PROJECTS/$SLUG/s1/subagents/agent-a2.jsonl"
  mk_sub "$SLUG" s1 a2 "$GOOD_META" "$(ln_nousage r2)"
  expect_loud_failure 7 report
  [ -z "$(ls -A "$TMPDIR")" ]
}

@test "the four layout failures have four distinct exit codes, none of them 0, 2 or 3" {
  local codes="" c
  expect_loud_failure 4 bash "$SCRIPT" --report --projects-dir "$BATS_TEST_TMPDIR/nope" --project-dir "$PROJ"
  codes="$codes $status"
  expect_loud_failure 5 report
  codes="$codes $status"
  mk_sub "$SLUG" s1 a1 - "$(ln_usage r1 1 1 1 1)"
  expect_loud_failure 6 report
  codes="$codes $status"
  rm -rf "$PROJECTS/$SLUG/s1"
  mk_sub "$SLUG" s1 a1 "$GOOD_META" "$(ln_nousage r1)"
  expect_loud_failure 7 report
  codes="$codes $status"
  [ "$(printf '%s\n' $codes | sort -u | wc -l | tr -d ' ')" = "4" ]
  for c in $codes; do [ "$c" -ne 0 ] && [ "$c" -ne 2 ] && [ "$c" -ne 3 ]; done
}

@test "the script header and the documentation list every exit code" {
  local c
  for c in 4 5 6 7 8; do
    grep -Eq "^#   $c  " "$SCRIPT" || { echo "header lacks exit code $c"; return 1; }
    grep -Eq "\\| *\`$c\` *\\|" "$REPO_ROOT/project/documentation/task-usage.md" || { echo "doc lacks exit code $c"; return 1; }
  done
}

# ---------------------------------------------------------------------------------------------------------------
# the checked-in negative fixtures (tests/fixtures/task-usage README case 8)
# ---------------------------------------------------------------------------------------------------------------

@test "fixture trees: the healthy tree passes, projects-no-meta is exit 6, projects-no-usage is exit 7" {
  run --separate-stderr bash "$SCRIPT" --check-layout --projects-dir "$FIX/projects" --project-dir /fixture/proj
  [ "$status" -eq 0 ]
  run --separate-stderr bash "$SCRIPT" --check-layout --projects-dir "$FIX/projects-no-meta" --project-dir /fixture/proj
  [ "$status" -eq 6 ]
  run --separate-stderr bash "$SCRIPT" --check-layout --projects-dir "$FIX/projects-no-usage" --project-dir /fixture/proj
  [ "$status" -eq 7 ]
  expect_loud_failure 6 bash "$SCRIPT" --report --projects-dir "$FIX/projects-no-meta" --project-dir /fixture/proj
  expect_loud_failure 7 bash "$SCRIPT" --report --projects-dir "$FIX/projects-no-usage" --project-dir /fixture/proj
}

# ---------------------------------------------------------------------------------------------------------------
# --check-layout
# ---------------------------------------------------------------------------------------------------------------

@test "--check-layout on a healthy tree exits 0, prints one JSON line on stdout and a verdict on stderr" {
  mk_good
  mk_sub "$SLUG" s1 a2 '{"agentType":"x","name":"verify-group5"}' "$(ln_usage r2 1 1 1 1)"
  run --separate-stderr checklayout
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | wc -l | tr -d ' ')" = "1" ]
  printf '%s' "$output" | jq -e '.schema_version == 1 and .ok == true and .exit_code == 0 and .transcripts == 2
    and ([.checks[].status] == ["ok","ok","ok","ok"]) and ([.checks[].check] == [1,2,3,4])' >/dev/null
  [[ "$stderr" == *"layout check passed"* ]]
}

@test "--check-layout does not aggregate: no tokens, tasks or sums anywhere in its verdict" {
  mk_good
  run --separate-stderr checklayout
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq 'has("tasks") or has("overhead") or has("unmapped")')" = "false" ]
  [ "$(printf '%s' "$output" | jq '[.. | objects | keys[] | select(test("^(input|output|cache_write|cache_read|usage_total_tokens)$"))] | length')" = "0" ]
}

@test "--check-layout returns the same exit code as --report for each failure and marks the failed check" {
  expect_loud_failure 5 report
  run --separate-stderr checklayout
  [ "$status" -eq 5 ]
  printf '%s' "$output" | jq -e '.ok == false and .exit_code == 5 and ([.checks[].status] == ["ok","fail","skipped","skipped"])' >/dev/null
  [[ "$stderr" == *"layout check FAILED (exit 5)"* ]]

  run --separate-stderr bash "$SCRIPT" --check-layout --projects-dir "$BATS_TEST_TMPDIR/nope" --project-dir "$PROJ"
  [ "$status" -eq 4 ]
  printf '%s' "$output" | jq -e '.exit_code == 4 and ([.checks[].status] == ["fail","skipped","skipped","skipped"])' >/dev/null
  [[ "$stderr" == *"$BATS_TEST_TMPDIR/nope"* ]]

  mk_sub "$SLUG" s1 a1 - "$(ln_usage r1 1 1 1 1)"
  run --separate-stderr checklayout
  [ "$status" -eq 6 ]
  printf '%s' "$output" | jq -e '.exit_code == 6 and .checks[2].status == "fail" and (.checks[2].details[0] | contains("agent-a1.meta.json"))' >/dev/null

  rm -rf "$PROJECTS/$SLUG/s1"
  mk_sub "$SLUG" s1 a1 "$GOOD_META" "$(ln_nousage r1)"
  run --separate-stderr checklayout
  [ "$status" -eq 7 ]
  printf '%s' "$output" | jq -e '.exit_code == 7 and .checks[3].status == "fail" and .checks[3].count == 1' >/dev/null
}

@test "--check-layout lists every failed check (3 and 4 together) and exits with the first one's code" {
  mk_sub "$SLUG" s1 a1 - "$(ln_usage r1 1 1 1 1)"
  mk_sub "$SLUG" s1 a2 '{"agentType":"developer","name":"E72_S01_T06"}' "$(ln_nousage r2)"
  run --separate-stderr checklayout
  [ "$status" -eq 6 ]
  printf '%s' "$output" | jq -e '([.checks[].status] == ["ok","ok","fail","fail"]) and .exit_code == 6' >/dev/null
  [[ "$stderr" == *"layout check 3 failed"* ]]
  [[ "$stderr" == *"layout check 4 failed"* ]]
}

@test "--check-layout prints on stdout only after the checks, and only its JSON verdict, on failure too" {
  mk_good
  mk_sub "$SLUG" s1 a2 - "$(ln_usage r2 1 1 1 1)"
  run --separate-stderr checklayout
  [ "$status" -eq 6 ]
  printf '%s' "$output" | jq -e 'type == "object"' >/dev/null
  [ "$(printf '%s\n' "$output" | wc -l | tr -d ' ')" = "1" ]
}

@test "--check-layout takes no --task or --story, and cannot be combined with another mode" {
  expect_loud_failure 2 checklayout --task E72_S01_T05
  expect_loud_failure 2 checklayout --story E72_S01
  expect_loud_failure 2 bash "$SCRIPT" --check-layout --report --projects-dir "$PROJECTS" --project-dir "$PROJ"
}

@test "--list-transcripts and --usage stay lenient: they still work on trees --report refuses" {
  mk_sub "$SLUG" s1 a1 - "$(ln_nousage r1)"
  run --separate-stderr bash "$SCRIPT" --list-transcripts --projects-dir "$PROJECTS" --project-dir "$PROJ"
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq 'length')" = "1" ]
  run --separate-stderr bash "$SCRIPT" --usage "$PROJECTS/$SLUG/s1/subagents/agent-a1.jsonl"
  [ "$status" -eq 0 ]
  printf '%s' "$output" | jq -e '.usage_lines == 0 and .assistant_lines == 1 and .usage_incomplete_lines == 0 and .usage_missing_fields == []' >/dev/null
}

@test "--usage exposes the counters behind check 4" {
  mk_sub "$SLUG" s1 a1 "$GOOD_META" "$(ln_usage r1 1 10 100 1000 | jq -c 'del(.message.usage.cache_read_input_tokens, .message.usage.output_tokens)')" "$(ln_usage r2 1 1 1 1)"
  run --separate-stderr bash "$SCRIPT" --usage "$PROJECTS/$SLUG/s1/subagents/agent-a1.jsonl"
  [ "$status" -eq 0 ]
  printf '%s' "$output" | jq -e '.assistant_lines == 2 and .usage_lines == 2 and .usage_incomplete_lines == 1
    and .usage_missing_fields == ["cache_read_input_tokens","output_tokens"]' >/dev/null
}
