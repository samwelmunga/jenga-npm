#!/usr/bin/env bats
#
# Wiring coverage for the scope test gate in the agent definitions (E72_S06_T04).
#
# skills/j-test/scripts/scope-test-gate.sh (E72_S06_T03) is called by the tester at the task, story and epic boundaries
# and requested from the tester by the scrum master before the epic closes. This suite is a grep-style check over the
# instruction text: it pins that the calls, the policy-none behaviour, the failure handling and the developer
# prohibition are present, and that the three edited files are byte-identical across the root, .claude/ and .agents/.
# It does not run the gate (tests/scope-test-gate.bats does) and it executes no agent.
#
# Assertions use `[ ]` and tests/helpers/assertions.bash only; a line starting with `[[` is banned repo-wide by
# tests/bats-assertion-convention.bats.

# shellcheck disable=SC2030,SC2031

bats_require_minimum_version 1.5.0

load helpers/assertions

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
TESTER="$REPO_ROOT/agents/tester.md"
SCRUM="$REPO_ROOT/agents/scrum-master.md"
DEVELOPER="$REPO_ROOT/agents/developer.md"
SKILL="$REPO_ROOT/skills/j-test/SKILL.md"
CLAUDE_MD="$REPO_ROOT/CLAUDE.md"

# read_file <path>: file contents in $body (fails the test when the file is missing).
read_file() {
  [ -f "$1" ]
  body="$(cat "$1")"
}

# tester.md ---------------------------------------------------------------------------------------------------------

@test "tester.md calls the gate for the task, story and epic scopes" {
  read_file "$TESTER"
  assert_contains "$body" "scope-test-gate.sh"
  assert_contains "$body" "--scope task --id <E##_S##_T##>"
  assert_contains "$body" "--scope story --id <E##_S##>"
  assert_contains "$body" "--scope epic --id <E##>"
}

@test "tester.md resolves the gate path with the installed-package fallback convention" {
  read_file "$TESTER"
  assert_contains "$body" "node_modules/@jenga-ai/agent/skills/j-test/scripts/scope-test-gate.sh"
}

@test "tester.md runs the task gate from the task worktree so the unmerged commits are found" {
  read_file "$TESTER"
  assert_contains "$body" "--scope task --id <E##_S##_T##> --root <worktree>"
  assert_contains "$body" "unmerged task branch"
  assert_contains "$body" "--rev"
  assert_contains "$body" "--range"
}

@test "tester.md states that policy none keeps the current behaviour" {
  read_file "$TESTER"
  assert_contains "$body" "policy none"
  assert_contains "$body" "no suite run (policy none)"
  assert_contains "$body" "the flow is unchanged"
}

@test "tester.md maps gate exit 1 to Failed plus a problem rapport and exit 2 or 3 to a non-pass" {
  read_file "$TESTER"
  assert_contains "$body" "**Exit 1.** At least one suite failed. The task is \`Failed\`"
  assert_contains "$body" "problem rapport"
  assert_contains "$body" "**Exit 2 or 3.**"
  assert_contains "$body" "it is never a pass"
  assert_contains "$body" "write the story \`Failed\`"
}

@test "tester.md calls the story gate only on a story-closing pass and keeps the mid-story pass gate-free" {
  read_file "$TESTER"
  assert_contains "$body" "Story scope test gate (story-closing pass only)"
  assert_contains "$body" "A mid-story pass does **not** call the story gate."
}

@test "tester.md does not fire story_rollup when the story gate fails" {
  read_file "$TESTER"
  assert_contains "$body" "**do not fire the \`story_rollup\` trigger**"
  assert_contains "$body" "**do not write the \`story_rollup\` trigger**"
}

@test "tester.md reports a gate fallback rather than hiding it" {
  read_file "$TESTER"
  assert_contains "$body" "no-commits"
  assert_contains "$body" "no-mapped-suites"
  assert_contains "$body" "reported, not hidden"
}

@test "tester.md describes the epic gate as on request, report back, never writing the epic status" {
  read_file "$TESTER"
  assert_contains "$body" "Epic scope test gate (on the scrum master's request)"
  assert_contains "$body" "You never write the epic's status"
}

@test "tester.md names the three config keys and says the gate adds to, not replaces, the tester's own tests" {
  read_file "$TESTER"
  assert_contains "$body" "project/configs/test-config.json"
  assert_contains "$body" "test_run_task"
  assert_contains "$body" "test_run_story"
  assert_contains "$body" "test_run_epic"
  assert_contains "$body" "in addition to, not instead of"
}

@test "tester.md keeps the SAST approval flow, the status-write monopoly and the developer prohibition" {
  read_file "$TESTER"
  assert_contains "$body" "SAST and vulnerability approval flow is unchanged"
  assert_contains "$body" "You are the only agent permitted to write the judged statuses of tasks and stories"
  assert_contains "$body" "The developer never runs tests"
}

# scrum-master.md ---------------------------------------------------------------------------------------------------

@test "scrum-master.md requests the epic gate from the tester before the epic status is set" {
  read_file "$SCRUM"
  assert_contains "$body" "epic scope test gate"
  assert_contains "$body" "--scope epic --id <E##>"
  assert_contains "$body" "run by the tester"
  assert_contains "$body" "**before** the epic status is set"
}

@test "scrum-master.md keeps the epic In Progress with a rapport on exit 1" {
  read_file "$SCRUM"
  assert_contains "$body" "**Exit 1:** a suite failed. Keep the epic \`In Progress\`, do not set \`date_completed\`"
  assert_contains "$body" "problem rapport"
  assert_contains "$body" "naming the failed suites"
}

@test "scrum-master.md does not roll up on exit 2 or 3 and does not run the suites itself" {
  read_file "$SCRUM"
  assert_contains "$body" "**Exit 2 or 3:**"
  assert_contains "$body" "do not roll up"
  assert_contains "$body" "you do not run the suites yourself"
}

# j-test skill ------------------------------------------------------------------------------------------------------

@test "j-test SKILL.md points at the two scope scripts and the Scope test policy section" {
  read_file "$SKILL"
  assert_contains "$body" "scope-policy.sh"
  assert_contains "$body" "scope-test-gate.sh"
  assert_contains "$body" "Scope test policy"
}

# developer prohibition ----------------------------------------------------------------------------------------------

@test "the developer prohibition is still present in developer.md and CLAUDE.md" {
  read_file "$DEVELOPER"
  assert_contains "$body" "You do not run tests yourself."
  assert_contains "$body" "You do not run tests."
  read_file "$CLAUDE_MD"
  assert_contains "$body" "Never runs tests"
}

@test "no sentence in the edited agent files and the skill assigns test running to the developer" {
  local f
  # Lines that mention the developer running tests are allowed only as a prohibition ("never runs", "does not run").
  for f in "$TESTER" "$SCRUM" "$SKILL"; do
    run bash -c "grep -inE 'developer[^.]{0,40}(runs?|executes?) (the )?(tests?|suites?|gate)|developer (should|must|may|can) run' \"\$1\" | grep -ivE 'never|not run|no test'" _ "$f"
    [ "$status" -eq 1 ]
  done
}

# mirror parity ------------------------------------------------------------------------------------------------------

@test "agents/tester.md is byte-identical across root, .claude and .agents" {
  cmp "$REPO_ROOT/agents/tester.md" "$REPO_ROOT/.claude/agents/tester.md"
  cmp "$REPO_ROOT/agents/tester.md" "$REPO_ROOT/.agents/agents/tester.md"
}

@test "agents/scrum-master.md is byte-identical across root, .claude and .agents" {
  cmp "$REPO_ROOT/agents/scrum-master.md" "$REPO_ROOT/.claude/agents/scrum-master.md"
  cmp "$REPO_ROOT/agents/scrum-master.md" "$REPO_ROOT/.agents/agents/scrum-master.md"
}

@test "skills/j-test/SKILL.md is byte-identical across root, .claude and .agents" {
  cmp "$REPO_ROOT/skills/j-test/SKILL.md" "$REPO_ROOT/.claude/skills/j-test/SKILL.md"
  cmp "$REPO_ROOT/skills/j-test/SKILL.md" "$REPO_ROOT/.agents/skills/j-test/SKILL.md"
}

# the scripts the text names -----------------------------------------------------------------------------------------

@test "scope-policy.sh and scope-test-gate.sh exist and are executable" {
  [ -x "$REPO_ROOT/skills/j-test/scripts/scope-policy.sh" ]
  [ -x "$REPO_ROOT/skills/j-test/scripts/scope-test-gate.sh" ]
}
