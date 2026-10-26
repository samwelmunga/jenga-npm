#!/usr/bin/env bats
#
# E80_S05_T04: the script contract that skills/j-workflow/SKILL.md relies on (story E80_S05, covers its AC 9).
#
# The skill is only a driver: every transition, gate and state write happens in scripts/workflow/*.sh. This suite
# has two groups.
#
#   1. Protocol. A fixture workflow (skill step, confirmation gate, skill step) is driven ONLY through the scripts,
#      in the order SKILL.md specifies: run-state.sh start, then next-step.sh / complete-step.sh until the gate
#      (awaiting_confirmation); run-state.sh pause; next-step.sh refuses; run-state.sh resume in a fresh process
#      (a simulated new session); step-confirm.sh reply; finish to complete. Also: a `failed` completion halts the
#      run, and `cancel` ends a run so it cannot be advanced.
#   2. Conformance. The real skills/j-workflow/SKILL.md: frontmatter, directory name, the script paths it names,
#      the sub-commands it names, and that it never writes run state itself.
#
# Allow-list and catalog registration are E80_S05_T05 and are not checked here.
#
# Isolation: the protocol tests build a throwaway working-file tree under $BATS_TEST_TMPDIR (a relocated tree name,
# with the runs directory moved again by the paths config, so no conventional location is involved), select it with
# JENGA_PROJECT_ROOT and write the fixture definition into it. The repository's own runs and board are never read or
# written; the conformance tests only read repository files. Each script call is its own `env -i` process: no shell
# state survives between calls, as in separate Bash tool calls of the skill.

bats_require_minimum_version 1.5.0

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
WF="$REPO_ROOT/scripts/workflow"
SKILL_DIR="$REPO_ROOT/skills/j-workflow"
SKILL_MD="$SKILL_DIR/SKILL.md"

setup() {
  unset WITH_LOCK_TIMEOUT_SECONDS WITH_LOCK_POLL_SECONDS WITH_LOCK_STALE_SECONDS JENGA_WORKFLOWS_TEST_ROOT
}

# ---------------------------------------------------------------------------
# fixture and process helpers (protocol group)
# ---------------------------------------------------------------------------

# fixture: a relocated (dot-prefixed) working-file tree whose registry also moves the runs directory, holding the
# gate definition in the tree's own workflow directory; selects the tree for sc().
fixture() {
  command -v jq >/dev/null 2>&1 || skip "jq is not installed (the workflow scripts need it)"
  ANCHOR="$BATS_TEST_TMPDIR/anchor"
  TREE=".project"
  mkdir -p "$ANCHOR/$TREE/configs" "$ANCHOR/$TREE/.workflows"
  printf '{"paths":{"workflow_runs":".project/moved-runs"}}\n' > "$ANCHOR/$TREE/configs/workflow.json"
  cat > "$ANCHOR/$TREE/.workflows/gated.json" <<'JSON'
{
  "id": "gated",
  "name": "Gated fixture",
  "description": "A skill step, a confirmation gate, then a skill step.",
  "steps": [
    {"id": "first", "type": "skill", "skill": "j.status"},
    {"id": "gate", "type": "confirm", "prompt": "Continue?", "options": ["Yes", "No"]},
    {"id": "last", "type": "skill", "skill": "j.status"}
  ]
}
JSON
  ANCHOR="$(cd "$ANCHOR" && pwd)"
  RUNS="$ANCHOR/$TREE/moved-runs"
  export JENGA_PROJECT_ROOT="$ANCHOR"
  # Run from an unrelated directory so nothing can resolve the tree from the working directory.
  mkdir -p "$BATS_TEST_TMPDIR/cwd"
  cd "$BATS_TEST_TMPDIR/cwd" || return 1
}

# sc <script name> <args...>: one script call in its own process with a scrubbed environment (PATH and the tree
# selector only). stdout and stderr are captured separately ($output, $stderr, $status).
sc() {
  local name="$1"
  shift
  run --separate-stderr env -i PATH="$PATH" JENGA_PROJECT_ROOT="$JENGA_PROJECT_ROOT" bash "$WF/$name" "$@"
}

# start_run: starts a run of the fixture and sets RID.
start_run() {
  sc run-state.sh start gated
  [ "$status" -eq 0 ]
  RID="$output"
  [ -n "$RID" ]
  [ -f "$RUNS/$RID.json" ]
}

# sig: the `signal` of the last next-step.sh output, with the exit status checked.
sig() {
  [ "$status" -eq 0 ]
  printf '%s' "$output" | jq -r .signal
}

# run_status <run id>: the run's status as run-state.sh reports it.
run_status() {
  sc run-state.sh status "$1"
  [ "$status" -eq 0 ]
  printf '%s' "$output" | jq -r .status
}

# step_status <run id> <step id>: one step's status from the run state, read through the step-state.sh script.
step_status() {
  sc step-state.sh get "$1"
  [ "$status" -eq 0 ]
  printf '%s' "$output" | jq -r --arg s "$2" '[.steps[] | select(.id == $s)][0].status'
}

# ---------------------------------------------------------------------------
# group 1: the protocol as SKILL.md drives it
# ---------------------------------------------------------------------------

@test "protocol: start, step, gate, pause, refusal, fresh-session resume, reply, complete" {
  fixture
  start_run
  [ "$(run_status "$RID")" = "running" ]

  # Run loop, step 1: the first step is a skill step.
  sc next-step.sh "$RID"
  [ "$(sig)" = "step" ]
  [ "$(printf '%s' "$output" | jq -r '.step_id + " " + .type')" = "first skill" ]
  [ "$(printf '%s' "$output" | jq -r .payload.invoke_as)" = "j.status" ]
  sc complete-step.sh "$RID" first passed
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r .status)" = "completed" ]

  # The next step is the gate: the loop stops on it and never calls complete-step.sh for it.
  sc next-step.sh "$RID"
  [ "$(sig)" = "step" ]
  [ "$(printf '%s' "$output" | jq -r '.step_id + " " + .type')" = "gate confirm" ]
  [ "$(printf '%s' "$output" | jq -r .payload.rendered)" = $'Continue?\n\n1. Yes\n2. No\n3. Other (describe below)' ]
  [ "$(run_status "$RID")" = "awaiting_confirmation" ]
  sc next-step.sh "$RID"
  [ "$(sig)" = "awaiting_confirmation" ]
  sc complete-step.sh "$RID" gate passed
  [ "$status" -eq 1 ]
  [ "$(run_status "$RID")" = "awaiting_confirmation" ]

  # Pause with the gate pending: the state says paused and next-step.sh refuses to dispatch anything.
  sc run-state.sh pause "$RID"
  [ "$status" -eq 0 ]
  [ "$output" = "paused" ]
  [ "$(run_status "$RID")" = "paused" ]
  local before
  before=$(cksum < "$RUNS/$RID.json")
  sc next-step.sh "$RID"
  [ "$(sig)" = "paused" ]
  [ "$(printf '%s' "$output" | jq -r '.step_id')" = "null" ]
  sc next-step.sh "$RID"
  [ "$(sig)" = "paused" ]
  [ "$(cksum < "$RUNS/$RID.json")" = "$before" ]
  [ "$(step_status "$RID" last)" = "pending" ]

  # A new session: nothing but the run id and the tree survives. Resume reports where the run continues.
  sc run-state.sh resume "$RID"
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r .status)" = "running" ]
  [ "$(printf '%s' "$output" | jq -r .next_step.id)" = "gate" ]
  [ "$(run_status "$RID")" = "running" ]

  # The loop re-enters and the gate comes back as a confirm step carrying the same rendering (SKILL.md: relay it
  # verbatim and stop); the stored gate is readable by a separate process and the user's reply resolves it. The
  # run status while the re-issued gate waits is deliberately not asserted: the skill relies on the gate payload,
  # not on that status.
  sc next-step.sh "$RID"
  [ "$(sig)" = "step" ]
  [ "$(printf '%s' "$output" | jq -r '.step_id + " " + .type')" = "gate confirm" ]
  [ "$(printf '%s' "$output" | jq -r .payload.rendered)" = $'Continue?\n\n1. Yes\n2. No\n3. Other (describe below)' ]
  sc step-confirm.sh status "$RID"
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r .step_id)" = "gate" ]
  sc step-confirm.sh reply "$RID" gate 1
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r '.option')" = "Yes" ]
  [ "$(run_status "$RID")" = "running" ]
  [ "$(step_status "$RID" gate)" = "completed" ]

  # Finish: the last skill step, then complete (repeated calls stay complete).
  sc next-step.sh "$RID"
  [ "$(sig)" = "step" ]
  [ "$(printf '%s' "$output" | jq -r .step_id)" = "last" ]
  sc complete-step.sh "$RID" last passed
  [ "$status" -eq 0 ]
  sc next-step.sh "$RID"
  [ "$(sig)" = "complete" ]
  sc next-step.sh "$RID"
  [ "$(sig)" = "complete" ]
  [ "$(run_status "$RID")" = "completed" ]
  [ "$(jq -r '[.steps[].status] | unique | join(",")' "$RUNS/$RID.json")" = "completed" ]
}

@test "protocol: an invalid gate reply changes nothing and the run keeps waiting (exit 3)" {
  fixture
  start_run
  sc next-step.sh "$RID"
  sc complete-step.sh "$RID" first passed
  sc next-step.sh "$RID"
  [ "$(printf '%s' "$output" | jq -r .step_id)" = "gate" ]
  local before
  before=$(cksum < "$RUNS/$RID.json")
  sc step-confirm.sh reply "$RID" gate 9
  [ "$status" -eq 3 ]
  [ "$(cksum < "$RUNS/$RID.json")" = "$before" ]
  [ "$(run_status "$RID")" = "awaiting_confirmation" ]
  sc next-step.sh "$RID"
  [ "$(sig)" = "awaiting_confirmation" ]
}

@test "protocol: a failed completion halts the run and next-step.sh keeps refusing until a resume" {
  fixture
  start_run
  sc next-step.sh "$RID"
  [ "$(printf '%s' "$output" | jq -r .step_id)" = "first" ]
  sc complete-step.sh "$RID" first failed "the skill reported an error"
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r .status)" = "halted" ]
  [ "$(run_status "$RID")" = "failed" ]
  [ "$(step_status "$RID" first)" = "failed" ]

  local before
  before=$(cksum < "$RUNS/$RID.json")
  sc next-step.sh "$RID"
  [ "$(sig)" = "halted" ]
  [ "$(printf '%s' "$output" | jq -r .step_id)" = "first" ]
  [ "$(printf '%s' "$output" | jq -r .payload.note)" = "the skill reported an error" ]
  sc next-step.sh "$RID"
  [ "$(sig)" = "halted" ]
  # Nothing was dispatched and no later step moved.
  [ "$(cksum < "$RUNS/$RID.json")" = "$before" ]
  [ "$(step_status "$RID" gate)" = "pending" ]
  [ "$(step_status "$RID" last)" = "pending" ]
  # A step cannot be reported on behalf of a failed run.
  sc complete-step.sh "$RID" gate passed
  [ "$status" -eq 1 ]
  [ "$(run_status "$RID")" = "failed" ]

  # Only an explicit resume moves it, and it restarts from the failed step.
  sc run-state.sh resume "$RID"
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r .next_step.id)" = "first" ]
  sc next-step.sh "$RID"
  [ "$(sig)" = "step" ]
  [ "$(printf '%s' "$output" | jq -r .step_id)" = "first" ]
}

@test "protocol: a cancelled run cannot be advanced, resumed or reported on" {
  fixture
  start_run
  sc next-step.sh "$RID"
  [ "$(printf '%s' "$output" | jq -r .step_id)" = "first" ]
  sc run-state.sh cancel "$RID"
  [ "$status" -eq 0 ]
  [ "$output" = "cancelled" ]
  [ "$(run_status "$RID")" = "cancelled" ]

  local before
  before=$(cksum < "$RUNS/$RID.json")
  sc next-step.sh "$RID"
  [ "$(sig)" = "cancelled" ]
  [ "$(printf '%s' "$output" | jq -r .step_id)" = "null" ]
  sc complete-step.sh "$RID" first passed
  [ "$status" -eq 1 ]
  sc run-state.sh resume "$RID"
  [ "$status" -eq 1 ]
  sc run-state.sh pause "$RID"
  [ "$status" -eq 1 ]
  sc run-state.sh cancel "$RID"
  [ "$status" -eq 1 ]
  sc next-step.sh "$RID"
  [ "$(sig)" = "cancelled" ]
  [ "$(cksum < "$RUNS/$RID.json")" = "$before" ]
  [ "$(run_status "$RID")" = "cancelled" ]
}

@test "protocol: relocated roots are honoured: runs land in the configured directory, the default ones are never created" {
  fixture
  start_run
  sc next-step.sh "$RID"
  sc complete-step.sh "$RID" first passed
  sc run-state.sh pause "$RID"
  sc run-state.sh cancel "$RID"
  [ -f "$RUNS/$RID.json" ]
  [ ! -e "$ANCHOR/$TREE/data" ]
  [ ! -e "$ANCHOR/project" ]
  [ ! -e "$BATS_TEST_TMPDIR/cwd/project" ]
  local f
  for f in $(find "$ANCHOR" -name "$RID*"); do
    case "$f" in "$RUNS/"*) ;; *) echo "stray run artefact: $f"; return 1 ;; esac
  done
}

# ---------------------------------------------------------------------------
# group 2: SKILL.md conformance
# ---------------------------------------------------------------------------

# frontmatter: the lines between the first two `---` lines of SKILL.md.
frontmatter() {
  awk 'NR == 1 && $0 != "---" { exit 1 } NR > 1 && $0 == "---" { exit 0 } NR > 1 { print }' "$SKILL_MD"
}

# code_lines: the lines of SKILL.md inside fenced code blocks.
code_lines() {
  awk '/^[[:space:]]*```/ { f = !f; next } f { print }' "$SKILL_MD"
}

@test "conformance: the skill directory is skills/j-workflow/ and there is no skills/workflow/" {
  [ -d "$SKILL_DIR" ]
  [ -f "$SKILL_MD" ]
  [ ! -e "$REPO_ROOT/skills/workflow" ]
}

@test "conformance: frontmatter parses with name j.workflow, a description, keywords and examples" {
  local fm
  fm=$(frontmatter)
  [ -n "$fm" ]
  printf '%s\n' "$fm" | grep -qx 'name: j.workflow'
  [ "$(printf '%s\n' "$fm" | grep -c '^name:')" -eq 1 ]
  printf '%s\n' "$fm" | grep -Eq '^description: .{20,}'
  # keywords: and examples: are lists with at least one quoted-or-plain item each.
  local key n
  for key in keywords examples; do
    printf '%s\n' "$fm" | grep -qx "$key:" || { echo "frontmatter lacks $key:"; return 1; }
    n=$(printf '%s\n' "$fm" | awk -v k="$key:" '$0 == k { f = 1; next } /^[A-Za-z_]+:/ { f = 0 } f && /^[[:space:]]+-[[:space:]]+[^[:space:]]/ { c++ } END { print c + 0 }')
    [ "$n" -ge 1 ] || { echo "$key has no items"; return 1; }
  done
  # The frontmatter is closed: the body follows the second marker.
  [ "$(grep -c '^---$' "$SKILL_MD")" -ge 2 ]
}

@test "conformance: every scripts/ path SKILL.md names exists in the repository and passes bash -n" {
  local paths p n=0
  paths=$(grep -oE '(skills/[A-Za-z0-9_-]+/)?scripts/[A-Za-z0-9_/-]+\.sh' "$SKILL_MD" | sort -u)
  [ -n "$paths" ]
  # The five scripts the run loop is built on must be among them.
  for p in scripts/workflow/run-state.sh scripts/workflow/next-step.sh scripts/workflow/complete-step.sh \
           scripts/workflow/step-confirm.sh skills/j-workflow/scripts/workflow-cli.sh; do
    printf '%s\n' "$paths" | grep -qx "$p" || { echo "SKILL.md does not name $p"; return 1; }
  done
  for p in $paths; do
    [ -f "$REPO_ROOT/$p" ] || { echo "named by SKILL.md but missing: $p"; return 1; }
    bash -n "$REPO_ROOT/$p" || { echo "syntax error: $p"; return 1; }
    n=$((n + 1))
  done
  [ "$n" -ge 5 ]
}

@test "conformance: SKILL.md names each sub-command: run, status, resume, pause, cancel, list" {
  local c
  for c in run status resume pause cancel list; do
    grep -Eq "(^|[^A-Za-z-])$c([^A-Za-z-]|\$)" "$SKILL_MD" || { echo "SKILL.md does not name: $c"; return 1; }
    grep -Eq "^#+ .*\`$c( |\`)|\`$c( |\`)|j\.workflow $c" "$SKILL_MD" || { echo "SKILL.md has no code-formatted use of: $c"; return 1; }
  done
  # The two lifecycle writers the skill delegates to are named with their sub-command.
  grep -Fq 'run-state.sh pause' "$SKILL_MD"
  grep -Fq 'run-state.sh cancel' "$SKILL_MD"
  grep -Fq 'run-state.sh resume' "$SKILL_MD"
  grep -Fq 'run-state.sh start' "$SKILL_MD"
}

@test "conformance: SKILL.md writes no run state: no redirect, tee or in-place edit in a code block, no runs path" {
  local code
  code=$(code_lines)
  [ -n "$code" ]
  # No redirect to a file (2>&1 style duplications are not writes), no tee, no in-place sed.
  if printf '%s\n' "$code" | sed -E 's/[0-9]*>&[0-9-]//g; s/&>[[:space:]]*\/dev\/null//g; s/[0-9]*>[[:space:]]*\/dev\/null//g' | grep -Eq '(^|[^-=|])>>?([^>]|$)|(^|[[:space:]])tee([[:space:]]|$)|sed[[:space:]]+-i'; then
    echo "a code block in SKILL.md writes to a file"
    return 1
  fi
  # The runs directory is never named: state is reached only through the scripts.
  ! grep -q 'workflow-runs' "$SKILL_MD"
  ! grep -Eq 'data/[A-Za-z-]*runs' "$SKILL_MD"
  # The skill itself says so.
  grep -Fq 'Never write run state by hand' "$SKILL_MD"
}
