#!/usr/bin/env bats
# bats file_tags=tier:integration
#
# tests/workflow-capture-review.bats - j.workflow-capture's review mode (E103_S01_T04)
#
# Pins:
#   1. render-review-table.sh renders a candidate-steps file deterministically (same input, same bytes), marks the
#      uncertain rows by the one rule in its header (flagged, no proposal, include without a type), handles an empty
#      list and a list with no uncertain row, prints one row in full, never prints a secret parameter's value, and
#      refuses a malformed file with exit 4 and nothing on stdout.
#   2. record-review.sh persists every include/exclude, step-type and parameter decision through record-answer.sh,
#      accept never overwrites a decision already made and refuses an uncertain row, pending lists what emission
#      still needs.
#   3. emit-workflow.sh emits a valid definition from those answers alone (no --answer, no re-judging).
#   4. record-answer.sh's new `parameters` kind: confirmed/none, the body shape, and refusal of anything else.
# All state lives under $BATS_TEST_TMPDIR; nothing here reads or writes the active-recording pointer.

bats_require_minimum_version 1.5.0
load helpers/assertions

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
RENDER="$REPO_ROOT/skills/j-workflow-capture/scripts/render-review-table.sh"
REVIEW="$REPO_ROOT/skills/j-workflow-capture/scripts/record-review.sh"
PROMPTS="$REPO_ROOT/skills/j-workflow-capture/assets/review-prompts.md"
RECORDER="$REPO_ROOT/skills/j-workflow-recorder/scripts"
RF="$RECORDER/recording-file.sh"
RA="$RECORDER/record-answer.sh"
CLOSE="$RECORDER/close-recording.sh"
EMIT="$RECORDER/emit-workflow.sh"
VALIDATOR="$REPO_ROOT/scripts/workflow/validate-workflow.sh"

setup() {
  T="$BATS_TEST_TMPDIR"
  PROJ="$T/proj"
  mkdir -p "$PROJ/project/configs"
  printf '%s\n' '{"paths":{"workflows":"out/defs"}}' > "$PROJ/project/configs/workflow.json"
  DEFS="$PROJ/out/defs"
  REC="$T/ship-the-site_RECORDING.md"
  DEST="$DEFS/ship-the-site.json"
  CAND="$T/candidates.json"

  unset JENGA_WORKFLOWS_TEST_ROOT JENGA_RECORDING_DIR
  export JENGA_PROJECT_ROOT="$PROJ"
  export JENGA_RECORDER_NOW=2026-11-20T01:02:03Z
  export JENGA_RECORDING_STATE_DIR="$T/pointer-state"
  export JENGA_RECORDING_SESSION_ID="capture-review-$BATS_TEST_NUMBER"
}

# Four candidates: two certain includes (one with parameters, one of them secret), one flagged-uncertain exclude,
# one with no proposal at all.
write_candidates() {
  cat > "$CAND" <<'JSON'
{
  "candidate_steps_version": 1,
  "steps": [
    {"n": 1, "text": "/j-commit commit the staged work", "proposal": "include", "step_type": "skill", "parameters": []},
    {"n": 2, "text": "scripts/check-release-ready.sh --strict /opt/acme/site", "proposal": "include", "step_type": "compute",
     "parameters": [{"name": "site_dir", "value": "/opt/acme/site"}, {"name": "deploy_token", "secret": true}]},
    {"n": 3, "text": "what is the weather | anyway", "proposal": "exclude", "uncertain": true, "reason": "maybe a detour"},
    {"n": 4, "text": "Ask whether the build\nlooks right before shipping", "evidence": ["Bash: ls", {"tool": "Read"}]}
  ]
}
JSON
}

# A recording whose steps are the candidates, appended in row order (what the capture writer does).
write_recording() {
  bash "$RF" create --source pasted "$REC" "ship the site" >/dev/null
  bash "$RF" append "$REC" "/j-commit commit the staged work" >/dev/null
  bash "$RF" append "$REC" "scripts/check-release-ready.sh --strict /opt/acme/site" >/dev/null
  bash "$RF" append "$REC" "what is the weather | anyway" >/dev/null
  bash "$RF" append "$REC" "Ask whether the build looks right before shipping" >/dev/null
}

value_of() { bash "$RA" --value "$REC" "$1" "$2"; }

# ---------------------------------------------------------------------------------------------------------------
# Renderer
# ---------------------------------------------------------------------------------------------------------------

@test "the new scripts pass bash -n and handle --help with exit 0" {
  for s in "$RENDER" "$REVIEW"; do
    run bash -n "$s"
    [ "$status" -eq 0 ]
    run bash "$s" --help
    [ "$status" -eq 0 ]
    assert_output_contains "usage:"
  done
}

@test "the table has one row per candidate with the six columns and the summary line" {
  write_candidates
  run bash "$RENDER" "$CAND"
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "| # | Step | Proposed | Type | Parameters | Uncertain |" ]
  [ "${lines[1]}" = "|---|---|---|---|---|---|" ]
  [ "${lines[2]}" = "| 1 | /j-commit commit the staged work | include | skill | - |  |" ]
  [ "${lines[3]}" = "| 2 | scripts/check-release-ready.sh --strict /opt/acme/site | include | compute | site_dir=/opt/acme/site, deploy_token (secret) |  |" ]
  [ "${lines[4]}" = '| 3 | what is the weather \| anyway | exclude | - | - | yes: maybe a detour |' ]
  [ "${lines[5]}" = "| 4 | Ask whether the build looks right before shipping | ? | ? | ? | yes: no proposal yet |" ]
  [ "${lines[6]}" = "4 candidate steps; uncertain: 3, 4" ]
}

@test "rendering is deterministic: the same file gives the same bytes" {
  write_candidates
  bash "$RENDER" "$CAND" > "$T/a"
  bash "$RENDER" "$CAND" > "$T/b"
  cmp "$T/a" "$T/b"
  bash "$RENDER" --row 4 "$CAND" > "$T/c"
  bash "$RENDER" --row 4 "$CAND" > "$T/d"
  cmp "$T/c" "$T/d"
}

@test "--uncertain lists the uncertain rows: flagged, no proposal, include without a type" {
  write_candidates
  jq '.steps[0].step_type = null' "$CAND" > "$T/x.json"
  run bash "$RENDER" --uncertain "$T/x.json"
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf '1\n3\n4')" ]
}

@test "an empty candidate list renders a single message and has no uncertain rows" {
  printf '%s\n' '{"candidate_steps_version":1,"steps":[]}' > "$CAND"
  run bash "$RENDER" "$CAND"
  [ "$status" -eq 0 ]
  [ "$output" = "No candidate steps to review." ]
  run bash "$RENDER" --uncertain "$CAND"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "a list with no uncertain rows says none uncertain and --uncertain prints nothing" {
  write_candidates
  jq '.steps |= map(select(.n <= 2))' "$CAND" > "$T/x.json"
  run bash "$RENDER" "$T/x.json"
  [ "$status" -eq 0 ]
  [ "${lines[${#lines[@]}-1]}" = "2 candidate steps; none uncertain" ]
  assert_output_not_contains "yes"
  run bash "$RENDER" --uncertain "$T/x.json"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "--row prints one row in full, with its recording step id, text and evidence" {
  write_candidates
  run bash "$RENDER" --row 4 "$CAND"
  [ "$status" -eq 0 ]
  assert_output_contains "recording step: step-004"
  assert_output_contains "uncertain: yes: no proposal yet"
  assert_output_contains "evidence: 2 item(s)"
  assert_output_contains "  - Bash: ls"
  run bash "$RENDER" --row 9 "$CAND"
  [ "$status" -eq 5 ]
  run bash "$RENDER" --row 0 "$CAND"
  [ "$status" -eq 2 ]
}

@test "a long excerpt is cut to 72 characters with an ellipsis" {
  local long
  long="$(printf 'x%.0s' $(seq 1 100))"
  jq -n --arg t "$long" '{candidate_steps_version:1, steps:[{n:1, text:$t, proposal:"exclude"}]}' > "$CAND"
  run bash "$RENDER" "$CAND"
  [ "$status" -eq 0 ]
  [ "${lines[2]}" = "| 1 | $(printf 'x%.0s' $(seq 1 72))... | exclude | - | - |  |" ]
}

@test "a secret parameter is never rendered with a value, and one that carries a value is refused" {
  write_candidates
  run bash "$RENDER" "$CAND"
  assert_output_contains "deploy_token (secret)"
  jq '.steps[1].parameters[1].value = "s3cr3t-value"' "$CAND" > "$T/x.json"
  run --separate-stderr bash "$RENDER" "$T/x.json"
  [ "$status" -eq 4 ]
  [ -z "$output" ]
  [[ "$stderr" == *"deploy_token is secret and must not carry a value"* ]]
  [[ "$stderr" != *"s3cr3t-value"* ]]
}

@test "a malformed file exits 4 with every problem on stderr and nothing on stdout" {
  printf '%s\n' '{"candidate_steps_version":1,"steps":[{"n":2,"text":"","proposal":"maybe","step_type":"comp"}]}' > "$CAND"
  run --separate-stderr bash "$RENDER" "$CAND"
  [ "$status" -eq 4 ]
  [ -z "$output" ]
  [[ "$stderr" == *"n must be 1"* ]]
  [[ "$stderr" == *"text must be a non-empty string"* ]]
  [[ "$stderr" == *"proposal must be include or exclude"* ]]
  [[ "$stderr" == *"step_type must be one of"* ]]
  printf 'not json\n' > "$CAND"
  run bash "$RENDER" "$CAND"
  [ "$status" -eq 4 ]
  run bash "$RENDER" "$T/missing.json"
  [ "$status" -eq 3 ]
}

# ---------------------------------------------------------------------------------------------------------------
# Writer and emission
# ---------------------------------------------------------------------------------------------------------------

@test "decide maps include, exclude, type and params onto record-answer.sh kinds" {
  write_recording
  bash "$REVIEW" decide "$REC" 1 include >/dev/null
  bash "$REVIEW" decide "$REC" 3 exclude --note "a side errand" >/dev/null
  bash "$REVIEW" decide "$REC" 1 type skill >/dev/null
  bash "$REVIEW" decide "$REC" 2 params site_dir=/opt/acme/site deploy_token >/dev/null
  bash "$REVIEW" decide "$REC" 1 params none >/dev/null
  [ "$(value_of step-001 deviation)" = "in-process" ]
  [ "$(value_of step-003 deviation)" = "out-of-process" ]
  [ "$(value_of step-001 step-type)" = "skill" ]
  [ "$(value_of step-002 parameters)" = "confirmed" ]
  [ "$(value_of step-001 parameters)" = "none" ]
  run bash "$RA" --text "$REC" step-002 parameters
  assert_output_contains "site_dir=/opt/acme/site"
  assert_output_contains "deploy_token"
  run bash "$RA" --text "$REC" step-003 deviation
  assert_output_contains "a side errand"
}

@test "a second decision of the same kind needs --replace, which corrects it" {
  write_recording
  bash "$REVIEW" decide "$REC" 2 type compute >/dev/null
  run bash "$REVIEW" decide "$REC" 2 type confirm
  [ "$status" -eq 7 ]
  [ "$(value_of step-002 step-type)" = "compute" ]
  bash "$REVIEW" decide "$REC" 2 type confirm --replace >/dev/null
  [ "$(value_of step-002 step-type)" = "confirm" ]
}

@test "decide refuses an unknown decision, a bad row and a row with no step" {
  write_recording
  run bash "$REVIEW" decide "$REC" 1 maybe
  [ "$status" -eq 2 ]
  run bash "$REVIEW" decide "$REC" x include
  [ "$status" -eq 2 ]
  run bash "$REVIEW" decide "$REC" 9 include
  [ "$status" -eq 5 ]
  run bash "$REVIEW" decide "$REC" 1 params "Bad Name=1"
  [ "$status" -eq 2 ]
}

@test "accept persists the proposals of the certain rows and keeps an earlier correction" {
  write_candidates
  write_recording
  bash "$REVIEW" decide "$REC" 1 type playbook >/dev/null
  run bash "$REVIEW" accept "$REC" "$CAND"
  [ "$status" -eq 0 ]
  assert_output_contains "$(printf '1\tstep-type\tkept playbook')"
  assert_output_contains "$(printf '2\tparameters\twritten confirmed')"
  [ "$(value_of step-001 step-type)" = "playbook" ]
  [ "$(value_of step-001 deviation)" = "in-process" ]
  [ "$(value_of step-001 parameters)" = "none" ]
  [ "$(value_of step-002 step-type)" = "compute" ]
  run bash "$RA" --text "$REC" step-002 parameters
  assert_output_contains "site_dir=/opt/acme/site"
  assert_output_contains "deploy_token"
  # uncertain rows are left for the walkthrough
  run bash "$RA" --value "$REC" step-003 deviation
  [ "$status" -eq 1 ]
  run bash "$RA" --value "$REC" step-004 deviation
  [ "$status" -eq 1 ]
}

@test "accept refuses a named uncertain row and writes nothing" {
  write_candidates
  write_recording
  cp "$REC" "$T/before"
  run bash "$REVIEW" accept "$REC" "$CAND" 1 3
  [ "$status" -eq 2 ]
  assert_output_contains "uncertain"
  cmp "$REC" "$T/before"
}

@test "pending lists what emission still needs, then nothing once every row is decided" {
  write_candidates
  write_recording
  bash "$REVIEW" accept "$REC" "$CAND" >/dev/null
  run bash "$REVIEW" pending "$REC" "$CAND"
  [ "$status" -eq 1 ]
  [ "$output" = "$(printf '3\tinclude or exclude\n4\tinclude or exclude')" ]
  bash "$REVIEW" decide "$REC" 3 exclude >/dev/null
  bash "$REVIEW" decide "$REC" 4 include >/dev/null
  run bash "$REVIEW" pending "$REC" "$CAND"
  [ "$status" -eq 1 ]
  [ "$output" = "$(printf '4\tstep type')" ]
  bash "$REVIEW" decide "$REC" 4 type confirm >/dev/null
  run bash "$REVIEW" pending "$REC" "$CAND"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "emit-workflow.sh emits a valid definition from the review answers alone" {
  write_candidates
  write_recording
  bash "$REVIEW" accept "$REC" "$CAND" >/dev/null
  bash "$REVIEW" decide "$REC" 3 exclude >/dev/null
  bash "$REVIEW" decide "$REC" 4 include >/dev/null
  bash "$REVIEW" decide "$REC" 4 type confirm >/dev/null
  bash "$CLOSE" "$REC" >/dev/null 2>&1
  run --separate-stderr bash "$EMIT" "$REC"
  [ "$status" -eq 0 ]
  [ "$output" = "$DEST" ]
  run bash "$VALIDATOR" "$DEST"
  [ "$status" -eq 0 ]
  [ "$(jq -r '[.steps[].id] | join(",")' "$DEST")" = "step_001,step_002,step_004" ]
  [ "$(jq -r '[.steps[].type] | join(",")' "$DEST")" = "skill,compute,confirm" ]
  [ "$(jq -r '.provenance.source' "$DEST")" = "pasted" ]
  # deterministic re-emission
  cp "$DEST" "$T/first.json"
  bash "$EMIT" "$REC" >/dev/null
  cmp "$DEST" "$T/first.json"
}

# ---------------------------------------------------------------------------------------------------------------
# record-answer.sh: the parameters kind
# ---------------------------------------------------------------------------------------------------------------

@test "record-answer.sh accepts the parameters kind and refuses a malformed body" {
  write_recording
  run bash "$RA" "$REC" step-001 parameters no
  [ "$status" -eq 0 ]
  [ "$(value_of step-001 parameters)" = "none" ]
  printf 'a=1\na=2\n' > "$T/dup"
  run bash "$RA" "$REC" step-002 parameters - < "$T/dup"
  [ "$status" -eq 2 ]
  run bash "$RA" "$REC" step-002 parameters "Not-a-name"
  [ "$status" -eq 2 ]
  run bash "$RA" "$REC" step-002 parameters "empty="
  [ "$status" -eq 2 ]
  run bash "$RA" "$REC" step-002 vibe yes
  assert_output_contains "parameters"
}

# ---------------------------------------------------------------------------------------------------------------
# Prompts asset and isolation
# ---------------------------------------------------------------------------------------------------------------

@test "review-prompts.md defines the three prompts as numbered lists with free text last" {
  [ -f "$PROMPTS" ]
  grep -q '^## Prompt R1' "$PROMPTS"
  grep -q '^## Prompt R2' "$PROMPTS"
  grep -q '^## Prompt R3' "$PROMPTS"
  # every fenced prompt block ends its numbered list with an Other (describe below) option
  run awk '
    /^```/ { if (inblock) { if (last !~ /Other \(describe below\)/) bad++; inblock = 0 } else { inblock = 1; last = "" } ; next }
    inblock && /^[0-9]+\. / { last = $0 }
    END { print bad + 0 }
  ' "$PROMPTS"
  [ "$output" = "0" ]
}

@test "nothing added by the review mode references the active-recording pointer" {
  run grep -lE 'active-recording\.sh|active-recording[[:space:]]+(set|clear|refresh)' "$RENDER" "$REVIEW" "$PROMPTS"
  [ "$status" -eq 1 ]
  # non-vacuous: the files exist and are read
  [ -s "$RENDER" ] && [ -s "$REVIEW" ] && [ -s "$PROMPTS" ]
}
