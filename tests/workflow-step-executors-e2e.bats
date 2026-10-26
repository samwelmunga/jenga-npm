#!/usr/bin/env bats
#
# E80_S03_T09: end-to-end proof that the step executors compose the way the j.workflow skill will drive them.
#
# The per-script suites (workflow-next-step, workflow-complete-step, workflow-step-confirm, ...) each cover one
# script. This file covers what only shows up when they are combined, through their public command lines only:
# run-state.sh start, then next-step.sh / complete-step.sh / step-confirm.sh, each in its own process.
#
#   1. a skill -> skill -> confirm-gate run, with a typed reference from step 2 to step 1's output, to `complete`
#   2. a failed step halts the run: `halted` forever, the gate is never dispatched (no skip-ahead)
#   3. a pending gate survives a new process and a new session (fresh environment)
#   4. a playbook step left in_progress is re-dispatched with "reinitialised": true
#   5. the pre-flight situation marker is untouched by every step type; no workflow script touches it
#
# Isolation: every test builds its own working-file tree under $BATS_TEST_TMPDIR, selects it with
# JENGA_PROJECT_ROOT and a fixture skills/playbooks tree with JENGA_PLAYBOOKS_TEST_ROOT, so this repository's own
# runs directory and board are never read or written. Assertions are on contract fields (signal, step_id, type,
# payload members), never on whole-object equality, so a later change to a payload's extra members cannot break them.
# This suite starts no nested bats run, so it needs no nested-suite skip.
#
# Mirror safety: depends only on scripts/workflow/*.sh, scripts/checklist-marker.sh, hooks/on_preflight_check.sh and
# fixtures it builds.

bats_require_minimum_version 1.5.0

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
WF="$REPO_ROOT/scripts/workflow"

setup() {
  unset WITH_LOCK_TIMEOUT_SECONDS WITH_LOCK_POLL_SECONDS WITH_LOCK_STALE_SECONDS JENGA_WORKFLOWS_TEST_ROOT
  command -v jq >/dev/null 2>&1 || skip "jq is not installed (the workflow scripts need it)"
  local s
  for s in run-state next-step complete-step step-confirm; do
    [ -f "$WF/$s.sh" ] || skip "scripts/workflow/$s.sh is not in this tree (the suite exercises it)"
  done
  mkdir -p "$BATS_TEST_TMPDIR/anchor/project/configs" "$BATS_TEST_TMPDIR/anchor/project/.workflows"
  printf '{"paths":{}}\n' > "$BATS_TEST_TMPDIR/anchor/project/configs/workflow.json"
  ANCHOR="$(cd "$BATS_TEST_TMPDIR/anchor" && pwd)"
  RUNS="$ANCHOR/project/data/workflow-runs"
  export JENGA_PROJECT_ROOT="$ANCHOR"
  export JENGA_CHECKLIST_SESSION_ID="e2e-session-one"
  cd "$BATS_TEST_TMPDIR" || return 1

  # fixture skills and playbooks: skills alpha/beta (and the j-alpha spelling the skill step resolves), playbook "chain".
  FIX="$BATS_TEST_TMPDIR/fix"
  mkdir -p "$FIX/skills/j-alpha" "$FIX/skills/jenga/playbooks"
  printf -- '---\nname: j.alpha\ndescription: fixture skill.\nmetadata:\n  prefered_agent: developer\n---\n# alpha\n' > "$FIX/skills/j-alpha/SKILL.md"
  local n
  for n in alpha beta; do
    mkdir -p "$FIX/skills/$n"
    printf -- '---\nname: j.%s\ndescription: fixture skill.\n---\n# %s\n' "$n" "$n" > "$FIX/skills/$n/SKILL.md"
  done
  cat > "$FIX/skills/jenga/playbooks/chain.json" <<'JSON'
{"id": "chain", "name": "Fixture chain", "description": "fixture playbook", "keywords": ["fixture"],
 "examples": ["fixture example"], "steps": ["alpha", "beta"]}
JSON
  # verify-output.sh resolves its validator and type registry under the same override root: link them (read only)
  ln -s "$REPO_ROOT/scripts" "$FIX/scripts"
  ln -s "$REPO_ROOT/templates" "$FIX/templates"
  export JENGA_PLAYBOOKS_TEST_ROOT="$FIX"

  cat > "$ANCHOR/project/.workflows/e2e.json" <<'JSON'
{
  "id": "e2e",
  "name": "End to end fixture",
  "description": "Fixture.",
  "steps": [
    {"id": "first", "type": "skill", "skill": "j.alpha",
     "outputs": [{"name": "found", "kind": "data", "type": "text"}]},
    {"id": "second", "type": "skill", "skill": "j.alpha", "args": {"from_first": "${steps.first.outputs.found}"}},
    {"id": "gate", "type": "confirm", "prompt": "Ship ${steps.first.outputs.found}?", "options": ["Ship", "Hold"]}
  ]
}
JSON
  cat > "$ANCHOR/project/.workflows/pb.json" <<'JSON'
{
  "id": "pb",
  "name": "Playbook fixture",
  "description": "Fixture.",
  "steps": [
    {"id": "play", "type": "playbook", "playbook": "chain"},
    {"id": "after", "type": "skill", "skill": "j.alpha"}
  ]
}
JSON
}

# ns / cs / sc: one script per call, each in its own process; stdout in $output, stderr in $stderr.
ns() { run --separate-stderr bash "$WF/next-step.sh" "$RUN"; }
cs() { run --separate-stderr bash "$WF/complete-step.sh" "$RUN" "$@"; }
sc() { run --separate-stderr bash "$WF/step-confirm.sh" "$@"; }

# o <jq expr>: the last stdout satisfies the expression.
o() {
  printf '%s' "$output" | jq -e "$1" >/dev/null || { echo "output: $output"; echo "does not satisfy: $1"; return 1; }
}

# start <workflow id>: starts a run through the public CLI and sets $RUN.
start() { RUN="$(bash "$WF/run-state.sh" start "$1")" && [ -n "$RUN" ]; }

# runst: the run's status, read from its state file.
runst() { jq -r .status "$RUNS/$RUN.json"; }

# marker_snap: the marker file's content, or the word "absent" when there is none. The path comes from the marker
# script itself so the test names no location.
marker_snap() {
  local p
  p="$(bash "$REPO_ROOT/scripts/checklist-marker.sh" path)" || { echo "no-marker-path"; return 0; }
  if [ -e "$p" ]; then cat "$p"; else echo "absent"; fi
}

# drive_to_gate: runs steps first and second to completion, then dispatches the gate. Leaves the run awaiting.
drive_to_gate() {
  ns; o '.signal == "step" and .step_id == "first"'
  cs first passed "release-42"; [ "$status" -eq 0 ]
  ns; o '.signal == "step" and .step_id == "second"'
  cs second passed; [ "$status" -eq 0 ]
  ns; o '.signal == "step" and .step_id == "gate" and .type == "confirm"'
}

@test "1. skill, skill, gate run: loops through the public scripts to complete with the cross-step reference substituted" {
  start e2e
  ns
  o '.signal == "step" and .step_id == "first" and .type == "skill" and .payload.skill == "j.alpha"'
  cs first passed "release-42"
  [ "$status" -eq 0 ]
  o '.status == "completed" and .step_id == "first"'

  ns
  o '.signal == "step" and .step_id == "second" and .type == "skill"'
  # the second step's input is the first step's output, substituted before dispatch
  o '.payload.args.from_first == "release-42"'
  [[ "$output" == *"release-42"* ]]
  cs second passed
  [ "$status" -eq 0 ]

  # the gate: the step signal carries the rendering, then the run waits
  ns
  o '.signal == "step" and .step_id == "gate" and .type == "confirm"'
  o '.payload.rendered | contains("release-42")'
  [ "$(runst)" = "awaiting_confirmation" ]
  ns
  o '.signal == "awaiting_confirmation" and .step_id == "gate"'

  # an invalid reply re-prompts (exit 3) and changes nothing; a valid reply completes the gate
  before="$(cksum < "$RUNS/$RUN.json")"
  sc reply "$RUN" gate "9"
  [ "$status" -eq 3 ]
  [[ "$output" == *"Ship"* ]]
  [ "$(cksum < "$RUNS/$RUN.json")" = "$before" ]
  [ "$(runst)" = "awaiting_confirmation" ]
  sc reply "$RUN" gate "1"
  [ "$status" -eq 0 ]
  o '.index == 1 and .option == "Ship"'
  [ "$(runst)" = "running" ]

  ns
  o '.signal == "complete"'
  [ "$(runst)" = "completed" ]
  ns
  o '.signal == "complete"'
}

@test "2. a failed step halts the run: halted every time, the gate is never dispatched" {
  start e2e
  ns; o '.signal == "step" and .step_id == "first"'
  cs first passed "release-42"
  ns; o '.signal == "step" and .step_id == "second"'
  cs second failed "skill reported an error"
  [ "$status" -eq 0 ]
  o '.status == "halted" and .step_id == "second"'

  local i
  for i in 1 2 3; do
    ns
    [ "$status" -eq 0 ]
    o '.signal == "halted" and .step_id == "second"'
  done
  [ "$(runst)" = "failed" ]
  # the gate step was never touched: still pending, no gate stored
  [ "$(jq -r '.steps[] | select(.id == "gate") | .status' "$RUNS/$RUN.json")" = "pending" ]
  [ "$(jq -r '.steps[] | select(.id == "first") | .status' "$RUNS/$RUN.json")" = "completed" ]
  sc status "$RUN"
  [ "$status" -eq 1 ]
}

@test "3. a pending gate survives a new process and a new session: read and answered from a fresh environment" {
  start e2e
  # process one: dispatch the gate, then the process ends
  bash -c "cd '$BATS_TEST_TMPDIR' && bash '$WF/next-step.sh' '$RUN' >/dev/null"   # first (in_progress)
  bash "$WF/complete-step.sh" "$RUN" first passed "release-42" >/dev/null
  bash "$WF/next-step.sh" "$RUN" >/dev/null
  bash "$WF/complete-step.sh" "$RUN" second passed >/dev/null
  bash -c "bash '$WF/next-step.sh' '$RUN'" >/dev/null
  [ "$(runst)" = "awaiting_confirmation" ]

  # process two: nothing inherited but PATH and the tree selector, a different session identity
  fresh() {
    env -i PATH="$PATH" JENGA_PROJECT_ROOT="$ANCHOR" JENGA_PLAYBOOKS_TEST_ROOT="$FIX" \
      CLAUDE_CODE_SESSION_ID="e2e-session-two" CLAUDE_SESSION_ID="e2e-session-two" JENGA_CHECKLIST_SESSION_ID="e2e-session-two" \
      bash "$@"
  }
  run fresh "$WF/next-step.sh" "$RUN"
  [ "$status" -eq 0 ]
  o '.signal == "awaiting_confirmation" and .step_id == "gate" and (.payload.rendered | contains("release-42"))'
  run fresh "$WF/step-confirm.sh" status "$RUN"
  [ "$status" -eq 0 ]
  o '.step_id == "gate"'
  run fresh "$WF/step-confirm.sh" reply "$RUN" gate "Hold"
  [ "$status" -eq 0 ]
  o '.index == 2 and .option == "Hold"'
  [ "$(runst)" = "running" ]
  run fresh "$WF/next-step.sh" "$RUN"
  o '.signal == "complete"'
}

@test "4. mid-playbook resume: a playbook step left in_progress is re-dispatched with reinitialised true" {
  start pb
  ns
  o '.signal == "step" and .step_id == "play" and .type == "playbook" and .payload.playbook_id == "chain" and .payload.reinitialised == false'
  [ "$(jq -r '.steps[] | select(.id == "play") | .status' "$RUNS/$RUN.json")" = "in_progress" ]
  # the session ends here: no report. A fresh process asks again.
  run --separate-stderr env -i PATH="$PATH" JENGA_PROJECT_ROOT="$ANCHOR" JENGA_PLAYBOOKS_TEST_ROOT="$FIX" bash "$WF/next-step.sh" "$RUN"
  [ "$status" -eq 0 ]
  o '.signal == "step" and .step_id == "play" and .type == "playbook"'
  o '.payload.playbook_id == "chain" and .payload.reinitialised == true and (.payload.steps | length) == 2'
  # and the run still finishes
  cs play passed
  [ "$status" -eq 0 ]
  ns; o '.signal == "step" and .step_id == "after"'
  cs after passed
  ns; o '.signal == "complete"'
}

@test "5. the pre-flight marker is untouched by every step type, whether absent or present" {
  local before after p
  # absent
  before="$(marker_snap)"
  [ "$before" = "absent" ]
  start e2e
  drive_to_gate
  sc reply "$RUN" gate "9"
  sc reply "$RUN" gate "1"
  ns; o '.signal == "complete"'
  start pb
  ns; o '.step_id == "play"'
  ns; o '.step_id == "play" and .payload.reinitialised == true'
  cs play passed
  after="$(marker_snap)"
  [ "$after" = "$before" ]

  # present: write a marker for a phase, snapshot it, run the whole flow again, compare byte for byte
  JENGA_CHECKLIST_MARKER_TTL_MINUTES=30 bash "$REPO_ROOT/scripts/checklist-marker.sh" write --situation pre-commit >/dev/null
  before="$(marker_snap)"
  [ "$before" != "absent" ]
  p="$(bash "$REPO_ROOT/scripts/checklist-marker.sh" path)"
  case "$p" in "$BATS_TEST_TMPDIR"/*) ;; *) echo "marker outside the fixture tree: $p"; return 1 ;; esac
  before="$(cksum < "$p")"
  start e2e
  drive_to_gate
  sc reply "$RUN" gate "1"
  ns; o '.signal == "complete"'
  start pb
  ns; ns; cs play passed
  after="$(cksum < "$p")"
  [ "$after" = "$before" ]
}

@test "5b. no workflow script invokes the marker or sets a hook-bypass variable, and the hook is unmodified" {
  local f
  for f in next-step complete-step step-confirm step-skill step-playbook step-state run-state resolve-refs; do
    [ -f "$WF/$f.sh" ] || continue
    run bash -c "grep -v -E '^[[:space:]]*#' '$WF/$f.sh' | grep -F -e 'checklist-marker' -e 'JENGA_CHECKLIST' -e 'on_preflight_check'"
    [ "$status" -eq 1 ] || { echo "$f.sh touches the marker or hook: $output"; return 1; }
    run bash -c "grep -v -E '^[[:space:]]*#' '$WF/$f.sh' | grep -E 'JENGA_[A-Z_]*(BYPASS|SKIP|DISABLE)'"
    [ "$status" -eq 1 ] || { echo "$f.sh sets a bypass variable: $output"; return 1; }
  done
  # hooks/on_preflight_check.sh is not modified by this work: identical to the tree's committed content
  if git -C "$REPO_ROOT" rev-parse --git-dir >/dev/null 2>&1 && git -C "$REPO_ROOT" ls-files --error-unmatch hooks/on_preflight_check.sh >/dev/null 2>&1; then
    run git -C "$REPO_ROOT" diff --quiet HEAD -- hooks/on_preflight_check.sh
    [ "$status" -eq 0 ]
  fi
}

@test "6. the test leaves this repository's own runs directory alone" {
  start e2e
  ns
  [ -f "$RUNS/$RUN.json" ]
  case "$RUNS" in "$BATS_TEST_TMPDIR"/*) ;; *) echo "runs dir outside the fixture: $RUNS"; return 1 ;; esac
  [ ! -e "$REPO_ROOT/project/data/workflow-runs/$RUN.json" ]
}
