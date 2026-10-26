#!/usr/bin/env bats
#
# E80_S03_T05: scripts/workflow/step-playbook.sh resolves a playbook id through load-playbooks.sh lookup and
# prints the action object for a `playbook` workflow step; --resume marks it as re-initialised (playbook run
# state is not durable, so a playbook is one unit of a workflow).
#
# Fixture-tree convention (following tests/load-playbooks-project-source.bats): each case builds its own
# synthetic skills/ and playbooks/ tree under $BATS_TEST_TMPDIR and points the loader at it with
# JENGA_PLAYBOOKS_TEST_ROOT. One case runs against a real builtin id and one checks that skills/jenga/ is
# untouched; neither modifies anything.

load helpers/assertions

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
SCRIPT="$REPO_ROOT/scripts/workflow/step-playbook.sh"

write_skill() {
  local name="$1"
  mkdir -p "$FIXTURE_ROOT/skills/$name"
  printf -- '---\nname: j.%s\ndescription: fixture skill %s.\n---\n# %s\n' "$name" "$name" "$name" \
    > "$FIXTURE_ROOT/skills/$name/SKILL.md"
}

write_builtin_playbook() {
  local id="$1" steps_json="$2"
  mkdir -p "$FIXTURE_ROOT/skills/jenga/playbooks"
  cat > "$FIXTURE_ROOT/skills/jenga/playbooks/$id.json" <<JSON
{
  "id": "$id",
  "name": "Fixture $id",
  "description": "fixture builtin playbook $id",
  "keywords": ["fixture"],
  "examples": ["fixture example"],
  "steps": [$steps_json]
}
JSON
}

# Runs the script with the fixture root; stdout and stderr land in $BATS_TEST_TMPDIR/{out,err}, status in $status.
run_step() {
  run env JENGA_PLAYBOOKS_TEST_ROOT="$FIXTURE_ROOT" bash -c \
    'bash "$0" "$@" >"$BATS_TEST_TMPDIR/out" 2>"$BATS_TEST_TMPDIR/err"' "$SCRIPT" "$@"
}

setup() {
  FIXTURE_ROOT="$BATS_TEST_TMPDIR/fixture-root"
  mkdir -p "$FIXTURE_ROOT/skills/jenga/playbooks"
  write_skill "alpha"
  write_skill "beta"
  write_skill "gamma"
}

jq_field() { python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(json.dumps(d[sys.argv[2]]))' "$BATS_TEST_TMPDIR/out" "$1"; }

# --- AC1: exists, executable, syntax, documented limit -------------------------------------------

@test "step-playbook.sh exists, is executable and passes bash -n" {
  [ -f "$SCRIPT" ]
  [ -x "$SCRIPT" ]
  run bash -n "$SCRIPT"
  [ "$status" -eq 0 ]
}

@test "the header states the whole-playbook-as-one-unit limit" {
  run grep -c -i "ONE unit of a workflow" "$SCRIPT"
  [ "$status" -eq 0 ]
  grep -q "FIRST step" "$SCRIPT"
}

# --- AC2: success --------------------------------------------------------------------------------

@test "a known id prints the object with ordered steps and reinitialised false" {
  write_builtin_playbook "chain" '"alpha", "beta", "gamma"'
  run_step chain
  [ "$status" -eq 0 ]
  [ "$(jq_field playbook_id)" = '"chain"' ]
  [ "$(jq_field name)" = '"Fixture chain"' ]
  [ "$(jq_field steps)" = '["alpha", "beta", "gamma"]' ]
  [ "$(jq_field reinitialised)" = "false" ]
  python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); sys.exit(0 if "note" not in d else 1)' "$BATS_TEST_TMPDIR/out"
}

@test "step objects yield their skill name, in order" {
  write_builtin_playbook "objs" '"alpha", {"skill": "beta", "instruction": "do it"}, {"skill": "gamma", "instruction": "then this"}'
  run_step objs
  [ "$status" -eq 0 ]
  [ "$(jq_field steps)" = '["alpha", "beta", "gamma"]' ]
}

@test "stdout carries exactly one JSON line" {
  write_builtin_playbook "chain" '"alpha"'
  run_step chain
  [ "$status" -eq 0 ]
  [ "$(wc -l < "$BATS_TEST_TMPDIR/out" | tr -d ' ')" = "1" ]
}

@test "a real builtin playbook id resolves against this repository" {
  run bash -c 'bash "$0" board-hygiene 2>/dev/null' "$SCRIPT"
  [ "$status" -eq 0 ]
  assert_output_contains '"playbook_id": "board-hygiene"'
  assert_output_contains '"steps": ["j-reconcile", "j-todo", "j-status"]'
  assert_output_contains '"reinitialised": false'
}

# --- AC3: --resume -------------------------------------------------------------------------------

@test "--resume prints reinitialised true and the explanatory note" {
  write_builtin_playbook "chain" '"alpha", "beta"'
  run_step chain --resume
  [ "$status" -eq 0 ]
  [ "$(jq_field reinitialised)" = "true" ]
  [ "$(jq_field steps)" = '["alpha", "beta"]' ]
  note="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["note"])' "$BATS_TEST_TMPDIR/out")"
  assert_contains "$note" "restarts from its first step"
  assert_contains "$note" "not"
}

@test "--resume works before the id too" {
  write_builtin_playbook "chain" '"alpha"'
  run_step --resume chain
  [ "$status" -eq 0 ]
  [ "$(jq_field reinitialised)" = "true" ]
}

@test "--resume never reuses an old playbook run state file" {
  write_builtin_playbook "chain" '"alpha"'
  printf '{"stale": true}\n' > "$BATS_TEST_TMPDIR/jenga-playbook-run-stale.json"
  TMPDIR="$BATS_TEST_TMPDIR" run_step chain --resume
  [ "$status" -eq 0 ]
  ! grep -q stale "$BATS_TEST_TMPDIR/out"
}

# --- AC4: unknown id -----------------------------------------------------------------------------

@test "an unknown id exits 1, relays a message on stderr and prints nothing on stdout" {
  write_builtin_playbook "chain" '"alpha"'
  run_step no-such-playbook
  [ "$status" -eq 1 ]
  [ ! -s "$BATS_TEST_TMPDIR/out" ]
  grep -q "no-such-playbook" "$BATS_TEST_TMPDIR/err"
  grep -qi "unknown playbook" "$BATS_TEST_TMPDIR/err"
}

@test "a playbook that fails validation exits 1 with its reason and nothing on stdout" {
  write_builtin_playbook "broken" '"alpha", "no-such-skill"'
  run_step broken
  [ "$status" -eq 1 ]
  [ ! -s "$BATS_TEST_TMPDIR/out" ]
  grep -qi "invalid" "$BATS_TEST_TMPDIR/err"
}

@test "an unknown id with --resume also exits 1 with nothing on stdout" {
  run_step no-such-playbook --resume
  [ "$status" -eq 1 ]
  [ ! -s "$BATS_TEST_TMPDIR/out" ]
}

# --- usage ---------------------------------------------------------------------------------------

@test "no id exits 2 with nothing on stdout" {
  run_step
  [ "$status" -eq 2 ]
  [ ! -s "$BATS_TEST_TMPDIR/out" ]
}

@test "an unknown option exits 2 and an extra argument exits 2" {
  run_step chain --bogus
  [ "$status" -eq 2 ]
  run_step chain other
  [ "$status" -eq 2 ]
}

@test "--help prints usage on stdout and exits 0" {
  run bash "$SCRIPT" --help
  [ "$status" -eq 0 ]
  assert_output_contains "step-playbook.sh <playbook_id> [--resume]"
}

# --- AC5: skills/jenga is untouched --------------------------------------------------------------

@test "running the script changes nothing under skills/jenga/" {
  before="$(git -C "$REPO_ROOT" status --porcelain -- skills/jenga 2>/dev/null)"
  bash "$SCRIPT" board-hygiene >/dev/null 2>&1
  bash "$SCRIPT" board-hygiene --resume >/dev/null 2>&1
  after="$(git -C "$REPO_ROOT" status --porcelain -- skills/jenga 2>/dev/null)"
  [ "$before" = "$after" ]
}

@test "the script does not call run-playbook-step.sh" {
  ! grep -v '^#' "$SCRIPT" | grep -q "run-playbook-step"
}
