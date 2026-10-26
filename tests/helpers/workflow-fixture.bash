#!/usr/bin/env bash
#
# Shared fixture project and process-isolation helpers for the workflow end-to-end suites (E80_S06_T03).
#
# Use (a test file loads BOTH helpers; this file does not source the assertions itself):
#
#     load helpers/assertions
#     load helpers/workflow-fixture
#
#     setup() { wf_setup; }
#     @test "..." {
#       RUN="$(wf_start)"
#       run wf_next "$RUN"
#       ...
#     }
#
# This is a .bash file, not a .bats file, so test discovery never runs it. It is meant to be `load`ed; sourcing it
# only defines functions and a few WF_* variables and changes nothing else. It is compatible with macOS bash 3.2
# (no mapfile, no associative arrays) and uses no bare `[[ ... ]]` statement (inert under bats; see
# tests/helpers/assertions.bash): every condition is `[ ... ]`, `case`, or an `if [[ ... ]]`.
#
# ---------------------------------------------------------------------------
# ISOLATION MODEL
# ---------------------------------------------------------------------------
# The repository this suite lives in is only READ. wf_setup copies the scripts, schema and fixtures a workflow run
# needs into a throwaway tree $PROJ under $BATS_TEST_TMPDIR; every script under test is then called from that copy,
# so nothing the scripts write (runs, artifacts, locks, the count log) lands in the real repo's board, queue, logs
# or project/data/. The scripts find their working-file root through scripts/resolve-root.sh, which honours
# JENGA_PROJECT_ROOT, so the tree is selected by that one variable.
#
# Every script call goes through wf_fresh: one `env -i` process, so "a later session" is a genuinely different
# process with its own CLAUDE_CODE_SESSION_ID and no inherited shell state. The only variables it sets:
#
#     PATH                       as the test has it
#     HOME                       as the test has it
#     JENGA_PROJECT_ROOT         $PROJ
#     JENGA_PLAYBOOKS_TEST_ROOT  $PROJ   (the catalog redirect, see below; the one extra variable)
#     CLAUDE_CODE_SESSION_ID     the session id the caller names
#
# wf_setup unsets the session variables the repo's other suites unset (CLAUDE_CODE_SESSION_ID, JENGA_SESSION_ID,
# CLAUDE_SESSION_ID) plus JENGA_WORKFLOWS_TEST_ROOT and the WITH_LOCK_* timers, so the developer's real
# environment cannot leak into the test.
#
# ---------------------------------------------------------------------------
# CATALOG REDIRECTION (skills and playbooks)
# ---------------------------------------------------------------------------
# No script is modified for testing. The redirect is the existing E53 / E80_S03 test seam,
# JENGA_PLAYBOOKS_TEST_ROOT, which load-playbooks.sh, step-skill.sh and verify-output.sh already honour. Pointed at
# $PROJ it makes them read:
#
#     skills            $PROJ/skills                          (the stub skill j.stub-step lives in skills/j-stub-step/)
#     builtin playbooks $PROJ/skills/jenga/playbooks          (created empty)
#     project playbooks $PROJ/project/.playbooks              (the stub playbook stub-playbook is installed here)
#     type registry     $PROJ/templates/playbook-types.json
#     type validator    $PROJ/scripts/validate-typed-object.sh
#
# Independently of that variable, the copied scripts locate their siblings relative to their own directory
# (step-playbook.sh finds $PROJ/skills/jenga/scripts/load-playbooks.sh, lib.sh finds the package root, which is
# $PROJ because it holds templates/). So running the scripts from $PROJ is what makes the tree self-contained, and
# JENGA_PLAYBOOKS_TEST_ROOT is the single extra variable wf_fresh adds on top of the four the task names.
#
# ---------------------------------------------------------------------------
# FUNCTIONS
# ---------------------------------------------------------------------------
# wf_require <repo-relative path>
#     Skips the calling test, naming the path, when that file is not in this tree (so the suite also passes in the
#     public mirror, where some repo files are absent). Never passes silently. wf_setup calls it for everything it
#     copies.
# wf_setup
#     Builds $PROJ and exports PROJ and JENGA_PROJECT_ROOT for the test's own use. Also sets WF_SESSION to sess-a
#     and WF_ID to all-step-types, and changes into $PROJ. Installs, from tests/fixtures/workflow/:
#       all-step-types.json                -> $PROJ/project/.workflows/all-step-types.json
#       stubs/count-run.sh                 -> $PROJ/project/.workflows/scripts/count-run.sh   (executable)
#       stubs/templates/stub-report.md     -> $PROJ/project/.workflows/templates/stub-report.md
#       stubs/skills/j-stub-step/SKILL.md  -> $PROJ/skills/j-stub-step/SKILL.md
#       stubs/playbooks/stub-playbook.json -> $PROJ/project/.playbooks/stub-playbook.json
#     and, when present, templates/workflows/example-report* -> $PROJ/templates/workflows/.
# wf_fresh <session_id> <command...>
#     Runs the command with cwd $PROJ in a clean process (the environment listed above). Output and exit status are
#     the command's own, so `run wf_fresh sess-a bash "$PROJ/scripts/workflow/load-workflows.sh" lookup all-step-types`
#     works. Each call can name a different session id.
# wf_start [--input k=v ...]
#     run-state.sh start "$WF_ID" ...; prints the new run id. Session id: $WF_SESSION (default sess-a), read at
#     call time, so a test changes session between calls with `WF_SESSION=sess-b`.
# wf_next <run_id>
#     next-step.sh <run_id>.
# wf_complete <run_id> <step_id> <passed|failed> [value-or-note]
#     complete-step.sh <run_id> <step_id> ... (the step the test "executed" as the agent).
# wf_reply <run_id> <step_id> <raw reply>
#     step-confirm.sh reply ... (answers the pending gate of a confirm step; a confirm step is not completed through
#     wf_complete).
# wf_status <run_id>
#     run-state.sh status <run_id>.
# wf_script <name>
#     Prints the path of scripts/workflow/<name> inside $PROJ, for tests that call another workflow script
#     directly through wf_fresh.
#
# The wrappers hold no lifecycle logic: they only pick the script and pass the arguments through, so the suites
# exercise the shipped scripts.
#
# ---------------------------------------------------------------------------
# FIXTURE COMPUTE STUB
# ---------------------------------------------------------------------------
# count-run.sh <label> appends <label> to $PROJ/wf-count.log, prints a fixed id_list, and exits 1 while the file
# $PROJ/wf-fail-<label> exists. Create that file to inject a failure and delete it to "fix" it; nothing needs to
# travel through the environment into the compute child (it derives $PROJ from its own location).
# ---------------------------------------------------------------------------

WF_REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
WF_FIXTURES="$WF_REPO_ROOT/tests/fixtures/workflow"

wf_require() {
  if [ ! -e "$WF_REPO_ROOT/$1" ]; then
    skip "$1 is not in this tree"
  fi
}

wf_setup() {
  unset CLAUDE_CODE_SESSION_ID JENGA_SESSION_ID CLAUDE_SESSION_ID JENGA_WORKFLOWS_TEST_ROOT
  unset WITH_LOCK_TIMEOUT_SECONDS WITH_LOCK_POLL_SECONDS WITH_LOCK_STALE_SECONDS
  command -v jq >/dev/null 2>&1 || skip "jq is not installed (the workflow scripts need it)"
  command -v python3 >/dev/null 2>&1 || skip "python3 is not installed (the playbook loader needs it)"

  local f
  for f in scripts/workflow/lib.sh scripts/workflow/run-state.sh scripts/workflow/next-step.sh \
           scripts/workflow/complete-step.sh scripts/workflow/load-workflows.sh \
           scripts/workflow/validate-workflow.sh scripts/workflow/step-skill.sh scripts/workflow/step-playbook.sh \
           scripts/resolve-root.sh scripts/with-lock.sh scripts/validate-typed-object.sh \
           templates/workflow-schema.json templates/playbook-types.json \
           skills/jenga/scripts/load-playbooks.sh skills/jenga/scripts/run-playbook-step.sh \
           skills/jenga/scripts/render-playbook-confirmation.sh skills/jenga/scripts/match-playbook.sh \
           tests/fixtures/workflow/all-step-types.json tests/fixtures/workflow/stubs/count-run.sh \
           tests/fixtures/workflow/stubs/templates/stub-report.md \
           tests/fixtures/workflow/stubs/skills/j-stub-step/SKILL.md \
           tests/fixtures/workflow/stubs/playbooks/stub-playbook.json; do
    wf_require "$f"
  done

  mkdir -p "$BATS_TEST_TMPDIR/proj"
  PROJ="$(cd -P "$BATS_TEST_TMPDIR/proj" && pwd -P)"

  mkdir -p "$PROJ/scripts" "$PROJ/templates/workflows" "$PROJ/skills/jenga/scripts" "$PROJ/skills/jenga/playbooks" \
    "$PROJ/skills/j-stub-step" "$PROJ/project/configs" "$PROJ/project/.playbooks" \
    "$PROJ/project/.workflows/scripts" "$PROJ/project/.workflows/templates"

  # Read-only copies from the real repo.
  cp -R "$WF_REPO_ROOT/scripts/workflow" "$PROJ/scripts/workflow"
  cp "$WF_REPO_ROOT/scripts/resolve-root.sh" "$WF_REPO_ROOT/scripts/with-lock.sh" \
     "$WF_REPO_ROOT/scripts/validate-typed-object.sh" "$PROJ/scripts/"
  cp "$WF_REPO_ROOT/templates/workflow-schema.json" "$WF_REPO_ROOT/templates/playbook-types.json" "$PROJ/templates/"
  for f in load-playbooks.sh run-playbook-step.sh render-playbook-confirmation.sh match-playbook.sh; do
    cp "$WF_REPO_ROOT/skills/jenga/scripts/$f" "$PROJ/skills/jenga/scripts/$f"
  done
  # The example report workflow and its templates are optional (a sibling task adds them).
  for f in "$WF_REPO_ROOT"/templates/workflows/example-report*; do
    if [ -e "$f" ]; then
      cp -R "$f" "$PROJ/templates/workflows/"
    fi
  done

  # The minimal registry: only the three E80 path keys; everything else falls back to resolve-root.sh's defaults.
  cat > "$PROJ/project/configs/workflow.json" <<'JSON'
{
  "paths": {
    "workflows": "project/.workflows",
    "workflow_runs": "project/data/workflow-runs",
    "workflow_artifacts": "project/data/workflow-artifacts"
  }
}
JSON

  # The fixtures.
  cp "$WF_FIXTURES/all-step-types.json" "$PROJ/project/.workflows/all-step-types.json"
  cp "$WF_FIXTURES/stubs/count-run.sh" "$PROJ/project/.workflows/scripts/count-run.sh"
  chmod +x "$PROJ/project/.workflows/scripts/count-run.sh"
  cp "$WF_FIXTURES/stubs/templates/stub-report.md" "$PROJ/project/.workflows/templates/stub-report.md"
  cp "$WF_FIXTURES/stubs/skills/j-stub-step/SKILL.md" "$PROJ/skills/j-stub-step/SKILL.md"
  cp "$WF_FIXTURES/stubs/playbooks/stub-playbook.json" "$PROJ/project/.playbooks/stub-playbook.json"

  export PROJ
  export JENGA_PROJECT_ROOT="$PROJ"
  WF_SESSION="sess-a"
  WF_ID="all-step-types"
  cd "$PROJ" || return 1
}

wf_fresh() {
  local sid="$1"
  shift
  (
    cd "$PROJ" || exit 1
    exec env -i PATH="$PATH" HOME="${HOME:-/}" JENGA_PROJECT_ROOT="$PROJ" JENGA_PLAYBOOKS_TEST_ROOT="$PROJ" \
      CLAUDE_CODE_SESSION_ID="$sid" "$@"
  )
}

wf_script() { printf '%s\n' "$PROJ/scripts/workflow/$1"; }

wf_start() { wf_fresh "${WF_SESSION:-sess-a}" bash "$(wf_script run-state.sh)" start "${WF_ID:-all-step-types}" "$@"; }
wf_next() { wf_fresh "${WF_SESSION:-sess-a}" bash "$(wf_script next-step.sh)" "$@"; }
wf_complete() { wf_fresh "${WF_SESSION:-sess-a}" bash "$(wf_script complete-step.sh)" "$@"; }
wf_reply() { wf_fresh "${WF_SESSION:-sess-a}" bash "$(wf_script step-confirm.sh)" reply "$@"; }
wf_status() { wf_fresh "${WF_SESSION:-sess-a}" bash "$(wf_script run-state.sh)" status "$@"; }
