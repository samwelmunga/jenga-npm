#!/usr/bin/env bats
# bats file_tags=tier:integration
#
# E90_S02_T02: the price-ratio loader and config are a DIRECT dependency of scripts/task-usage.sh. A missing or
# malformed one stops the cost-aware modes (--report, --persist, --usage) with exit 10 and a message naming the file;
# there is no silent fallback to the pre-E90 raw-only output. --list-transcripts and --check-layout never price
# anything and are UNAFFECTED (decision recorded in the script header). A model with no ratios is still unpriced.
# The j.close-story helpers report the error instead of printing raw-only output.

bats_require_minimum_version 1.5.0

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
SCRIPT="$REPO_ROOT/scripts/task-usage.sh"
WSU="$REPO_ROOT/skills/j-close-story/scripts/write-story-usage.sh"
PTU="$REPO_ROOT/skills/j-close-story/scripts/persist-task-usage.sh"
PROJ="/fake/work/proj"
SLUG="-fake-work-proj"

setup() {
  PROJECTS="$BATS_TEST_TMPDIR/projects"
  mkdir -p "$PROJECTS/$SLUG"
  cat > "$BATS_TEST_TMPDIR/ratios.json" <<'JSON'
{"config_version":1,"date":"2026-11-19","models":{"m-a":{"input":1,"cache_write_5m":1.25,"cache_write_1h":2,"cache_read":0.1,"output":5}}}
JSON
  export JENGA_PRICE_RATIOS_FILE="$BATS_TEST_TMPDIR/ratios.json"
  unset JENGA_PROJECT_ROOT
  export JENGA_PROJECTS_DIR="$PROJECTS"
}

# mk_sub <session> <agent-id> <task-id> <model>: one task-mapped subagent transcript
mk_sub() {
  local d="$PROJECTS/$SLUG/$1/subagents"
  mkdir -p "$d"
  printf '{"agentType":"developer","name":"%s"}\n' "$3" > "$d/agent-$2.meta.json"
  {
    printf '{"type":"user","message":{"role":"user","content":"hello"}}\n'
    printf '{"type":"assistant","requestId":"r1","message":{"role":"assistant","model":"%s","usage":{"input_tokens":1,"output_tokens":10,"cache_creation_input_tokens":100,"cache_read_input_tokens":1000,"cache_creation":{"ephemeral_5m_input_tokens":100,"ephemeral_1h_input_tokens":0}}}}\n' "$4"
  } > "$d/agent-$2.jsonl"
}

gone() { export JENGA_PRICE_RATIOS_FILE="$BATS_TEST_TMPDIR/no-such-ratios.json"; }

@test "--report with the config absent: exit 10, the message names the config, nothing on stdout" {
  mk_sub s1 a1 E90_S02_T02 m-a
  gone
  run --separate-stderr bash "$SCRIPT" --report --projects-dir "$PROJECTS" --project-dir "$PROJ"
  [ "$status" -eq 10 ]
  [ -z "$output" ]
  [[ "$stderr" == *"price-ratio config missing or unreadable: $BATS_TEST_TMPDIR/no-such-ratios.json"* ]]
}

@test "--report with a malformed config: exit 10 naming the config" {
  mk_sub s1 a1 E90_S02_T02 m-a
  printf 'not json' > "$BATS_TEST_TMPDIR/bad.json"
  export JENGA_PRICE_RATIOS_FILE="$BATS_TEST_TMPDIR/bad.json"
  run --separate-stderr bash "$SCRIPT" --report --projects-dir "$PROJECTS" --project-dir "$PROJ"
  [ "$status" -eq 10 ]
  [ -z "$output" ]
  [[ "$stderr" == *"price-ratio config malformed: $BATS_TEST_TMPDIR/bad.json"* ]]
}

@test "--report with the loader absent: exit 10 naming the loader" {
  mk_sub s1 a1 E90_S02_T02 m-a
  mkdir -p "$BATS_TEST_TMPDIR/copy/lib"
  cp "$SCRIPT" "$BATS_TEST_TMPDIR/copy/task-usage.sh"
  cp "$REPO_ROOT/scripts/lib/board-ids.sh" "$BATS_TEST_TMPDIR/copy/lib/"
  run --separate-stderr bash "$BATS_TEST_TMPDIR/copy/task-usage.sh" --report --projects-dir "$PROJECTS" --project-dir "$PROJ"
  [ "$status" -eq 10 ]
  [ -z "$output" ]
  [[ "$stderr" == *"copy/token-price-ratios.sh"* ]]
}

@test "--usage and --persist stop with exit 10 too, and --persist writes nothing" {
  mk_sub s1 a1 E90_S02_T02 m-a
  gone
  run --separate-stderr bash "$SCRIPT" --usage "$PROJECTS/$SLUG/s1/subagents/agent-a1.jsonl"
  [ "$status" -eq 10 ]
  mkdir -p "$BATS_TEST_TMPDIR/root/project/board/tasks"
  printf -- '---\nid: E90_S02_T02\nstatus: Passed\n---\n' > "$BATS_TEST_TMPDIR/root/project/board/tasks/E90_S02_T02_x.md"
  before="$(cat "$BATS_TEST_TMPDIR/root/project/board/tasks/E90_S02_T02_x.md")"
  JENGA_PROJECT_ROOT="$BATS_TEST_TMPDIR/root" run --separate-stderr bash "$SCRIPT" --persist --story E90_S02 --projects-dir "$PROJECTS" --project-dir "$PROJ"
  [ "$status" -eq 10 ]
  [ -z "$output" ]
  [ "$(cat "$BATS_TEST_TMPDIR/root/project/board/tasks/E90_S02_T02_x.md")" = "$before" ]
}

@test "--list-transcripts and --check-layout are unaffected by a missing config (documented choice)" {
  mk_sub s1 a1 E90_S02_T02 m-a
  gone
  run --separate-stderr bash "$SCRIPT" --list-transcripts --projects-dir "$PROJECTS" --project-dir "$PROJ"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e 'length == 1' >/dev/null
  run --separate-stderr bash "$SCRIPT" --check-layout --projects-dir "$PROJECTS" --project-dir "$PROJ"
  [ "$status" -eq 0 ]
  grep -q "UNAFFECTED" "$SCRIPT"
}

@test "a model with no ratios is still unpriced and never guessed (config present)" {
  mk_sub s1 a1 E90_S02_T02 m-unknown
  run bash "$SCRIPT" --usage "$PROJECTS/$SLUG/s1/subagents/agent-a1.jsonl"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.cost_units == null and .unpriced_models == ["m-unknown"]' >/dev/null
}

@test "no optional-load wording for an E90 file remains in the four files" {
  run grep -n -i -E "only when present|loader or config (absent|available)|when the (loader|config) (is )?(absent|present)|price-ratio config is absent|cost mode off" \
    "$SCRIPT" "$WSU" "$PTU" "$REPO_ROOT/skills/j-close-story/SKILL.md"
  [ "$status" -eq 1 ]
}

@test "persist-task-usage.sh: a missing config prints one price-ratio WARNING and no per-task raw lines" {
  local root="$BATS_TEST_TMPDIR/proj"
  mkdir -p "$root/project/configs" "$root/project/board/tasks"
  cp "$REPO_ROOT/project/configs/workflow.json" "$root/project/configs/"
  git init -q "$root"; root="$(cd "$root" && pwd -P)"
  ln -s "$REPO_ROOT/scripts" "$root/scripts"; ln -s "$REPO_ROOT/skills" "$root/skills"
  printf -- '---\nid: E99_S01_T01\nstory_id: E99_S01\nstatus: Passed\nusage_total_tokens: 5\nusage_input_tokens: 1\n---\n' > "$root/project/board/tasks/E99_S01_T01_f.md"
  gone
  cd "$root"
  run --separate-stderr bash "$PTU" E99_S01
  [ "$status" -eq 0 ]
  [[ "$output" == *"WARNING: price-ratio dependency missing"* ]]
  [[ "$output" != *"total=5"* ]]
}

@test "write-story-usage.sh: a missing config reports not measured, price-ratio dependency missing, and writes nothing" {
  local root="$BATS_TEST_TMPDIR/proj2"
  mkdir -p "$root/project/configs" "$root/project/board/tasks" "$root/project/board/stories"
  cp "$REPO_ROOT/project/configs/workflow.json" "$root/project/configs/"
  git init -q "$root"; root="$(cd "$root" && pwd -P)"
  ln -s "$REPO_ROOT/scripts" "$root/scripts"; ln -s "$REPO_ROOT/skills" "$root/skills"
  printf -- '---\nid: E99_S01\nepic_id: E99\nstatus: In Progress\n---\n' > "$root/project/board/stories/E99_S01_f.md"
  before="$(cat "$root/project/board/stories/E99_S01_f.md")"
  gone
  cd "$root"
  run --separate-stderr bash "$WSU" E99_S01
  [ "$status" -eq 0 ]
  [[ "$output" == *"not measured: price-ratio dependency missing, nothing written"* ]]
  [ "$(cat "$root/project/board/stories/E99_S01_f.md")" = "$before" ]
}
