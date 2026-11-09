#!/usr/bin/env bats
#
# E76_S03_T03: scripts/task-usage.sh --report overhead allocation and the per-story rollup (--allocate, --stories).
#
# The rule under test is project/documentation/task-usage.md, "Allocating overhead to stories", and the first tests
# reproduce its worked example with the document's own numbers. All fixtures are synthetic and built under
# $BATS_TEST_TMPDIR; no real ~/.claude/projects data and no real board is read. Fixture helpers are local to this file.
# E76 ships publicly (decided 2026-11-07), so this file ships and must not depend on anything private.

bats_require_minimum_version 1.5.0

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
SCRIPT="$REPO_ROOT/scripts/task-usage.sh"

PROJ="/fake/work/proj"
SLUG="-fake-work-proj"

setup() {
  PROJECTS="$BATS_TEST_TMPDIR/projects"
  BOARD="$BATS_TEST_TMPDIR/board-stories"
  mkdir -p "$PROJECTS/$SLUG"
}

# ln_usage <requestId> <input> <output> <cache_write> <cache_read>: one assistant line with usage
ln_usage() {
  jq -n -c --arg r "$1" --argjson i "$2" --argjson o "$3" --argjson cw "$4" --argjson cr "$5" \
    '{type:"assistant",requestId:$r,message:{role:"assistant",usage:{input_tokens:$i,output_tokens:$o,cache_creation_input_tokens:$cw,cache_read_input_tokens:$cr}}}'
}

# mk_sub <session> <agent-id> <meta name> <input> <output> <cache_write> <cache_read>: a subagent transcript + meta
mk_sub() {
  local d="$PROJECTS/$SLUG/$1/subagents"
  mkdir -p "$d"
  jq -n -c --arg n "$3" '{agentType:"developer",name:$n}' > "$d/agent-$2.meta.json"
  { jq -n -c '{type:"user",isSidechain:true,message:{role:"user",content:"hello"}}'
    ln_usage "r-$2" "$4" "$5" "$6" "$7"; } > "$d/agent-$2.jsonl"
}

# mk_sm <session> <agent-id> <meta name> <input> <output> <cache_write> <cache_read>: a scrum-master subagent
mk_sm() {
  mk_sub "$@"
  jq -n -c --arg n "$3" '{agentType:"scrum-master",name:$n}' > "$PROJECTS/$SLUG/$1/subagents/agent-$2.meta.json"
}

# mk_session <session> <input> <output> <cache_write> <cache_read>: a main-session transcript
mk_session() {
  { jq -n -c '{type:"user",message:{role:"user",content:"hello"}}'
    ln_usage "s-$1" "$2" "$3" "$4" "$5"; } > "$PROJECTS/$SLUG/$1.jsonl"
}

# mk_story <id> <task>...: a board story file with a block tasks: list
mk_story() {
  local id="$1"
  shift
  mkdir -p "$BOARD"
  { printf -- '---\nid: %s\ntitle: x\ntasks:\n' "$id"
    local t; for t in "$@"; do printf '  - %s\n' "$t"; done
    printf -- '---\n\n# Story\n'; } > "$BOARD/${id}_slug.md"
}

report() { bash "$SCRIPT" --report --projects-dir "$PROJECTS" --project-dir "$PROJ" --board-stories-dir "$BOARD" "$@"; }

# The worked example of the document: three stories (weights 3, 1, 6) in one session entry.
worked_example() {
  mk_sub s1 a1 E9_S02_T01 1 1 1 0
  mk_sub s1 a2 E10_S01_T01 1 0 0 0
  mk_sub s1 a3 E9_S10_T01 1 2 3 50
  mk_session s1 14 25 9 1000
}

# alloc <story> <field>: allocated overhead field of one story in $output
alloc() { printf '%s' "$output" | jq -r --arg s "$1" ".stories[\$s].allocated_overhead.$2"; }

@test "the worked example: shares per field are exactly the document's table" {
  worked_example
  run report --allocate
  [ "$status" -eq 0 ]
  # input 4/1/9, output 8/2/15, cache_write 3/1/5, cache_read 300/100/600 (E9_S02 / E10_S01 / E9_S10)
  [ "$(alloc E9_S02 input)" = "4" ];   [ "$(alloc E10_S01 input)" = "1" ];   [ "$(alloc E9_S10 input)" = "9" ]
  [ "$(alloc E9_S02 output)" = "8" ];  [ "$(alloc E10_S01 output)" = "2" ];  [ "$(alloc E9_S10 output)" = "15" ]
  [ "$(alloc E9_S02 cache_write)" = "3" ]; [ "$(alloc E10_S01 cache_write)" = "1" ]; [ "$(alloc E9_S10 cache_write)" = "5" ]
  [ "$(alloc E9_S02 cache_read)" = "300" ]; [ "$(alloc E10_S01 cache_read)" = "100" ]; [ "$(alloc E9_S10 cache_read)" = "600" ]
  # the per-story sums of the four are 315, 104 and 629, and they total 1048 = 14 + 25 + 9 + 1000
  [ "$(alloc E9_S02 total_tokens)" = "315" ]
  [ "$(alloc E10_S01 total_tokens)" = "104" ]
  [ "$(alloc E9_S10 total_tokens)" = "629" ]
  [ "$(printf '%s' "$output" | jq '[.stories[].allocated_overhead.total_tokens] | add')" = "1048" ]
  [ "$(printf '%s' "$output" | jq -c '.unallocated_overhead')" = "[]" ]
}

@test "the worked example: stories come in numeric ID order (E9_S02, E9_S10, E10_S01), not string order" {
  worked_example
  run report --allocate
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -c '.stories | keys_unsorted')" = '["E9_S02","E9_S10","E10_S01"]' ]
}

@test "the worked example: a story's total is its task tokens plus its allocated overhead, kept as separate numbers" {
  worked_example
  run report --allocate
  [ "$status" -eq 0 ]
  # E9_S10's tasks: input 1, output 2, cache_write 3, cache_read 50 = 56; overhead 629; total 685
  [ "$(printf '%s' "$output" | jq '.stories.E9_S10.tasks.total_tokens')" = "56" ]
  [ "$(printf '%s' "$output" | jq '.stories.E9_S10.allocated_overhead.total_tokens')" = "629" ]
  [ "$(printf '%s' "$output" | jq '.stories.E9_S10.total.total_tokens')" = "685" ]
  [ "$(printf '%s' "$output" | jq '.stories.E9_S10.weight')" = "6" ]
  run jq -e '[.stories[] | select(.measured) | . as $s
              | all(["input","output","cache_write","cache_read","total_tokens"][]; . as $f
                    | $s.total[$f] == $s.tasks[$f] + $s.allocated_overhead[$f])] | all' <<<"$output"
  [ "$status" -eq 0 ]
}

@test "the worked example: the existing task-level output is unchanged by the allocation" {
  worked_example
  run report
  [ "$status" -eq 0 ]
  plain="$output"
  run report --allocate
  [ "$status" -eq 0 ]
  for k in tasks overhead unmapped warnings schema_version; do
    [ "$(printf '%s' "$plain" | jq -c ".$k")" = "$(printf '%s' "$output" | jq -c ".$k")" ]
  done
  # a task keeps its own numbers: the overhead is in no task record
  [ "$(printf '%s' "$output" | jq '.tasks.E9_S10_T01.usage_total_tokens')" = "56" ]
}

@test "without --allocate or --stories the report has exactly the original top-level keys" {
  worked_example
  run report
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -c 'keys')" = '["generated_at","overhead","schema_version","tasks","unmapped","warnings"]' ]
  run report --allocate
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -c 'keys')" = '["generated_at","overhead","schema_version","stories","tasks","unallocated_overhead","unmapped","warnings"]' ]
  [ "$(printf '%s' "$output" | jq '.schema_version')" = "1" ]
}

@test "a story-named entry is charged in full to that story and the story's session-mates take nothing from it" {
  worked_example
  mk_sm s1 sm1 E9_S02 5 40 12 700
  run report --allocate
  [ "$status" -eq 0 ]
  # the session entry still splits as in the example; E9_S02 additionally carries 5, 40, 12, 700
  [ "$(alloc E9_S02 input)" = "9" ]
  [ "$(alloc E9_S02 output)" = "48" ]
  [ "$(alloc E9_S02 cache_write)" = "15" ]
  [ "$(alloc E9_S02 cache_read)" = "1000" ]
  [ "$(alloc E10_S01 total_tokens)" = "104" ]
  [ "$(alloc E9_S10 total_tokens)" = "629" ]
}

@test "a story-named entry for a story with no tasks is charged to it, and the story is reported as not measured" {
  worked_example
  mk_sm s1 sm1 E50_S01 5 40 12 700
  run report --allocate
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -c '.stories.E50_S01 | {measured, weight, tasks, total}')" = '{"measured":false,"weight":null,"tasks":null,"total":null}' ]
  [ "$(alloc E50_S01 input)" = "5" ]
  [ "$(alloc E50_S01 output)" = "40" ]
  [ "$(alloc E50_S01 cache_write)" = "12" ]
  [ "$(alloc E50_S01 cache_read)" = "700" ]
  [ "$(printf '%s' "$output" | jq -c '.stories.E50_S01.measured_tasks')" = "[]" ]
}

@test "a requested story with no tasks and no overhead is not measured: no invented numbers" {
  worked_example
  run report --stories E77_S01
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -c '.stories | keys')" = '["E77_S01"]' ]
  [ "$(printf '%s' "$output" | jq -c '.stories.E77_S01 | {measured, weight, tasks, total}')" = '{"measured":false,"weight":null,"tasks":null,"total":null}' ]
  [ "$(alloc E77_S01 total_tokens)" = "0" ]
}

@test "a session-level entry whose candidate stories all have weight 0 is unallocated with reason zero-weight" {
  mk_sub s1 a1 E9_S02_T01 0 0 0 100
  mk_sub s1 a2 E9_S10_T01 0 0 0 100
  mk_session s1 6 30 4 500
  run report --allocate
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -c '.unallocated_overhead | map({id, level, input, output, cache_write, cache_read, reason})')" \
    = '[{"id":null,"level":"none","input":6,"output":30,"cache_write":4,"cache_read":500,"reason":"zero-weight"}]' ]
  [ "$(printf '%s' "$output" | jq -r '.unallocated_overhead[0].path | endswith("/s1.jsonl")')" = "true" ]
  # neither story changes
  [ "$(alloc E9_S02 total_tokens)" = "0" ]
  [ "$(alloc E9_S10 total_tokens)" = "0" ]
}

@test "a session with no task transcript under its directory is unallocated with reason no-candidate-story" {
  mk_sub s1 a1 E9_S02_T01 1 1 1 1
  mk_session s2 6 30 4 500
  run report --allocate
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r '.unallocated_overhead | map(.reason) | join(",")')" = "no-candidate-story" ]
  [ "$(printf '%s' "$output" | jq '.unallocated_overhead[0].cache_read')" = "500" ]
  [ "$(alloc E9_S02 total_tokens)" = "0" ]
  # never charged to a task either
  [ "$(printf '%s' "$output" | jq '.tasks.E9_S02_T01.usage_total_tokens')" = "4" ]
}

@test "an entry with four zero amounts that cannot be placed produces no unallocated record" {
  mk_sub s1 a1 E9_S02_T01 1 1 1 1
  mk_session s2 0 0 0 0
  run report --allocate
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -c '.unallocated_overhead')" = "[]" ]
}

@test "an epic-level scrum-master entry is split across the session's stories like a main session" {
  worked_example
  mk_sm s1 sm1 E9 0 0 0 1000
  run report --allocate
  [ "$status" -eq 0 ]
  # cache_read 1000 more, split 300/100/600 on top of the example's own 300/100/600
  [ "$(alloc E9_S02 cache_read)" = "600" ]
  [ "$(alloc E10_S01 cache_read)" = "200" ]
  [ "$(alloc E9_S10 cache_read)" = "1200" ]
}

@test "entries are allocated one by one, each with its own session's stories" {
  mk_sub s1 a1 E9_S02_T01 1 0 2 0
  mk_sub s2 a2 E9_S10_T01 1 0 8 0
  mk_session s1 0 0 0 100
  mk_session s2 0 0 0 100
  run report --allocate
  [ "$status" -eq 0 ]
  # s1 has only E9_S02 as a candidate, s2 only E9_S10: each takes its whole entry, no mixing across sessions
  [ "$(alloc E9_S02 cache_read)" = "100" ]
  [ "$(alloc E9_S10 cache_read)" = "100" ]
}

@test "shares are proportional to story weight: twice the weight, twice the share, up to the rounding" {
  mk_sub s1 a1 E20_S01_T01 0 0 2000 0
  mk_sub s1 a2 E20_S02_T01 0 0 1000 0
  mk_session s1 0 100 0 3000
  run report --allocate
  [ "$status" -eq 0 ]
  # divisible case: exactly double
  [ "$(alloc E20_S01 cache_read)" = "2000" ]
  [ "$(alloc E20_S02 cache_read)" = "1000" ]
  # 100 over 2:1 does not divide: 67 and 33, within one token of exactly double
  a="$(alloc E20_S01 output)"; b="$(alloc E20_S02 output)"
  [ "$((a + b))" = "100" ]
  [ "$((a - 2 * b))" -le 2 ]
  [ "$((2 * b - a))" -le 2 ]
}

@test "no remainder is lost: per field, shares plus unallocated equal the overhead, across mixed entries" {
  mk_sub s1 a1 E5_S01_T01 3 7 11 13
  mk_sub s1 a2 E5_S02_T01 17 19 23 29
  mk_sub s1 a3 E5_S03_T01 31 37 41 43
  mk_sub s2 a4 E6_S01_T01 47 53 59 61
  mk_sub s2 a5 E6_S02_T01 67 71 73 79
  mk_session s1 1001 2003 3007 4013
  mk_session s2 97 101 103 107
  mk_session s3 5 6 7 8
  mk_sm s1 sm1 E5_S02 11 13 17 19
  mk_sm s2 sm2 E6 23 29 31 37
  mk_sm s3 sm3 E7_S09 41 43 47 53
  run report --allocate
  [ "$status" -eq 0 ]
  report_json="$output"
  # s3 has no tasks, so its session entry (5,6,7,8) is the only unallocated one; sm3 names E7_S09 and is charged
  [ "$(printf '%s' "$output" | jq -c '[.unallocated_overhead[] | .reason]')" = '["no-candidate-story"]' ]
  [ "$(alloc E7_S09 input)" = "41" ]
  run jq -e '. as $r
    | all(["input","output","cache_write","cache_read"][]; . as $f
          | ([$r.stories[].allocated_overhead[$f]] | add) + ([$r.unallocated_overhead[][$f]] | add // 0)
            == ([$r.overhead[][$f]] | add))' <<<"$report_json"
  [ "$status" -eq 0 ]
}

@test "the leftover tokens go to the largest remainders, ties to the numeric story ID" {
  # three stories of equal weight 1 share 2 tokens: remainders tie at 2/3, the first two in numeric order get one
  mk_sub s1 a1 E10_S01_T01 1 0 0 0
  mk_sub s1 a2 E9_S10_T01 1 0 0 0
  mk_sub s1 a3 E9_S02_T01 1 0 0 0
  mk_session s1 0 2 0 0
  run report --allocate
  [ "$status" -eq 0 ]
  [ "$(alloc E9_S02 output)" = "1" ]
  [ "$(alloc E9_S10 output)" = "1" ]
  [ "$(alloc E10_S01 output)" = "0" ]
}

@test "a zero-weight story that shares a session with weighted stories never receives a leftover token" {
  mk_sub s1 a1 E9_S01_T01 0 0 0 5
  mk_sub s1 a2 E9_S02_T01 1 0 0 0
  mk_sub s1 a3 E9_S03_T01 2 0 0 0
  mk_session s1 0 10 0 0
  run report --allocate
  [ "$status" -eq 0 ]
  [ "$(alloc E9_S01 output)" = "0" ]
  [ "$(alloc E9_S02 output)" = "3" ]
  [ "$(alloc E9_S03 output)" = "7" ]
}

@test "arithmetic beyond 2^53 stays exact: field totals and weights in the billions (products above 2^64)" {
  # weights 5000000003 / 7000000009 / 11000000017 (cache_write of one task each), W = 23000000029
  mk_sub s1 a1 E9_S02_T01 0 0 5000000003 0
  mk_sub s1 a2 E10_S01_T01 0 0 7000000009 0
  mk_sub s1 a3 E9_S10_T01 0 0 11000000017 0
  mk_session s1 4000000000007 3000000000001 9007199254740990 8123456789012345
  run report --allocate
  [ "$status" -eq 0 ]
  # expected values computed with exact big-integer arithmetic (largest remainder, numeric-ID tie-break)
  [ "$(alloc E9_S02 input)" = "869565216818" ];  [ "$(alloc E10_S01 input)" = "1217391304380" ];  [ "$(alloc E9_S10 input)" = "1913043478809" ]
  [ "$(alloc E9_S02 output)" = "652173912613" ]; [ "$(alloc E10_S01 output)" = "913043478284" ];   [ "$(alloc E9_S10 output)" = "1434782609104" ]
  [ "$(alloc E9_S02 cache_write)" = "1958086793214871" ]
  [ "$(alloc E10_S01 cache_write)" = "2741321512380583" ]
  [ "$(alloc E9_S10 cache_write)" = "4307790949145536" ]
  [ "$(alloc E9_S02 cache_read)" = "1765968866009522" ]
  [ "$(alloc E10_S01 cache_read)" = "2472356414108660" ]
  [ "$(alloc E9_S10 cache_read)" = "3885131508894163" ]
  # and nothing is lost
  run jq -e '. as $r | all(["input","output","cache_write","cache_read"][]; . as $f
      | ([$r.stories[].allocated_overhead[$f]] | add) == $r.overhead[0][$f])' <<<"$output"
  [ "$status" -eq 0 ]
}

@test "the filters narrow tasks only: the allocation and the stories section do not depend on --task or --story" {
  worked_example
  run report --allocate
  [ "$status" -eq 0 ]
  full_stories="$(printf '%s' "$output" | jq -c '.stories')"
  full_unalloc="$(printf '%s' "$output" | jq -c '.unallocated_overhead')"
  run report --allocate --task E9_S10_T01
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -c '.tasks | keys')" = '["E9_S10_T01"]' ]
  [ "$(printf '%s' "$output" | jq -c '.stories')" = "$full_stories" ]
  [ "$(printf '%s' "$output" | jq -c '.unallocated_overhead')" = "$full_unalloc" ]
  run report --allocate --story E10_S01
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -c '.tasks | keys')" = '["E10_S01_T01"]' ]
  [ "$(printf '%s' "$output" | jq -c '.stories')" = "$full_stories" ]
}

@test "--stories narrows the stories section only, with the same numbers as the unfiltered run" {
  worked_example
  run report --allocate
  [ "$status" -eq 0 ]
  full="$(printf '%s' "$output" | jq -c '.stories')"
  run report --stories E9_S10 --stories E9_S02
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -c '.stories | keys_unsorted')" = '["E9_S02","E9_S10"]' ]
  [ "$(printf '%s' "$output" | jq -c '.stories')" = "$(printf '%s' "$full" | jq -c '{E9_S02, E9_S10}')" ]
  # tasks, overhead, unmapped and warnings are complete, as without the option
  [ "$(printf '%s' "$output" | jq '.tasks | length')" = "3" ]
  [ "$(printf '%s' "$output" | jq '.overhead | length')" = "1" ]
  [ "$(printf '%s' "$output" | jq -c '.warnings')" = "[]" ]
}

@test "--stories does not take part in the zero-versus-absent exit 8 and --story still does" {
  worked_example
  run report --stories E77_S01
  [ "$status" -eq 0 ]
  run report --story E77_S01 --stories E9_S02
  [ "$status" -eq 8 ]
}

@test "--stories with a malformed ID, or without --report, exits 2 with nothing on stdout" {
  run --separate-stderr report --stories not-a-story
  [ "$status" -eq 2 ]
  [ -z "$output" ]
  run --separate-stderr report --stories E9_S10_T01
  [ "$status" -eq 2 ]
  run --separate-stderr bash "$SCRIPT" --list-transcripts --stories E9_S02 --projects-dir "$PROJECTS" --project-dir "$PROJ"
  [ "$status" -eq 2 ]
  run --separate-stderr bash "$SCRIPT" --check-layout --allocate --projects-dir "$PROJECTS" --project-dir "$PROJ"
  [ "$status" -eq 2 ]
  run --separate-stderr bash "$SCRIPT" --report --stories --projects-dir "$PROJECTS"
  [ "$status" -eq 2 ]
}

@test "the board roster: tasks come from the story file's tasks: list and the unmeasured ones are named" {
  worked_example
  mk_story E9_S10 E9_S10_T01 E9_S10_T02
  mkdir -p "$BOARD"
  printf -- '---\nid: E9_S02\ntasks: ["E9_S02_T01", E9_S02_T02]\n---\n' > "$BOARD/E9_S02_inline.md"
  run report --allocate
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -c '.stories.E9_S10 | {board_tasks, measured_tasks, unmeasured_tasks}')" \
    = '{"board_tasks":["E9_S10_T01","E9_S10_T02"],"measured_tasks":["E9_S10_T01"],"unmeasured_tasks":["E9_S10_T02"]}' ]
  [ "$(printf '%s' "$output" | jq -c '.stories.E9_S02.unmeasured_tasks')" = '["E9_S02_T02"]' ]
  # a story with no story file has no roster, which is null and not an empty list
  [ "$(printf '%s' "$output" | jq -c '.stories.E10_S01 | {board_tasks, unmeasured_tasks}')" = '{"board_tasks":null,"unmeasured_tasks":null}' ]
  # the sums come from the measured tasks: the unmeasured one adds nothing and is not zeros
  [ "$(printf '%s' "$output" | jq '.stories.E9_S10.tasks.total_tokens')" = "56" ]
}

@test "a missing board directory is not an error and adds no warning" {
  worked_example
  run bash "$SCRIPT" --report --allocate --projects-dir "$PROJECTS" --project-dir "$PROJ" --board-stories-dir "$BATS_TEST_TMPDIR/nope"
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -c '.warnings')" = "[]" ]
  [ "$(printf '%s' "$output" | jq -c '.stories.E9_S10.board_tasks')" = "null" ]
}

@test "the worktree-slug transcripts of a task count toward the story weight and the session lookup uses their own session directory" {
  mk_sub s1 a1 E9_S02_T01 0 0 10 0
  # the same story's other task ran in a session under a worktree slug directory: it has its own session directory,
  # so it does not make E9_S02 a candidate of s1's overhead entry, but it does count toward the story's weight
  mkdir -p "$PROJECTS/$SLUG--claude-worktrees-w1/s9/subagents"
  jq -n -c '{agentType:"developer",name:"E9_S02_T02"}' > "$PROJECTS/$SLUG--claude-worktrees-w1/s9/subagents/agent-w1.meta.json"
  { jq -n -c '{type:"user",message:{role:"user",content:"hi"}}'; ln_usage rw 0 0 30 0; } > "$PROJECTS/$SLUG--claude-worktrees-w1/s9/subagents/agent-w1.jsonl"
  mk_sub s1 a2 E9_S10_T01 0 0 10 0
  mk_session s1 0 0 0 100
  run report --allocate
  [ "$status" -eq 0 ]
  # weights: E9_S02 = 10 + 30 = 40, E9_S10 = 10; candidates of s1 are both (E9_S02 via T01): 80 / 20
  [ "$(printf '%s' "$output" | jq '.stories.E9_S02.weight')" = "40" ]
  [ "$(alloc E9_S02 cache_read)" = "80" ]
  [ "$(alloc E9_S10 cache_read)" = "20" ]
}
