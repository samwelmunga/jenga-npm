#!/usr/bin/env bats
# bats file_tags=tier:integration
#
# E90_S01_T10: the worked example in project/documentation/task-usage.md, section "The rule" > "Worked example", is
# run through scripts/task-usage.sh --report --allocate and every number the document states is asserted here: the task
# cost units, the story weights, each per-amount share and leftover unit, the story totals, the story-named entry, the
# unpriced-model case, the zero-weight case, and the second example (ties and numeric story ID order). If a number in
# the document is changed without the script (or the reverse), a test below fails.
#
# Fixture: tests/fixtures/task-usage-cost/ (transcripts and its own ratios.json). JENGA_PRICE_RATIOS_FILE points at that
# ratio config, so the test does not move when the real config in project/configs/ is re-dated. Cases that extend the
# fixture build their additions in a throwaway copy under $BATS_TEST_TMPDIR.

bats_require_minimum_version 1.5.0

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
SCRIPT="$REPO_ROOT/scripts/task-usage.sh"
FIX="$REPO_ROOT/tests/fixtures/task-usage-cost"
PROJ="/fixture/proj"

setup() {
  export JENGA_PRICE_RATIOS_FILE="$FIX/ratios.json"
  PROJECTS="$BATS_TEST_TMPDIR/projects"
  SESS="$PROJECTS/-fixture-proj/sess-0001"
  cp -R "$FIX/projects" "$PROJECTS"
}

# ln <requestId> <model> <input> <output> <cw5m> <cw1h> <cache_read>
ln() {
  jq -n -c --arg r "$1" --arg m "$2" --argjson i "$3" --argjson o "$4" --argjson w5 "$5" --argjson w1 "$6" --argjson cr "$7" \
    '{type:"assistant",requestId:$r,message:{role:"assistant",model:$m,usage:{input_tokens:$i,output_tokens:$o,
      cache_creation_input_tokens:($w5+$w1),cache_read_input_tokens:$cr,
      cache_creation:{ephemeral_5m_input_tokens:$w5,ephemeral_1h_input_tokens:$w1}}}}'
}

# add_sub <session> <agent-id> <agentType> <name> <line>: a subagent transcript with its sidecar
add_sub() {
  local d="$PROJECTS/-fixture-proj/$1/subagents"
  mkdir -p "$d"
  printf '{"agentType":"%s","name":"%s"}\n' "$3" "$4" > "$d/agent-$2.meta.json"
  printf '%s\n%s\n' '{"type":"user","message":{"role":"user","content":"synthetic"}}' "$5" > "$d/agent-$2.jsonl"
}

# report [projects-dir]: --report --allocate over the projects directory, JSON on stdout
report() {
  run --separate-stderr bash "$SCRIPT" --report --allocate --projects-dir "${1:-$PROJECTS}" --project-dir "$PROJ"
  [ "$status" -eq 0 ]
}

@test "tasks: cost units 50, 23 (22.50 rounds half up) and 20, and the story weights 73 and 20" {
  report
  echo "$output" | jq -e '.tasks.E9_S02_T01.cost_units == 50 and .tasks.E9_S02_T02.cost_units == 23 and .tasks.E10_S01_T01.cost_units == 20' >/dev/null
  echo "$output" | jq -e '.stories.E9_S02.weight == 73 and .stories.E10_S01.weight == 20' >/dev/null
  echo "$output" | jq -e '.stories.E9_S02.tasks.cost_units == 73 and .stories.E10_S01.tasks.cost_units == 20' >/dev/null
}

@test "the overhead entry is one session entry of 6 / 10 / 4 / 90 with cost_units 70" {
  report
  echo "$output" | jq -e '(.overhead | length) == 1 and (.overhead[0] | .kind == "session" and .level == "none"
    and .input == 6 and .output == 10 and .cache_write == 4 and .cache_read == 90 and .cost_units == 70)' >/dev/null
}

@test "allocated overhead per story: E9_S02 gets 5 / 8 / 3 / 71 / 55 and E10_S01 gets 1 / 2 / 1 / 19 / 15" {
  report
  echo "$output" | jq -e '.stories.E9_S02.allocated_overhead | .input == 5 and .output == 8 and .cache_write == 3 and .cache_read == 71 and .cost_units == 55' >/dev/null
  echo "$output" | jq -e '.stories.E10_S01.allocated_overhead | .input == 1 and .output == 2 and .cache_write == 1 and .cache_read == 19 and .cost_units == 15' >/dev/null
}

@test "story totals are task cost plus allocated overhead: 128 and 35, summing to 163, with nothing unallocated" {
  report
  echo "$output" | jq -e '.stories.E9_S02.total.cost_units == 128 and .stories.E10_S01.total.cost_units == 35' >/dev/null
  echo "$output" | jq -e '([.stories[].total.cost_units] | add) == 163 and ([.stories[].tasks.cost_units] | add) == 93' >/dev/null
  echo "$output" | jq -e '.unallocated_overhead == []' >/dev/null
  # each overhead column adds up exactly to the entry's amount
  echo "$output" | jq -e '[.stories[].allocated_overhead] | (map(.input)|add) == 6 and (map(.output)|add) == 10
    and (map(.cache_write)|add) == 4 and (map(.cache_read)|add) == 90 and (map(.cost_units)|add) == 70' >/dev/null
}

@test "a story-named entry (E10_S01, 2 / 3 / 0 / 40, cost_units 21) is charged in full to that story only" {
  add_sub sess-0001 s1 scrum-master E10_S01 "$(ln req_s1 fixture-priced 2 3 0 0 40)"
  report
  # E10_S01 = the split share plus the whole entry; E9_S02 is unchanged
  echo "$output" | jq -e '.stories.E10_S01.allocated_overhead | .input == 3 and .output == 5 and .cache_write == 1 and .cache_read == 59 and .cost_units == 36' >/dev/null
  echo "$output" | jq -e '.stories.E9_S02.allocated_overhead | .input == 5 and .output == 8 and .cache_write == 3 and .cache_read == 71 and .cost_units == 55' >/dev/null
  echo "$output" | jq -e '.unallocated_overhead == []' >/dev/null
}

@test "an unpriced third task leaves E9_S02's weight at 73, flags it partial, and names the model" {
  add_sub sess-0001 t4 developer E9_S02_T03 "$(ln req_t4 unpriced-model 5 5 5 0 5)"
  report
  echo "$output" | jq -e '.tasks.E9_S02_T03.cost_units == null and .tasks.E9_S02_T03.unpriced_models == ["unpriced-model"]' >/dev/null
  echo "$output" | jq -e '.stories.E9_S02 | .weight == 73 and .tasks.cost_units == 73 and .cost_units_partial == true' >/dev/null
  echo "$output" | jq -e '.stories.E9_S02.allocated_overhead.cost_units == 55 and .stories.E10_S01.allocated_overhead.cost_units == 15' >/dev/null
}

@test "zero weight: a session entry of 6 / 30 / 4 / 500 (cost_units 211) over unpriced-only stories is one unallocated record" {
  rm -rf "$PROJECTS"; mkdir -p "$PROJECTS/-fixture-proj"
  printf '%s\n%s\n' '{"type":"user","message":{"role":"user","content":"synthetic"}}' "$(ln req_m fixture-priced 6 30 4 0 500)" \
    > "$PROJECTS/-fixture-proj/sess-0001.jsonl"
  add_sub sess-0001 u1 developer E9_S02_T01 "$(ln req_u1 unpriced-model 5 5 5 0 5)"
  add_sub sess-0001 u2 developer E10_S01_T01 "$(ln req_u2 unpriced-model 5 5 5 0 5)"
  report
  echo "$output" | jq -e '(.unallocated_overhead | length) == 1 and (.unallocated_overhead[0] | .reason == "zero-weight"
    and .input == 6 and .output == 30 and .cache_write == 4 and .cache_read == 500 and .cost_units == 211)' >/dev/null
  echo "$output" | jq -e '.stories.E9_S02.weight == 0 and .stories.E10_S01.weight == 0
    and .stories.E9_S02.allocated_overhead.cost_units == 0 and .stories.E10_S01.allocated_overhead.cost_units == 0' >/dev/null
}

@test "second example: weights 3 / 1 / 6, ties broken by numeric story ID (E9_S10 before E10_S01; E9_S02 before E10_S01)" {
  rm -rf "$PROJECTS"; mkdir -p "$PROJECTS/-fixture-proj"
  printf '%s\n%s\n' '{"type":"user","message":{"role":"user","content":"synthetic"}}' "$(ln req_m fixture-priced 14 25 9 0 1000)" \
    > "$PROJECTS/-fixture-proj/sess-0001.jsonl"
  # input-only tasks price at 1 unit per token, so the weights are exactly 3, 1 and 6
  add_sub sess-0001 w1 developer E9_S02_T01 "$(ln req_w1 fixture-priced 3 0 0 0 0)"
  add_sub sess-0001 w2 developer E10_S01_T01 "$(ln req_w2 fixture-priced 1 0 0 0 0)"
  add_sub sess-0001 w3 developer E9_S10_T01 "$(ln req_w3 fixture-priced 6 0 0 0 0)"
  report
  echo "$output" | jq -e '.stories.E9_S02.weight == 3 and .stories.E10_S01.weight == 1 and .stories.E9_S10.weight == 6' >/dev/null
  # input (14): 4 + 1 + 9, the tie on remainder 4 goes to E9_S10
  echo "$output" | jq -e '(.stories.E9_S02.allocated_overhead.input == 4) and (.stories.E10_S01.allocated_overhead.input == 1) and (.stories.E9_S10.allocated_overhead.input == 9)' >/dev/null
  # output (25): 8 + 2 + 15, the tie on remainder 5 goes to E9_S02
  echo "$output" | jq -e '(.stories.E9_S02.allocated_overhead.output == 8) and (.stories.E10_S01.allocated_overhead.output == 2) and (.stories.E9_S10.allocated_overhead.output == 15)' >/dev/null
  # cache_write (9): 3 + 1 + 5, two leftover units to the largest remainders 9 (E10_S01) and 7 (E9_S02)
  echo "$output" | jq -e '(.stories.E9_S02.allocated_overhead.cache_write == 3) and (.stories.E10_S01.allocated_overhead.cache_write == 1) and (.stories.E9_S10.allocated_overhead.cache_write == 5)' >/dev/null
  # cache_read (1000): exact shares 300 + 100 + 600, no leftover
  echo "$output" | jq -e '(.stories.E9_S02.allocated_overhead.cache_read == 300) and (.stories.E10_S01.allocated_overhead.cache_read == 100) and (.stories.E9_S10.allocated_overhead.cache_read == 600)' >/dev/null
}
