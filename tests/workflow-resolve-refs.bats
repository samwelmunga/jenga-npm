#!/usr/bin/env bats
#
# E80_S03_T03: scripts/workflow/resolve-refs.sh - substitutes ${inputs.<name>} and
# ${steps.<id>.outputs.<name>} references in one step of a workflow run and prints the step as JSON.
#
# Every test builds its own throwaway working-file tree under $BATS_TEST_TMPDIR, selects it with
# JENGA_PROJECT_ROOT, writes a fixture definition into <tree>/.workflows/, starts a real run with run-state.sh and
# moves its steps with step-state.sh, so the repository's own runs directory is never read or written. The real
# loader, validator and step-state.sh run against the repository's schema (read only).
#
# Escaping: the E80_S01 grammar defines no escape syntax, so resolve-refs.sh implements none (see the rapport
# E80_S03_T03-no-escape-syntax-in-grammar). The "escaping" tests below cover the two literal pass-throughs the
# grammar does define: a ${...} that is not a reference is emitted verbatim, and a substituted value that looks
# like a reference is not rescanned.
#
# Mirror safety: depends only on scripts/workflow/*.sh, scripts/*.sh, templates/ and fixtures it builds.

bats_require_minimum_version 1.5.0

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
SCRIPT="$REPO_ROOT/scripts/workflow/resolve-refs.sh"
STEP_STATE="$REPO_ROOT/scripts/workflow/step-state.sh"
RUN_STATE="$REPO_ROOT/scripts/workflow/run-state.sh"

setup() {
  unset WITH_LOCK_TIMEOUT_SECONDS WITH_LOCK_POLL_SECONDS WITH_LOCK_STALE_SECONDS JENGA_WORKFLOWS_TEST_ROOT
  mkdir -p "$BATS_TEST_TMPDIR/anchor/project/configs" "$BATS_TEST_TMPDIR/anchor/project/.workflows"
  printf '{"paths":{}}\n' > "$BATS_TEST_TMPDIR/anchor/project/configs/workflow.json"
  ANCHOR="$(cd "$BATS_TEST_TMPDIR/anchor" && pwd)"
  RUNS="$ANCHOR/project/data/workflow-runs"
  WFDIR="$ANCHOR/project/.workflows"
  export JENGA_PROJECT_ROOT="$ANCHOR"
  cd "$BATS_TEST_TMPDIR" || return 1
  demo_def > "$WFDIR/rr.json"
}

# demo_def: one workflow with a step per scenario. Steps use_* each carry exactly one runtime problem.
demo_def() {
  cat <<'JSON'
{
  "id": "rr",
  "name": "Reference fixture",
  "description": "Fixture.",
  "inputs": [
    {"name": "scope"},
    {"name": "tag", "default": "dflt"}
  ],
  "steps": [
    {"id": "survey", "type": "skill", "skill": "j.status", "args": {"scope": "${inputs.scope}"},
     "outputs": [{"name": "items", "kind": "data", "type": "id_list"}, {"name": "extra", "kind": "data", "type": "text"}]},
    {"id": "tidy", "type": "skill", "skill": "j.status", "outputs": [{"name": "o", "kind": "data", "type": "text"}]},
    {"id": "boom", "type": "skill", "skill": "j.status", "outputs": [{"name": "o", "kind": "data", "type": "text"}]},
    {"id": "pend", "type": "skill", "skill": "j.status", "outputs": [{"name": "o", "kind": "data", "type": "text"}]},
    {"id": "approve", "type": "confirm",
     "prompt": "Save ${steps.survey.outputs.items} for ${inputs.scope}? ${HOME} and ${steps.survey.outputs.items} again",
     "options": ["Save ${inputs.scope}", "Skip"]},
    {"id": "render", "type": "render", "template": "t.md",
     "inputs": {"scope": "${inputs.scope}", "list": "${steps.survey.outputs.items}"}},
    {"id": "plain", "type": "compute", "command": "echo ${HOME}", "args": ["a", "b"], "checkpoint": true},
    {"id": "use_unknown", "type": "confirm", "prompt": "tag is ${inputs.tag}", "options": ["ok"]},
    {"id": "use_skipped", "type": "confirm", "prompt": "from ${steps.tidy.outputs.o}", "options": ["ok"]},
    {"id": "use_failed", "type": "confirm", "prompt": "from ${steps.boom.outputs.o}", "options": ["ok"]},
    {"id": "use_pending", "type": "confirm", "prompt": "from ${steps.pend.outputs.o}", "options": ["ok"]},
    {"id": "use_unset", "type": "confirm", "prompt": "extra ${steps.survey.outputs.extra}", "options": ["ok"]},
    {"id": "use_mixed", "type": "confirm", "prompt": "${inputs.scope} then ${steps.tidy.outputs.o}", "options": ["ok"]},
    {"id": "use_extra", "type": "confirm", "prompt": "[${steps.survey.outputs.extra}]", "options": ["ok"]}
  ]
}
JSON
}

# new_run [--input k=v ...]: starts a run of rr (scope defaults to E80) and moves survey to completed with
# outputs items=E80_S01,E80_S02, tidy to skipped, boom to failed. Sets RUN.
new_run() {
  if [ "$#" -eq 0 ]; then
    set -- --input scope=E80
  fi
  RUN="$(bash "$RUN_STATE" start rr "$@")" || return 1
  bash "$STEP_STATE" set-output "$RUN" survey items "E80_S01,E80_S02" || return 1
  bash "$STEP_STATE" set-step "$RUN" survey completed || return 1
  bash "$STEP_STATE" set-step "$RUN" tidy skipped || return 1
  bash "$STEP_STATE" set-step "$RUN" boom failed || return 1
}

# mod <jq filter> [jq args]: rewrites the current run's state file directly, bypassing the scripts.
mod() {
  local filter="$1"
  shift
  jq "$@" "$filter" "$RUNS/$RUN.json" > "$RUNS/$RUN.json.new" && mv "$RUNS/$RUN.json.new" "$RUNS/$RUN.json"
}

# rr <args...>: runs the script with stdout ($output) and stderr ($stderr) captured separately.
rr() {
  run --separate-stderr bash "$SCRIPT" "$@"
}

# fails_cleanly <fragment>...: the last rr exited 1, printed nothing on stdout, and stderr contains each fragment.
fails_cleanly() {
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  local frag
  for frag in "$@"; do
    case "$stderr" in
      *"$frag"*) ;;
      *) printf 'stderr lacks %s; stderr was: %s\n' "$frag" "$stderr" >&2; return 1 ;;
    esac
  done
}

# ---------------------------------------------------------------------------
# shape
# ---------------------------------------------------------------------------

@test "script exists, is executable and passes bash -n" {
  [ -f "$SCRIPT" ]
  [ -x "$SCRIPT" ]
  run bash -n "$SCRIPT"
  [ "$status" -eq 0 ]
}

@test "header names the grammar source of truth, the loose-regex duplication, the exit codes and the no-escape fact" {
  local header
  header="$(grep -E '^#' "$SCRIPT")"
  [[ "$header" == *"templates/workflow-schema.json"* ]]
  [[ "$header" == *"substitution.pattern"* ]]
  [[ "$header" == *"reference_problems"* ]]
  [[ "$header" == *"NO escape syntax"* ]]
  local code
  for code in 0 1 2 3 4 5; do
    printf '%s\n' "$header" | grep -Eq "^#[[:space:]]+$code[[:space:]]"
  done
}

@test "no non-comment line names a project/ path literal and the schema pattern is not copied in" {
  run bash -c 'grep -v -E "^[[:space:]]*#" "$1" | grep -F "project/"' _ "$SCRIPT"
  [ "$status" -eq 1 ]
  run bash -c 'grep -v -E "^[[:space:]]*#" "$1" | grep -F "[a-z][a-z0-9_]*"' _ "$SCRIPT"
  [ "$status" -eq 1 ]
}

@test "sourcing prints nothing and creates nothing, even under set -u" {
  mkdir "$BATS_TEST_TMPDIR/empty"
  run --separate-stderr bash -c 'set -u; cd "$2" && . "$1" && type _rr_main >/dev/null && echo sourced-ok' _ "$SCRIPT" "$BATS_TEST_TMPDIR/empty"
  [ "$status" -eq 0 ]
  [ "$output" = "sourced-ok" ]
  [ -z "$stderr" ]
  [ -z "$(ls -A "$BATS_TEST_TMPDIR/empty")" ]
}

@test "usage: -h and --help print usage on stdout and exit 0" {
  rr -h
  [ "$status" -eq 0 ]
  [[ "$output" == *"Usage: resolve-refs.sh <run_id> <step_id>"* ]]
  rr --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"Usage: resolve-refs.sh"* ]]
}

@test "usage: no arguments, one argument and three arguments are exit 2 with usage on stderr" {
  rr
  [ "$status" -eq 2 ]
  [ -z "$output" ]
  [[ "$stderr" == *"Usage: resolve-refs.sh"* ]]
  rr onlyone
  [ "$status" -eq 2 ]
  rr a b c
  [ "$status" -eq 2 ]
  [ -z "$output" ]
}

# ---------------------------------------------------------------------------
# success
# ---------------------------------------------------------------------------

@test "success: a run input and an earlier step output are substituted everywhere, byte-identically on repeat" {
  new_run
  rr "$RUN" approve
  [ "$status" -eq 0 ]
  [ -z "$stderr" ]
  expected="$(jq -n -S '{id: "approve", type: "confirm",
    prompt: "Save E80_S01,E80_S02 for E80? ${HOME} and E80_S01,E80_S02 again",
    options: ["Save E80", "Skip"]}')"
  [ "$output" = "$expected" ]
  first="$output"
  rr "$RUN" approve
  [ "$status" -eq 0 ]
  [ "$output" = "$first" ]
  [ "$(bash "$SCRIPT" "$RUN" approve | cksum)" = "$(bash "$SCRIPT" "$RUN" approve | cksum)" ]
}

@test "success: strings in nested maps and arrays are substituted; outputs and structure are untouched" {
  new_run
  rr "$RUN" survey
  [ "$status" -eq 0 ]
  expected="$(jq -n -S '{id: "survey", type: "skill", skill: "j.status", args: {scope: "E80"},
    outputs: [{name: "items", kind: "data", type: "id_list"}, {name: "extra", kind: "data", type: "text"}]}')"
  [ "$output" = "$expected" ]
  rr "$RUN" render
  [ "$status" -eq 0 ]
  expected="$(jq -n -S '{id: "render", type: "render", template: "t.md", inputs: {scope: "E80", list: "E80_S01,E80_S02"}}')"
  [ "$output" = "$expected" ]
}

@test "success: a defaulted input that the run did not supply is substituted from the state" {
  new_run
  jq -e '.inputs.tag == "dflt"' "$RUNS/$RUN.json" >/dev/null
  rr "$RUN" use_unknown
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r .prompt)" = "tag is dflt" ]
}

@test "success: output keys are sorted" {
  new_run
  rr "$RUN" approve
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf '%s' "$output" | jq -S .)" ]
  [ "$(printf '%s\n' "$output" | grep -n -E '^  "(id|options|prompt|type)"' | sed 's/^[0-9]*:  "\([a-z]*\)".*/\1/' | tr '\n' ' ')" = "id options prompt type " ]
}

@test "success: a value with newlines, including trailing ones, is substituted exactly" {
  new_run
  bash "$STEP_STATE" set-output "$RUN" survey extra $'line1\nline2\n\n'
  rr "$RUN" use_extra
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -j .prompt | od -An -c | tr -d ' \n')" = "$(printf '[line1\nline2\n\n]' | od -An -c | tr -d ' \n')" ]
}

@test "success: a non-string input value is inserted as compact JSON" {
  new_run
  mod '.inputs.scope = {"a": [1, 2]}'
  rr "$RUN" approve
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r '.options[0]')" = 'Save {"a":[1,2]}' ]
}

@test "no references: the step prints unchanged, in key-sorted form, and a non-reference braces token stays verbatim" {
  new_run
  rr "$RUN" plain
  [ "$status" -eq 0 ]
  expected="$(jq -n -S '{id: "plain", type: "compute", command: "echo ${HOME}", args: ["a", "b"], checkpoint: true}')"
  [ "$output" = "$expected" ]
}

@test "escaping (no escape syntax in the grammar): a non-reference braces token is emitted verbatim next to a reference" {
  new_run
  rr "$RUN" approve
  [ "$status" -eq 0 ]
  [[ "$(printf '%s' "$output" | jq -r .prompt)" == *'? ${HOME} and '* ]]
}

@test "no re-scan: an input value that looks like a reference stays literal" {
  new_run --input 'scope=${inputs.tag}'
  rr "$RUN" approve
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r .prompt)" = 'Save E80_S01,E80_S02 for ${inputs.tag}? ${HOME} and E80_S01,E80_S02 again' ]
  [ "$(printf '%s' "$output" | jq -r '.options[0]')" = 'Save ${inputs.tag}' ]
}

@test "no re-scan: a step output that looks like a reference stays literal, even one that would fail" {
  new_run
  bash "$STEP_STATE" set-output "$RUN" survey items '${steps.tidy.outputs.o}${inputs.nope}'
  rr "$RUN" approve
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r .prompt)" = 'Save ${steps.tidy.outputs.o}${inputs.nope} for E80? ${HOME} and ${steps.tidy.outputs.o}${inputs.nope} again' ]
}

@test "no re-scan: a value that contains regex replacement syntax is inserted literally" {
  new_run
  bash "$STEP_STATE" set-output "$RUN" survey items '\1 $1 & \0'
  rr "$RUN" approve
  [ "$status" -eq 0 ]
  [[ "$(printf '%s' "$output" | jq -r .prompt)" == 'Save \1 $1 & \0 for E80'* ]]
}

# ---------------------------------------------------------------------------
# the five failure cases: exit 1, reference and cause named, nothing on stdout
# ---------------------------------------------------------------------------

@test "failure: a reference to an unknown run input" {
  new_run
  mod 'del(.inputs.tag)'
  rr "$RUN" use_unknown
  fails_cleanly '${inputs.tag}' "no input named 'tag'"
}

@test "failure: a reference to a skipped step" {
  new_run
  rr "$RUN" use_skipped
  fails_cleanly '${steps.tidy.outputs.o}' 'skipped'
}

@test "failure: a reference to a failed step" {
  new_run
  rr "$RUN" use_failed
  fails_cleanly '${steps.boom.outputs.o}' 'failed'
}

@test "failure: a reference to a step that has not completed yet (pending, then in_progress)" {
  new_run
  rr "$RUN" use_pending
  fails_cleanly '${steps.pend.outputs.o}' 'has not completed yet' 'pending'
  bash "$STEP_STATE" set-step "$RUN" pend in_progress
  rr "$RUN" use_pending
  fails_cleanly '${steps.pend.outputs.o}' 'has not completed yet' 'in_progress'
}

@test "failure: a reference to an output the completed step has not produced" {
  new_run
  rr "$RUN" use_unset
  fails_cleanly '${steps.survey.outputs.extra}' "no output named 'extra'"
}

@test "failure: one bad reference among good ones still prints nothing, not a partial result" {
  new_run
  rr "$RUN" use_mixed
  fails_cleanly '${steps.tidy.outputs.o}' 'skipped'
}

@test "failure: the state file is left byte-identical" {
  new_run
  before="$(cksum < "$RUNS/$RUN.json")"
  rr "$RUN" use_skipped
  [ "$status" -eq 1 ]
  rr "$RUN" approve
  [ "$status" -eq 0 ]
  [ "$(cksum < "$RUNS/$RUN.json")" = "$before" ]
}

# ---------------------------------------------------------------------------
# stubbed loader: definitions the real loader would refuse (defense in depth)
# ---------------------------------------------------------------------------

# stub_pkg <step json>: a copy of scripts/ whose load-workflows.sh lookup prints a one-step definition, so
# definitions that the validator would drop can still reach resolve-refs.sh. Sets STUB.
stub_pkg() {
  local pkg="$BATS_TEST_TMPDIR/pkg"
  mkdir -p "$pkg"
  cp -R "$REPO_ROOT/scripts" "$pkg/scripts"
  ln -s "$REPO_ROOT/templates" "$pkg/templates"
  jq -n --argjson step "$1" '{id: "rr", name: "n", description: "d", steps: [$step]}' > "$BATS_TEST_TMPDIR/stub-def.json"
  printf '#!/usr/bin/env bash\ncat "%s"\n' "$BATS_TEST_TMPDIR/stub-def.json" > "$pkg/scripts/workflow/load-workflows.sh"
  STUB="$pkg/scripts/workflow/resolve-refs.sh"
}

@test "failure: a malformed reference (loose token that fails the schema pattern) is exit 1 with nothing on stdout" {
  new_run
  stub_pkg '{"id":"survey","type":"confirm","prompt":"a ${inputs.Scope} b ${steps.survey.outputs} c ${inputs}","options":["ok"]}'
  run --separate-stderr bash "$STUB" "$RUN" survey
  fails_cleanly 'malformed reference' '${inputs.Scope}' '${steps.survey.outputs}' '${inputs}'
}

@test "failure: a reference to an output the step does not declare is exit 1 naming the reference" {
  new_run
  stub_pkg '{"id":"survey","type":"confirm","prompt":"x ${steps.survey.outputs.nope}","options":["ok"]}'
  run --separate-stderr bash "$STUB" "$RUN" survey
  fails_cleanly '${steps.survey.outputs.nope}' "no output named 'nope'"
}

@test "failure: a reference to a step the run does not have" {
  new_run
  stub_pkg '{"id":"survey","type":"confirm","prompt":"x ${steps.ghost.outputs.o}","options":["ok"]}'
  run --separate-stderr bash "$STUB" "$RUN" survey
  fails_cleanly '${steps.ghost.outputs.o}' "no step 'ghost'"
}

# ---------------------------------------------------------------------------
# other exit codes
# ---------------------------------------------------------------------------

@test "an unknown step is exit 2 with nothing on stdout" {
  new_run
  rr "$RUN" ghost
  [ "$status" -eq 2 ]
  [ -z "$output" ]
  [[ "$stderr" == *"ghost"* ]]
}

@test "an unknown run is exit 3 and an invalid run id is exit 2" {
  new_run
  rr no-such-run approve
  [ "$status" -eq 3 ]
  [ -z "$output" ]
  rr '../etc' approve
  [ "$status" -eq 2 ]
  [ -z "$output" ]
}

@test "a corrupt state file is exit 4 with nothing on stdout" {
  new_run
  printf 'not json' > "$RUNS/$RUN.json"
  rr "$RUN" approve
  [ "$status" -eq 4 ]
  [ -z "$output" ]
}

@test "a run whose workflow can no longer be looked up is exit 2" {
  new_run
  rm "$WFDIR/rr.json"
  rr "$RUN" approve
  [ "$status" -eq 2 ]
  [ -z "$output" ]
  [[ "$stderr" == *"rr"* ]]
}
