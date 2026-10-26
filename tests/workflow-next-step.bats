#!/usr/bin/env bats
#
# E80_S03_T07: scripts/workflow/next-step.sh - the dispatcher that answers "what do I do now" for a workflow run.
# It composes step-state.sh, resolve-refs.sh, step-skill.sh, step-playbook.sh and step-confirm.sh and prints one JSON
# object {signal, run_id, step_id, type, payload}.
#
# Every test builds its own throwaway working-file tree under $BATS_TEST_TMPDIR, selects it with JENGA_PROJECT_ROOT,
# writes a fixture definition into <tree>/.workflows/ and starts a real run with run-state.sh, so the repository's own
# runs directory is never read or written. A fixture skills/playbooks tree (JENGA_PLAYBOOKS_TEST_ROOT) gives
# step-skill.sh and step-playbook.sh something deterministic to resolve. All sibling scripts are the real ones.
#
# Mirror safety: depends only on scripts/workflow/*.sh, scripts/*.sh, templates/ and fixtures it builds.

bats_require_minimum_version 1.5.0

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
SCRIPT="$REPO_ROOT/scripts/workflow/next-step.sh"
STEP_STATE="$REPO_ROOT/scripts/workflow/step-state.sh"
RUN_STATE="$REPO_ROOT/scripts/workflow/run-state.sh"
CONFIRM="$REPO_ROOT/scripts/workflow/step-confirm.sh"

setup() {
  unset WITH_LOCK_TIMEOUT_SECONDS WITH_LOCK_POLL_SECONDS WITH_LOCK_STALE_SECONDS JENGA_WORKFLOWS_TEST_ROOT
  mkdir -p "$BATS_TEST_TMPDIR/anchor/project/configs" "$BATS_TEST_TMPDIR/anchor/project/.workflows"
  printf '{"paths":{}}\n' > "$BATS_TEST_TMPDIR/anchor/project/configs/workflow.json"
  ANCHOR="$(cd "$BATS_TEST_TMPDIR/anchor" && pwd)"
  RUNS="$ANCHOR/project/data/workflow-runs"
  export JENGA_PROJECT_ROOT="$ANCHOR"
  cd "$BATS_TEST_TMPDIR" || return 1

  # fixture skills and playbooks: skill j.alpha exists; playbook "chain" exists; "ghost" does not.
  FIX="$BATS_TEST_TMPDIR/fix"
  mkdir -p "$FIX/skills/j-alpha" "$FIX/skills/jenga/playbooks"
  printf -- '---\nname: j.alpha\ndescription: fixture skill.\nmetadata:\n  prefered_agent: developer\n---\n# alpha\n' > "$FIX/skills/j-alpha/SKILL.md"
  # the playbook loader validates a playbook's steps against skills/<name>/SKILL.md
  local n
  for n in alpha beta; do
    mkdir -p "$FIX/skills/$n"
    printf -- '---\nname: j.%s\ndescription: fixture skill.\n---\n# %s\n' "$n" "$n" > "$FIX/skills/$n/SKILL.md"
  done
  cat > "$FIX/skills/jenga/playbooks/chain.json" <<'JSON'
{"id": "chain", "name": "Fixture chain", "description": "fixture playbook", "keywords": ["fixture"],
 "examples": ["fixture example"], "steps": ["alpha", "beta"]}
JSON
  export JENGA_PLAYBOOKS_TEST_ROOT="$FIX"
}

# mk <steps json array>: writes the definition "nx" with those steps and starts a run, setting $RUN.
mk() {
  cat > "$ANCHOR/project/.workflows/nx.json" <<JSON
{
  "id": "nx",
  "name": "Next-step fixture",
  "description": "Fixture.",
  "inputs": [{"name": "scope", "default": "E80"}],
  "steps": $1
}
JSON
  RUN="$(bash "$RUN_STATE" start nx)" || return 1
}

# ns: runs next-step.sh on the current run; stdout in $output, stderr in $stderr, status in $status.
ns() {
  run --separate-stderr bash "$SCRIPT" "$RUN"
}

# o <jq expr>: the last output satisfies the expression (jq -e).
o() {
  printf '%s' "$output" | jq -e "$1" >/dev/null || { echo "output: $output"; echo "does not satisfy: $1"; return 1; }
}

# st <step_id>: prints that step's status in the current run.
st() {
  jq -r --arg s "$1" '.steps[] | select(.id == $s) | .status' "$RUNS/$RUN.json"
}

# runst: prints the run status.
runst() {
  jq -r '.status' "$RUNS/$RUN.json"
}

snap() {
  cksum < "$RUNS/$RUN.json"
}

SKILL_STEP='{"id": "a", "type": "skill", "skill": "j.alpha"}'
SKILL_B='{"id": "b", "type": "skill", "skill": "j.alpha", "args": {"zeta": "last", "alpha": "first"}}'
PB_STEP='{"id": "p", "type": "playbook", "playbook": "chain", "args": {"scope": "${inputs.scope}"}}'
CF_STEP='{"id": "c", "type": "confirm", "prompt": "Save ${inputs.scope}?", "options": ["Save", "Skip"]}'

# ---------------------------------------------------------------------------
# shape
# ---------------------------------------------------------------------------

@test "script exists, is executable and passes bash -n" {
  [ -f "$SCRIPT" ]
  [ -x "$SCRIPT" ]
  run bash -n "$SCRIPT"
  [ "$status" -eq 0 ]
}

@test "header documents every signal, every step type's payload, the reasons and exit codes 0 to 5" {
  local header word code
  header=$(sed -n '1,/^set -u$/p' "$SCRIPT")
  for word in halted paused cancelled complete awaiting_confirmation 'signal' skill playbook confirm compute render \
              deterministic_step_cap unknown_skill unknown_playbook unresolved_reference \
              'step-state.sh' 'resolve-refs.sh' 'step-skill.sh' 'step-playbook.sh' 'step-confirm.sh' reinitialised rendered; do
    printf '%s\n' "$header" | grep -qF -- "$word" || { echo "header lacks: $word"; return 1; }
  done
  for code in 0 1 2 3 4 5; do
    printf '%s\n' "$header" | grep -Eq "^#   $code  " || { echo "header lacks exit code $code"; return 1; }
  done
}

@test "the script names no project/ path and no consumer-install package path on a code line" {
  run bash -c "grep -v -E '^[[:space:]]*#' \"$SCRIPT\" | grep -F -e 'project/' -e 'node_modules/@jenga-ai/agent'"
  [ "$status" -eq 1 ]
}

@test "-h prints usage and exits 0; no arguments and extra arguments are usage errors (exit 2)" {
  run --separate-stderr bash "$SCRIPT" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"next-step.sh <run_id>"* ]]
  run --separate-stderr bash "$SCRIPT"
  [ "$status" -eq 2 ]
  [ -z "$output" ]
  run --separate-stderr bash "$SCRIPT" a b
  [ "$status" -eq 2 ]
}

@test "an unknown run is exit 3 and a corrupt state file is exit 4, each with nothing on stdout" {
  run --separate-stderr bash "$SCRIPT" no-such-run
  [ "$status" -eq 3 ]
  [ -z "$output" ]
  mk "[$SKILL_STEP]"
  printf 'not json' > "$RUNS/$RUN.json"
  ns
  [ "$status" -eq 4 ]
  [ -z "$output" ]
  [ "$(cat "$RUNS/$RUN.json")" = "not json" ]
}

@test "an invalid run id is a usage error (exit 2)" {
  run --separate-stderr bash "$SCRIPT" "../escape"
  [ "$status" -eq 2 ]
  [ -z "$output" ]
}

# ---------------------------------------------------------------------------
# skill, playbook, confirm
# ---------------------------------------------------------------------------

@test "a skill step returns signal step with the skill payload, prints one JSON line, and marks the step in_progress" {
  mk "[$SKILL_STEP]"
  ns
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | wc -l | tr -d ' ')" = "1" ]
  o ".signal == \"step\" and .run_id == \"$RUN\" and .step_id == \"a\" and .type == \"skill\""
  o '.payload.skill == "j.alpha" and .payload.invoke_as == "j.alpha" and .payload.instruction == "" and .payload.prefered_agent == "developer"'
  o '.payload.skill_path | endswith("SKILL.md")'
  [ "$(st a)" = "in_progress" ]
  [ "$(runst)" = "running" ]
}

@test "a skill step's args become a sorted key=value instruction and stay available as args" {
  mk "[$SKILL_B]"
  ns
  [ "$status" -eq 0 ]
  o '.payload.instruction == "alpha=first zeta=last"'
  o '.payload.args == {"alpha": "first", "zeta": "last"}'
}

@test "references in a skill step are substituted from run inputs and earlier step outputs" {
  mk '[{"id": "a", "type": "skill", "skill": "j.alpha", "outputs": [{"name": "out", "kind": "data", "type": "text"}]},
       {"id": "b", "type": "skill", "skill": "j.alpha", "args": {"x": "${steps.a.outputs.out}", "y": "${inputs.scope}"}}]'
  bash "$STEP_STATE" set-output "$RUN" a out "VALUE"
  bash "$STEP_STATE" set-step "$RUN" a completed
  ns
  [ "$status" -eq 0 ]
  o '.step_id == "b" and .payload.instruction == "x=VALUE y=E80"'
}

@test "a skill step already in_progress is returned again as the same action" {
  mk "[$SKILL_STEP]"
  ns
  local first="$output"
  ns
  [ "$status" -eq 0 ]
  [ "$output" = "$first" ]
  [ "$(st a)" = "in_progress" ]
}

@test "a playbook step returns the playbook payload and is marked in_progress" {
  mk "[$PB_STEP]"
  ns
  [ "$status" -eq 0 ]
  o '.signal == "step" and .step_id == "p" and .type == "playbook"'
  o '.payload.playbook_id == "chain" and .payload.name == "Fixture chain" and .payload.steps == ["alpha", "beta"] and .payload.reinitialised == false'
  o '.payload.args == {"scope": "E80"}'
  [ "$(st p)" = "in_progress" ]
}

@test "a playbook step already in_progress is dispatched with --resume (reinitialised true, with a note)" {
  mk "[$PB_STEP]"
  ns
  o '.payload.reinitialised == false'
  ns
  [ "$status" -eq 0 ]
  o '.signal == "step" and .payload.reinitialised == true and (.payload.note | test("first step"))'
  [ "$(st p)" = "in_progress" ]
}

@test "a confirm step returns the gate payload, persists the gate and moves the run to awaiting_confirmation" {
  mk "[$CF_STEP]"
  ns
  [ "$status" -eq 0 ]
  o '.signal == "step" and .step_id == "c" and .type == "confirm"'
  o '.payload.prompt == "Save E80?" and .payload.options == ["Save", "Skip", "Other (describe below)"]'
  o '.payload.rendered == "Save E80?\n\n1. Save\n2. Skip\n3. Other (describe below)"'
  [ "$(st c)" = "in_progress" ]
  [ "$(runst)" = "awaiting_confirmation" ]
  bash "$CONFIRM" status "$RUN" >/dev/null
}

@test "a pending gate returns awaiting_confirmation with the same stored rendering on every call" {
  mk "[$CF_STEP, $SKILL_STEP]"
  ns
  local rendered
  rendered=$(printf '%s' "$output" | jq -r '.payload.rendered')
  ns
  [ "$status" -eq 0 ]
  o '.signal == "awaiting_confirmation" and .step_id == "c" and .type == "confirm"'
  [ "$(printf '%s' "$output" | jq -r '.payload.rendered')" = "$rendered" ]
  local before="$output" sum
  sum=$(snap)
  ns
  ns
  [ "$output" = "$before" ]
  [ "$(snap)" = "$sum" ]
  [ "$(st a)" = "pending" ]
}

@test "after the gate is answered the next call dispatches the following step" {
  mk "[$CF_STEP, $SKILL_STEP]"
  ns
  bash "$CONFIRM" reply "$RUN" c 1 >/dev/null
  ns
  [ "$status" -eq 0 ]
  o '.signal == "step" and .step_id == "a" and .type == "skill"'
  [ "$(st c)" = "completed" ]
}

@test "awaiting_confirmation with no stored gate is a defined error, not a crash" {
  mk "[$SKILL_STEP]"
  bash "$STEP_STATE" set-step "$RUN" a in_progress
  bash "$RUN_STATE" await-confirmation "$RUN" a >/dev/null
  ns
  [ "$status" -eq 0 ]
  o '.signal == "error" and .reason == "awaiting_confirmation_without_gate"'
}

# compute and render steps are executed by next-step.sh itself (E80_S04_T08): see
# tests/workflow-dispatch-compute-render.bats. The two 'not implemented' assertions that stood here were removed.

# ---------------------------------------------------------------------------
# run lifecycle signals
# ---------------------------------------------------------------------------

@test "a failed run returns halted with the failed step and note, and never dispatches a later step" {
  mk "[$SKILL_STEP, $SKILL_B]"
  bash "$RUN_STATE" step "$RUN" a in_progress >/dev/null
  bash "$RUN_STATE" step "$RUN" a failed --note "boom happened" >/dev/null
  [ "$(runst)" = "failed" ]
  local sum first
  sum=$(snap)
  ns
  [ "$status" -eq 0 ]
  o '.signal == "halted" and .step_id == "a" and .type == "skill" and .payload.failed_step == "a" and .payload.note == "boom happened"'
  first="$output"
  ns
  ns
  ns
  [ "$output" = "$first" ]
  [ "$(st b)" = "pending" ]
  [ "$(snap)" = "$sum" ]
}

@test "a failed step in a run that is running again (a retry) is dispatched like a pending one" {
  mk "[$SKILL_STEP]"
  bash "$STEP_STATE" set-step "$RUN" a failed
  ns
  [ "$status" -eq 0 ]
  o '.signal == "step" and .step_id == "a"'
  [ "$(st a)" = "in_progress" ]
}

@test "a paused run returns paused and dispatches nothing" {
  mk "[$SKILL_STEP]"
  bash "$RUN_STATE" pause "$RUN" >/dev/null
  local sum
  sum=$(snap)
  ns
  [ "$status" -eq 0 ]
  o '.signal == "paused" and .run_id == "'"$RUN"'" and .step_id == null'
  [ "$(st a)" = "pending" ]
  [ "$(snap)" = "$sum" ]
}

@test "a cancelled run returns cancelled and dispatches nothing" {
  mk "[$SKILL_STEP]"
  bash "$RUN_STATE" cancel "$RUN" >/dev/null
  local sum
  sum=$(snap)
  ns
  [ "$status" -eq 0 ]
  o '.signal == "cancelled"'
  [ "$(st a)" = "pending" ]
  [ "$(snap)" = "$sum" ]
}

@test "when every step is terminal it returns complete and sets the run to completed" {
  mk "[$SKILL_STEP, $SKILL_B]"
  bash "$STEP_STATE" set-step "$RUN" a completed
  bash "$STEP_STATE" set-step "$RUN" b skipped
  ns
  [ "$status" -eq 0 ]
  o '.signal == "complete" and .step_id == null'
  [ "$(runst)" = "completed" ]
  jq -e '.history[-1].to == "completed"' "$RUNS/$RUN.json" >/dev/null
  ns
  [ "$status" -eq 0 ]
  o '.signal == "complete"'
  [ "$(runst)" = "completed" ]
}

# ---------------------------------------------------------------------------
# handler and resolver failures
# ---------------------------------------------------------------------------

@test "an unknown skill returns the unknown_skill error and leaves the step pending" {
  mk '[{"id": "a", "type": "skill", "skill": "j.nosuchskill"}]'
  ns
  [ "$status" -eq 0 ]
  o '.signal == "error" and .reason == "unknown_skill" and .step_id == "a" and .type == "skill" and (.payload.message | test("nosuchskill"))'
  [ "$(st a)" = "pending" ]
  [ "$(runst)" = "running" ]
  jq -e '.steps[] | select(.id == "a") | .started_at == null and .finished_at == null' "$RUNS/$RUN.json" >/dev/null
  ns
  o '.reason == "unknown_skill"'
  [ "$(st a)" = "pending" ]
}

@test "an unknown playbook returns the unknown_playbook error and leaves the step pending" {
  mk '[{"id": "p", "type": "playbook", "playbook": "ghost"}]'
  ns
  [ "$status" -eq 0 ]
  o '.signal == "error" and .reason == "unknown_playbook" and .step_id == "p" and .type == "playbook"'
  [ "$(st p)" = "pending" ]
  [ "$(runst)" = "running" ]
}

@test "a reference to a skipped step returns unresolved_reference and leaves the step pending" {
  mk '[{"id": "a", "type": "skill", "skill": "j.alpha", "outputs": [{"name": "out", "kind": "data", "type": "text"}]},
       {"id": "b", "type": "skill", "skill": "j.alpha", "args": {"x": "${steps.a.outputs.out}"}}]'
  bash "$STEP_STATE" set-step "$RUN" a skipped
  local sum
  sum=$(snap)
  ns
  [ "$status" -eq 0 ]
  o '.signal == "error" and .reason == "unresolved_reference" and .step_id == "b" and (.payload.message | test("skipped"))'
  [ "$(st b)" = "pending" ]
  [ "$(snap)" = "$sum" ]
}

@test "a reference to an output the completed step never produced returns unresolved_reference" {
  mk '[{"id": "a", "type": "skill", "skill": "j.alpha", "outputs": [{"name": "out", "kind": "data", "type": "text"}]},
       {"id": "b", "type": "skill", "skill": "j.alpha", "args": {"x": "${steps.a.outputs.out}"}}]'
  bash "$STEP_STATE" set-step "$RUN" a completed
  ns
  [ "$status" -eq 0 ]
  o '.signal == "error" and .reason == "unresolved_reference" and .step_id == "b"'
  [ "$(st b)" = "pending" ]
}

@test "a handler failure after a good step leaves the run usable: fixing the catalog lets the same call succeed" {
  mk '[{"id": "a", "type": "skill", "skill": "j.later"}]'
  ns
  o '.reason == "unknown_skill"'
  mkdir -p "$FIX/skills/j-later"
  printf -- '---\nname: j.later\ndescription: now present.\n---\n# later\n' > "$FIX/skills/j-later/SKILL.md"
  ns
  [ "$status" -eq 0 ]
  o '.signal == "step" and .payload.skill == "j.later"'
  [ "$(st a)" = "in_progress" ]
}

# ---------------------------------------------------------------------------
# ordering and re-dispatch guarantees
# ---------------------------------------------------------------------------

@test "a completed step is never dispatched again and its record is untouched" {
  mk "[$SKILL_STEP, $SKILL_B]"
  ns
  o '.step_id == "a"'
  bash "$STEP_STATE" set-step "$RUN" a completed
  local before
  before=$(jq -c '.steps[] | select(.id == "a")' "$RUNS/$RUN.json")
  ns
  o '.signal == "step" and .step_id == "b"'
  ns
  o '.signal == "step" and .step_id == "b"'
  [ "$(jq -c '.steps[] | select(.id == "a")' "$RUNS/$RUN.json")" = "$before" ]
  [ "$(st a)" = "completed" ]
}

@test "the steps of a mixed run are served one at a time in definition order" {
  mk "[$SKILL_STEP, $PB_STEP, $CF_STEP]"
  ns; o '.step_id == "a"'
  bash "$STEP_STATE" set-step "$RUN" a completed
  ns; o '.step_id == "p"'
  [ "$(st c)" = "pending" ]
  bash "$STEP_STATE" set-step "$RUN" p completed
  ns; o '.step_id == "c" and .type == "confirm"'
  bash "$CONFIRM" reply "$RUN" c 2 >/dev/null
  ns; o '.signal == "complete"'
  [ "$(runst)" = "completed" ]
}

@test "no temporary files are left behind" {
  mk "[$SKILL_STEP]"
  local tmp="$BATS_TEST_TMPDIR/tmp"
  mkdir -p "$tmp"
  TMPDIR="$tmp" bash "$SCRIPT" "$RUN" >/dev/null
  [ -z "$(ls -A "$tmp")" ]
}
