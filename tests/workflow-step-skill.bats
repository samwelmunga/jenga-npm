#!/usr/bin/env bats
#
# E80_S03_T04: scripts/workflow/step-skill.sh validates a workflow skill step's skill against the skills catalog
# and prints the action payload the calling agent invokes.
#
# Every resolution case builds a fixture skills tree under $BATS_TEST_TMPDIR and points the script at it with
# JENGA_PLAYBOOKS_TEST_ROOT, so nothing here depends on which skills this repository ships. The two cases that
# use the real catalog (j.commit) only read skills/j-commit/SKILL.md.
#
# Mirror safety: depends only on scripts/workflow/step-skill.sh and fixtures it builds.

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
SCRIPT="$REPO_ROOT/scripts/workflow/step-skill.sh"

setup() {
  unset JENGA_PLAYBOOKS_TEST_ROOT JENGA_PROJECT_ROOT
  FIX="$BATS_TEST_TMPDIR/fix"
  mkdir -p "$FIX/skills"
}

# make_skill <skills dir> <directory name> <frontmatter name> [prefered_agent]
make_skill() {
  local dir="$1/$2"
  mkdir -p "$dir"
  {
    printf -- '---\nname: %s\ndescription: fixture skill\n' "$3"
    if [ -n "${4:-}" ]; then printf 'metadata:\n  prefered_agent: %s\n' "$4"; fi
    printf 'keywords:\n  - fixture\n---\n\n# Body\n'
  } > "$dir/SKILL.md"
}

# run_step <args...>: runs the script against the fixture root; sets $status, $out (stdout) and $errout (stderr).
run_step() {
  local errfile="$BATS_TEST_TMPDIR/stderr"
  status=0
  out="$(JENGA_PLAYBOOKS_TEST_ROOT="$FIX" bash "$SCRIPT" "$@" 2>"$errfile")" || status=$?
  errout="$(cat "$errfile")"
}

# --- AC1: exists, executable, syntax, documented -------------------------------------------------

@test "step-skill.sh exists, is executable and passes bash -n" {
  [ -f "$SCRIPT" ]
  [ -x "$SCRIPT" ]
  run bash -n "$SCRIPT"
  [ "$status" -eq 0 ]
}

@test "the header documents the output object and the exit codes" {
  local head
  head="$(sed -n '1,70p' "$SCRIPT")"
  for key in skill skill_path invoke_as instruction prefered_agent; do
    printf '%s' "$head" | grep -q "$key"
  done
  printf '%s' "$head" | grep -q 'EXIT CODES'
  printf '%s' "$head" | grep -Eq '^#   0 '
  printf '%s' "$head" | grep -Eq '^#   1 '
  printf '%s' "$head" | grep -Eq '^#   2 '
}

@test "--help prints usage on stdout and exits 0" {
  run bash "$SCRIPT" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"step-skill.sh <skill>"* ]]
}

# --- AC2: a real skill ---------------------------------------------------------------------------

@test "a real skill (j.commit) prints the payload with an existing skill_path" {
  run bash "$SCRIPT" j.commit "commit the work"
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r .skill)" = "j.commit" ]
  [ "$(printf '%s' "$output" | jq -r .invoke_as)" = "j.commit" ]
  [ "$(printf '%s' "$output" | jq -r .instruction)" = "commit the work" ]
  local p
  p="$(printf '%s' "$output" | jq -r .skill_path)"
  [ -f "$p" ]
  [ "${p##*/}" = "SKILL.md" ]
  [[ "$p" == */skills/j-commit/SKILL.md ]]
}

@test "the payload is a single JSON object with exactly the documented keys" {
  make_skill "$FIX/skills" j-alpha j.alpha
  run_step j.alpha
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$out" | wc -l | tr -d ' ')" -le 1 ]
  [ "$(printf '%s' "$out" | jq -r 'keys_unsorted | join(",")')" = "skill,skill_path,invoke_as,instruction,prefered_agent" ]
  [ "$(printf '%s' "$out" | jq -r .skill_path)" = "$FIX/skills/j-alpha/SKILL.md" ]
}

# --- AC3: prefered_agent -------------------------------------------------------------------------

@test "prefered_agent is taken from metadata.prefered_agent when present" {
  make_skill "$FIX/skills" j-alpha j.alpha developer
  run_step j.alpha
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$out" | jq -r .prefered_agent)" = "developer" ]
}

@test "prefered_agent is JSON null when absent" {
  make_skill "$FIX/skills" j-alpha j.alpha
  run_step j.alpha
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$out" | jq -c .prefered_agent)" = "null" ]
}

@test "a prefered_agent outside the metadata block is ignored" {
  mkdir -p "$FIX/skills/j-alpha"
  printf -- '---\nname: j.alpha\nprefered_agent: tester\nmetadata:\n  other: x\n---\n' > "$FIX/skills/j-alpha/SKILL.md"
  run_step j.alpha
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$out" | jq -c .prefered_agent)" = "null" ]
}

@test "a quoted frontmatter name and quoted prefered_agent are unquoted" {
  mkdir -p "$FIX/skills/j-alpha"
  printf -- '---\nname: "j.alpha"\nmetadata:\n  prefered_agent: "tester"\n---\n' > "$FIX/skills/j-alpha/SKILL.md"
  run_step j.alpha
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$out" | jq -r .prefered_agent)" = "tester" ]
}

# --- instruction ---------------------------------------------------------------------------------

@test "instruction is the empty string when no input text is given" {
  make_skill "$FIX/skills" j-alpha j.alpha
  run_step j.alpha
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$out" | jq -c .instruction)" = '""' ]
}

@test "input text with quotes and spaces round-trips verbatim" {
  make_skill "$FIX/skills" j-alpha j.alpha
  run_step j.alpha 'say "hi" and it'"'"'s $HOME'
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$out" | jq -r .instruction)" = 'say "hi" and it'"'"'s $HOME' ]
}

# --- AC4: the three failure branches -------------------------------------------------------------

@test "an unknown skill exits 1 with a message naming it and nothing on stdout" {
  run_step j.missing
  [ "$status" -eq 1 ]
  [ -z "$out" ]
  [[ "$errout" == *"j.missing"* ]]
  [[ "$errout" == *"skills/j-missing/SKILL.md"* ]]
}

@test "a directory without SKILL.md exits 1 with nothing on stdout" {
  mkdir -p "$FIX/skills/j-empty"
  run_step j.empty
  [ "$status" -eq 1 ]
  [ -z "$out" ]
  [[ "$errout" == *"j.empty"* ]]
  [[ "$errout" == *"j-empty/SKILL.md"* ]]
}

@test "a frontmatter name mismatch exits 1 with nothing on stdout" {
  make_skill "$FIX/skills" j-alpha j.other
  run_step j.alpha
  [ "$status" -eq 1 ]
  [ -z "$out" ]
  [[ "$errout" == *"j.alpha"* ]]
  [[ "$errout" == *"j.other"* ]]
}

@test "a SKILL.md with no frontmatter exits 1" {
  mkdir -p "$FIX/skills/j-alpha"
  printf '# no frontmatter\nname: j.alpha\n' > "$FIX/skills/j-alpha/SKILL.md"
  run_step j.alpha
  [ "$status" -eq 1 ]
  [ -z "$out" ]
}

@test "a name: line in the body, outside the frontmatter, does not satisfy the check" {
  mkdir -p "$FIX/skills/j-alpha"
  printf -- '---\ndescription: x\n---\nname: j.alpha\n' > "$FIX/skills/j-alpha/SKILL.md"
  run_step j.alpha
  [ "$status" -eq 1 ]
  [ -z "$out" ]
}

@test "names that are not valid skill names exit 1 without looking outside the skills tree" {
  make_skill "$FIX" evil j.evil
  for bad in 'j.' 'j../evil' 'j.a/b' 'j.A' 'j.-x' 'commit' 'x.commit' '../evil'; do
    run_step "$bad"
    [ "$status" -eq 1 ]
    [ -z "$out" ]
    [[ "$errout" == *"unknown skill"* ]]
  done
}

@test "no skill argument is a usage error (exit 2) with nothing on stdout" {
  run_step
  [ "$status" -eq 2 ]
  [ -z "$out" ]
  [[ "$errout" == *"Usage"* ]]
}

# --- permanent bare-directory skills -------------------------------------------------------------

@test "jenga resolves to skills/jenga and reports the canonical name j.jenga" {
  make_skill "$FIX/skills" jenga j.jenga scrum-master
  run_step jenga
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$out" | jq -r .skill)" = "j.jenga" ]
  [ "$(printf '%s' "$out" | jq -r .invoke_as)" = "j.jenga" ]
  [ "$(printf '%s' "$out" | jq -r .skill_path)" = "$FIX/skills/jenga/SKILL.md" ]
}

@test "jenga-config and jenga-permission-level resolve to their bare directories, in either spelling" {
  make_skill "$FIX/skills" jenga-config j.jenga-config
  make_skill "$FIX/skills" jenga-permission-level j.jenga-permission-level
  for n in jenga-config jenga-permission-level; do
    for spelling in "$n" "j.$n"; do
      run_step "$spelling"
      [ "$status" -eq 0 ]
      [ "$(printf '%s' "$out" | jq -r .skill)" = "j.$n" ]
      [ "$(printf '%s' "$out" | jq -r .skill_path)" = "$FIX/skills/$n/SKILL.md" ]
    done
  done
}

@test "j.jenga does not resolve to a j-jenga directory" {
  make_skill "$FIX/skills" j-jenga j.jenga
  run_step j.jenga
  [ "$status" -eq 1 ]
  [ -z "$out" ]
}

# --- AC5: fallback and override ------------------------------------------------------------------

@test "the consumer-install fallback is used when the primary skills directory lacks the skill" {
  make_skill "$FIX/node_modules/@jenga-ai/agent/skills" j-consumer j.consumer tester
  run_step j.consumer
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$out" | jq -r .skill_path)" = "$FIX/node_modules/@jenga-ai/agent/skills/j-consumer/SKILL.md" ]
  [ "$(printf '%s' "$out" | jq -r .prefered_agent)" = "tester" ]
}

@test "the primary skills directory wins over the consumer-install fallback" {
  make_skill "$FIX/skills" j-both j.both
  make_skill "$FIX/node_modules/@jenga-ai/agent/skills" j-both j.both
  run_step j.both
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$out" | jq -r .skill_path)" = "$FIX/skills/j-both/SKILL.md" ]
}

@test "the test-root override replaces the real catalog: j.commit is unknown in an empty fixture" {
  run_step j.commit
  [ "$status" -eq 1 ]
  [ -z "$out" ]
}

@test "a trailing slash on the test root does not change the reported path" {
  make_skill "$FIX/skills" j-alpha j.alpha
  out="$(JENGA_PLAYBOOKS_TEST_ROOT="$FIX/" bash "$SCRIPT" j.alpha)"
  [ "$(printf '%s' "$out" | jq -r .skill_path)" = "$FIX/skills/j-alpha/SKILL.md" ]
}

# --- AC6: no run state, no marker ----------------------------------------------------------------

@test "the script references neither the situation marker script nor any run state file" {
  run grep -n -i -E 'checklist-marker|run-state|run_state|run state|\.runs' "$SCRIPT"
  [ "$status" -eq 1 ]
}

@test "running it creates nothing in the fixture" {
  make_skill "$FIX/skills" j-alpha j.alpha
  local before after
  before="$(cd "$FIX" && find . | LC_ALL=C sort)"
  run_step j.alpha "x"
  [ "$status" -eq 0 ]
  after="$(cd "$FIX" && find . | LC_ALL=C sort)"
  [ "$before" = "$after" ]
}
