#!/usr/bin/env bats
# bats file_tags=tier:integration
#
# E90_S01_T03: scripts/task-usage.sh prints the cost-equivalent unit ("cost_units") next to the four raw counts, per
# transcript (--usage) and per task (--report), priced per line by the line's own model with the 5-minute and 1-hour
# cache-write counts priced separately. All fixtures are synthetic and built under $BATS_TEST_TMPDIR, with their own
# price-ratio config (JENGA_PRICE_RATIOS_FILE), so the test does not depend on the shipped ratios.

bats_require_minimum_version 1.5.0

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
SCRIPT="$REPO_ROOT/scripts/task-usage.sh"
PROJ="/fake/work/proj"
SLUG="-fake-work-proj"

setup() {
  PROJECTS="$BATS_TEST_TMPDIR/projects"
  mkdir -p "$PROJECTS/$SLUG"
  # Two models with DIFFERENT ratio sets (m-b is exactly double m-a) so that a wrong model pick changes the answer.
  cat > "$BATS_TEST_TMPDIR/ratios.json" <<'JSON'
{"config_version":1,"date":"2026-11-19","models":{
 "m-a":{"input":1,"cache_write_5m":1.25,"cache_write_1h":2,"cache_read":0.1,"output":5},
 "m-b":{"input":2,"cache_write_5m":2.5,"cache_write_1h":4,"cache_read":0.2,"output":10}}}
JSON
  export JENGA_PRICE_RATIOS_FILE="$BATS_TEST_TMPDIR/ratios.json"
}

# ln <requestId> <model> <input> <output> <cw5m> <cw1h> <cache_read>: one assistant line; cache_creation_input_tokens is
# the sum of the two TTL counts, as on every line of real transcripts
ln() {
  jq -n -c --arg r "$1" --arg m "$2" --argjson i "$3" --argjson o "$4" --argjson w5 "$5" --argjson w1 "$6" --argjson cr "$7" \
    '{type:"assistant",requestId:$r,message:{role:"assistant",model:$m,usage:{input_tokens:$i,output_tokens:$o,
      cache_creation_input_tokens:($w5+$w1),cache_read_input_tokens:$cr,
      cache_creation:{ephemeral_5m_input_tokens:$w5,ephemeral_1h_input_tokens:$w1}}}}'
}

# mk_sub <session> <agent-id> <task-id> <line>...
mk_sub() {
  local d="$PROJECTS/$SLUG/$1/subagents" aid="$2" id="$3"
  mkdir -p "$d"
  shift 3
  printf '{"agentType":"developer","name":"%s"}\n' "$id" > "$d/agent-$aid.meta.json"
  { jq -n -c '{type:"user",message:{role:"user",content:"hello"}}'
    local l; for l in "$@"; do printf '%s\n' "$l"; done; } > "$d/agent-$aid.jsonl"
}

# The hand-computed fixture. Ratios are in units of one fresh input token.
#   line A (m-a): input 100, output 10, cache write 5m 1000, cache write 1h 500, cache read 2000
#     100*1 + 1000*1.25 + 500*2 + 2000*0.1 + 10*5 = 100 + 1250 + 1000 + 200 + 50 = 2600
#   line B (m-b): input 10, output 20, cache write 5m 400, cache write 1h 100, cache read 3000
#     10*2 + 400*2.5 + 100*4 + 3000*0.2 + 20*10 = 20 + 1000 + 400 + 600 + 200 = 2220
#   transcript total 2600 + 2220 = 4820 (a wrong model pick, e.g. m-a for both, would give 2600 + 1110 = 3710)
LINE_A() { ln r1 m-a 100 10 1000 500 2000; }
LINE_B() { ln r2 m-b 10 20 400 100 3000; }

@test "--usage: two models and both cache-write TTLs give the hand-computed cost_units 4820 next to the four raw counts" {
  mk_sub s1 a1 E90_S01_T03 "$(LINE_A)" "$(LINE_B)"
  run bash "$SCRIPT" --usage "$PROJECTS/$SLUG/s1/subagents/agent-a1.jsonl"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.input == 110 and .output == 30 and .cache_write == 2000 and .cache_read == 5000' >/dev/null
  echo "$output" | jq -e '.cost_units == 4820 and .unpriced_models == []' >/dev/null
}

@test "--report: the task carries the same cost_units, and the sum over transcripts is the sum of their units" {
  mk_sub s1 a1 E90_S01_T03 "$(LINE_A)" "$(LINE_B)"
  # second transcript, same task, model m-a only: 2600 again, so the task is 4820 + 2600 = 7420
  mk_sub s2 a2 E90_S01_T03 "$(ln r9 m-a 100 10 1000 500 2000)"
  run --separate-stderr bash "$SCRIPT" --report --projects-dir "$PROJECTS" --project-dir "$PROJ"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.tasks.E90_S01_T03 | .cost_units == 7420 and .unpriced_models == [] and .input == 210 and .usage_transcripts == 2' >/dev/null
}

@test "a streaming call is priced once, from its last line, by its own model" {
  mk_sub s1 a1 E90_S01_T03 "$(ln r1 m-a 100 1 1000 500 2000)" "$(ln r1 m-a 100 10 1000 500 2000)"
  run bash "$SCRIPT" --usage "$PROJECTS/$SLUG/s1/subagents/agent-a1.jsonl"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.cost_units == 2600' >/dev/null
}

@test "a model with no ratios is named as unpriced, is never guessed, and the raw counts are still printed" {
  mk_sub s1 a1 E90_S01_T03 "$(ln r1 m-unknown 100 10 1000 500 2000)"
  run bash "$SCRIPT" --usage "$PROJECTS/$SLUG/s1/subagents/agent-a1.jsonl"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.cost_units == null and .unpriced_models == ["m-unknown"]' >/dev/null
  echo "$output" | jq -e '.input == 100 and .output == 10 and .cache_write == 1500 and .cache_read == 2000' >/dev/null
}

@test "a task with one priced and one unpriced transcript has cost_units null (never partial, never guessed) and names the model" {
  mk_sub s1 a1 E90_S01_T03 "$(LINE_A)"
  mk_sub s2 a2 E90_S01_T03 "$(ln r2 m-unknown 5 5 5 5 5)"
  run --separate-stderr bash "$SCRIPT" --report --projects-dir "$PROJECTS" --project-dir "$PROJ"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.tasks.E90_S01_T03 | .cost_units == null and .unpriced_models == ["m-unknown"] and .input == 105' >/dev/null
}

@test "a date-suffixed model id uses its base model's ratios" {
  mk_sub s1 a1 E90_S01_T03 "$(ln r1 m-a-20261119 100 10 1000 500 2000)"
  run bash "$SCRIPT" --usage "$PROJECTS/$SLUG/s1/subagents/agent-a1.jsonl"
  echo "$output" | jq -e '.cost_units == 2600 and .unpriced_models == []' >/dev/null
}

@test "a usage line without the 5m/1h split prices its cache-write total at the 5-minute ratio (documented rule)" {
  local l='{"type":"assistant","requestId":"r1","message":{"role":"assistant","model":"m-a","usage":{"input_tokens":0,"output_tokens":0,"cache_creation_input_tokens":100,"cache_read_input_tokens":0}}}'
  mk_sub s1 a1 E90_S01_T03 "$l"
  run bash "$SCRIPT" --usage "$PROJECTS/$SLUG/s1/subagents/agent-a1.jsonl"
  # 100 * 1.25 = 125
  echo "$output" | jq -e '.cost_units == 125' >/dev/null
}

@test "config absent: --usage stops with exit 10 naming the config, with nothing on stdout (no silent raw-only output)" {
  mk_sub s1 a1 E90_S01_T03 "$(LINE_A)" "$(LINE_B)"
  local f="$PROJECTS/$SLUG/s1/subagents/agent-a1.jsonl"
  JENGA_PRICE_RATIOS_FILE="$BATS_TEST_TMPDIR/does-not-exist.json" run --separate-stderr bash "$SCRIPT" --usage "$f"
  [ "$status" -eq 10 ]
  [ -z "$output" ]
  [[ "$stderr" == *"price-ratio config missing or unreadable: $BATS_TEST_TMPDIR/does-not-exist.json"* ]]
}

@test "loader absent: exit 10 naming the loader (the script is copied to a directory with no loader)" {
  mk_sub s1 a1 E90_S01_T03 "$(LINE_A)" "$(LINE_B)"
  local f="$PROJECTS/$SLUG/s1/subagents/agent-a1.jsonl"
  mkdir -p "$BATS_TEST_TMPDIR/noloader"
  cp "$SCRIPT" "$BATS_TEST_TMPDIR/noloader/task-usage.sh"
  run --separate-stderr bash "$BATS_TEST_TMPDIR/noloader/task-usage.sh" --usage "$f"
  [ "$status" -eq 10 ]
  [ -z "$output" ]
  [[ "$stderr" == *"noloader/token-price-ratios.sh"* ]]
}

@test "--report with the config absent stops with exit 10 and prints no report" {
  mk_sub s1 a1 E90_S01_T03 "$(LINE_A)"
  JENGA_PRICE_RATIOS_FILE="$BATS_TEST_TMPDIR/does-not-exist.json" run --separate-stderr bash "$SCRIPT" --report --projects-dir "$PROJECTS" --project-dir "$PROJ"
  [ "$status" -eq 10 ]
  [ -z "$output" ]
}

@test "cost_units is whole units: the exact hundredths are rounded half up once" {
  # m-a cache_read ratio 0.1: 5 tokens = 0.5 units -> 1; 4 tokens = 0.4 units -> 0
  mk_sub s1 a1 E90_S01_T03 "$(ln r1 m-a 0 0 0 0 5)"
  mk_sub s2 a2 E90_S01_T04 "$(ln r2 m-a 0 0 0 0 4)"
  run --separate-stderr bash "$SCRIPT" --report --projects-dir "$PROJECTS" --project-dir "$PROJ"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.tasks.E90_S01_T03.cost_units == 1 and .tasks.E90_S01_T04.cost_units == 0' >/dev/null
}

@test "--usage does not leak the internal exact-hundredths key" {
  mk_sub s1 a1 E90_S01_T03 "$(LINE_A)"
  run bash "$SCRIPT" --usage "$PROJECTS/$SLUG/s1/subagents/agent-a1.jsonl"
  [[ "$output" != *_cost_h* ]]
  run --separate-stderr bash "$SCRIPT" --report --projects-dir "$PROJECTS" --project-dir "$PROJ"
  [[ "$output" != *_cost_h* ]]
}
