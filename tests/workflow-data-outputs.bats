#!/usr/bin/env bats
#
# E80_S04_T09: scripts/workflow/complete-step.sh publishes the declared outputs of a passed step to the workflow
# output registry (scripts/workflow/artifacts.sh register). kind data outputs are registered with the declared
# type; kind artifact outputs only when the skill step supplied an existing file path; a step with no outputs makes
# no registry call; a registry failure fails the step instead of completing it; a type violation fails before any
# registry write; a retried step replaces its own earlier record.
#
# Every test builds its own throwaway working-file tree under $BATS_TEST_TMPDIR and selects it with
# JENGA_PROJECT_ROOT, so the repository's own runs and registry are never read or written. The scripts are the
# real ones (complete-step.sh, artifacts.sh, step-state.sh, run-state.sh, verify-output.sh).
#
# Mirror safety: depends only on scripts/workflow/*.sh, scripts/*.sh, templates/ and fixtures it builds.

bats_require_minimum_version 1.5.0

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
SCRIPT="$REPO_ROOT/scripts/workflow/complete-step.sh"
ARTIFACTS="$REPO_ROOT/scripts/workflow/artifacts.sh"
STEP_STATE="$REPO_ROOT/scripts/workflow/step-state.sh"
RUN_STATE="$REPO_ROOT/scripts/workflow/run-state.sh"
RESOLVE="$REPO_ROOT/scripts/resolve-root.sh"

setup() {
  unset WITH_LOCK_TIMEOUT_SECONDS WITH_LOCK_POLL_SECONDS WITH_LOCK_STALE_SECONDS JENGA_WORKFLOWS_TEST_ROOT JENGA_PLAYBOOKS_TEST_ROOT JENGA_PLAYBOOK_TYPES_FILE
  mkdir -p "$BATS_TEST_TMPDIR/anchor/project/configs" "$BATS_TEST_TMPDIR/anchor/project/.workflows"
  printf '{"paths":{}}\n' > "$BATS_TEST_TMPDIR/anchor/project/configs/workflow.json"
  ANCHOR="$(cd "$BATS_TEST_TMPDIR/anchor" && pwd)"
  RUNS="$ANCHOR/project/data/workflow-runs"
  export JENGA_PROJECT_ROOT="$ANCHOR"
  AROOT="$(bash "$RESOLVE" get workflow_artifacts)"
  cd "$BATS_TEST_TMPDIR" || return 1
  cat > "$ANCHOR/project/.workflows/do.json" <<'JSON'
{
  "id": "do",
  "name": "Data-outputs fixture",
  "description": "Fixture.",
  "steps": [
    {"id": "ids", "type": "skill", "skill": "j.status",
     "outputs": [{"name": "ids", "kind": "data", "type": "id_list"}]},
    {"id": "plain", "type": "skill", "skill": "j.status"},
    {"id": "multi", "type": "skill", "skill": "j.status",
     "outputs": [{"name": "items", "kind": "data", "type": "id_list"}, {"name": "summary", "kind": "data", "type": "text"}]},
    {"id": "doc", "type": "skill", "skill": "j.status",
     "outputs": [{"name": "report", "kind": "artifact", "type": "text"}]},
    {"id": "mixed", "type": "skill", "skill": "j.status",
     "outputs": [{"name": "report", "kind": "artifact", "type": "text"}, {"name": "note", "kind": "data", "type": "text"}]}
  ]
}
JSON
  RUN="$(bash "$RUN_STATE" start do)" || return 1
}

# cs <args...>: runs the script with stdout ($output) and stderr ($stderr) captured separately.
cs() {
  run --separate-stderr bash "$SCRIPT" "$@"
}

# begin <step>: puts a step in_progress, as next-step.sh does when it hands the step out.
begin() {
  bash "$STEP_STATE" set-step "$RUN" "$1" in_progress
}

sstatus() {
  jq -r --arg s "$1" '.steps[] | select(.id == $s) | .status' "$RUNS/$RUN.json"
}

# records <name>: how many records the registry holds for <name> in the current run.
records() {
  bash "$ARTIFACTS" list --workflow do --run "$RUN" | jq --arg n "$1" '[.[] | select(.name == $n)] | length'
}

# ---------------------------------------------------------------------------
# kind data is published
# ---------------------------------------------------------------------------

@test "a data output is stored in run state and registered with kind data and the declared type" {
  begin ids
  cs "$RUN" ids passed "E1, E2"
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r .status)" = "completed" ]
  [ "$(sstatus ids)" = "completed" ]
  [ "$(jq -r '.steps[] | select(.id == "ids") | .outputs.ids' "$RUNS/$RUN.json")" = "$(printf 'E1\nE2')" ]
  run --separate-stderr bash "$ARTIFACTS" get do ids --run "$RUN"
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r .kind)" = "data" ]
  [ "$(printf '%s' "$output" | jq -r .type)" = "id_list" ]
  [ "$(printf '%s' "$output" | jq -r .step_id)" = "ids" ]
  run --separate-stderr bash "$ARTIFACTS" get do ids --run "$RUN" --path
  [ "$status" -eq 0 ]
  [ "$(cat "$output")" = "$(printf 'E1\nE2')" ]
  grep -qx 'E1' "$output"
  grep -qx 'E2' "$output"
}

@test "every data output of a multi-output step is registered" {
  begin multi
  cs "$RUN" multi passed '{"items":"E3,E4","summary":"two ids"}'
  [ "$status" -eq 0 ]
  [ "$(records items)" -eq 1 ]
  [ "$(records summary)" -eq 1 ]
  run --separate-stderr bash "$ARTIFACTS" get do items --run "$RUN" --path
  [ "$(cat "$output")" = "$(printf 'E3\nE4')" ]
  run --separate-stderr bash "$ARTIFACTS" get do summary --run "$RUN" --path
  [ "$(cat "$output")" = "two ids" ]
  [ "$(bash "$ARTIFACTS" get do summary --run "$RUN" | jq -r .type)" = "text" ]
}

@test "no temporary file is left behind after publishing" {
  mkdir -p "$BATS_TEST_TMPDIR/tmpd"
  begin ids
  TMPDIR="$BATS_TEST_TMPDIR/tmpd" cs "$RUN" ids passed "E1"
  [ "$status" -eq 0 ]
  [ -z "$(ls -A "$BATS_TEST_TMPDIR/tmpd")" ]
}

# ---------------------------------------------------------------------------
# a type violation fails before any registry write
# ---------------------------------------------------------------------------

@test "a value violating the declared type writes no record and no file" {
  begin ids
  cs "$RUN" ids passed "not an id"
  [ "$status" -eq 1 ]
  [ "$(sstatus ids)" = "in_progress" ]
  [ ! -e "$AROOT" ]
  [ "$(bash "$ARTIFACTS" list --workflow do | jq length)" -eq 0 ]
}

@test "one bad output of several writes nothing for the good one either" {
  begin multi
  cs "$RUN" multi passed '{"items":"nope","summary":"fine"}'
  [ "$status" -eq 1 ]
  [ ! -e "$AROOT" ]
}

# ---------------------------------------------------------------------------
# a registry failure fails the step
# ---------------------------------------------------------------------------

@test "a read-only artifacts directory leaves the step failed, not completed, with the registry error recorded" {
  [ "$(id -u)" -ne 0 ] || skip "root ignores directory permissions"
  mkdir -p "$AROOT"
  chmod 555 "$AROOT"
  begin ids
  cs "$RUN" ids passed "E1"
  chmod 755 "$AROOT"
  [ "$status" -eq 1 ]
  [ "$(printf '%s' "$output" | jq -r .status)" = "halted" ]
  [[ "$stderr" == *"could not be registered"* ]]
  [ "$(sstatus ids)" = "failed" ]
  [ "$(jq -r '.status' "$RUNS/$RUN.json")" = "failed" ]
  jq -e '.steps[] | select(.id == "ids") | .note | contains("registry") and contains("could not create")' "$RUNS/$RUN.json" >/dev/null
  [ "$(records ids)" -eq 0 ]
}

# ---------------------------------------------------------------------------
# no outputs: no registry call
# ---------------------------------------------------------------------------

@test "a step with no outputs makes no registry call and creates no registry directory" {
  begin plain
  cs "$RUN" plain passed
  [ "$status" -eq 0 ]
  [ "$(sstatus plain)" = "completed" ]
  [ ! -e "$AROOT" ]
}

# ---------------------------------------------------------------------------
# retry
# ---------------------------------------------------------------------------

@test "retrying a failed step with a data output succeeds and leaves exactly 1 record for that name" {
  [ "$(id -u)" -ne 0 ] || skip "root ignores directory permissions"
  mkdir -p "$AROOT"
  chmod 555 "$AROOT"
  begin ids
  cs "$RUN" ids passed "E1"
  chmod 755 "$AROOT"
  [ "$status" -eq 1 ]
  [ "$(sstatus ids)" = "failed" ]

  run --separate-stderr bash "$RUN_STATE" resume "$RUN"
  [ "$status" -eq 0 ]
  begin ids
  cs "$RUN" ids passed "E1, E7"
  [ "$status" -eq 0 ]
  [ "$(sstatus ids)" = "completed" ]
  [ "$(records ids)" -eq 1 ]
  run --separate-stderr bash "$ARTIFACTS" get do ids --run "$RUN" --path
  [ "$(cat "$output")" = "$(printf 'E1\nE7')" ]
}

@test "an earlier partial record of the same name does not block the step and is replaced" {
  printf 'E9\n' > "$BATS_TEST_TMPDIR/old.txt"
  bash "$ARTIFACTS" register do "$RUN" ids ids --kind data --type id_list --file "$BATS_TEST_TMPDIR/old.txt" >/dev/null
  [ "$(records ids)" -eq 1 ]
  begin ids
  cs "$RUN" ids passed "E1"
  [ "$status" -eq 0 ]
  [ "$(records ids)" -eq 1 ]
  run --separate-stderr bash "$ARTIFACTS" get do ids --run "$RUN" --path
  [ "$(cat "$output")" = "E1" ]
}

# ---------------------------------------------------------------------------
# kind artifact
# ---------------------------------------------------------------------------

@test "an artifact output is not registered when the value is not an existing file" {
  begin doc
  cs "$RUN" doc passed "no such file here"
  [ "$status" -eq 0 ]
  [ "$(sstatus doc)" = "completed" ]
  [ ! -e "$AROOT" ]
}

@test "an artifact output naming an existing file is registered with kind artifact" {
  printf '# Report\n' > "$BATS_TEST_TMPDIR/report.md"
  begin doc
  cs "$RUN" doc passed "$BATS_TEST_TMPDIR/report.md"
  [ "$status" -eq 0 ]
  [ "$(bash "$ARTIFACTS" get do report --run "$RUN" | jq -r .kind)" = "artifact" ]
  run --separate-stderr bash "$ARTIFACTS" get do report --run "$RUN" --path
  [ "$(cat "$output")" = "# Report" ]
}

@test "in a mixed step the data output is registered and the artifact without a file is not" {
  begin mixed
  cs "$RUN" mixed passed '{"report":"missing.md","note":"hello"}'
  [ "$status" -eq 0 ]
  [ "$(records note)" -eq 1 ]
  [ "$(records report)" -eq 0 ]
}
