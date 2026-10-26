#!/usr/bin/env bats
#
# Coverage for skills/j-reconcile/scripts/commit-evidence.sh (E79_S02_T06): /j-reconcile's commit-evidence lookup,
# now a thin wrapper over the shared resolver scripts/commits-for-item.sh.
#
# What it pins:
#   - found / none / unavailable are told apart, and ALL THREE exit 0: an empty result is "no evidence", never an
#     error, in reconcile (the resolver's own --require-nonempty is used internally only to learn why it is empty).
#   - "unavailable" is the shallow-clone case (commit-traceability-contract.md section 5.6, cell O3.H6): empty there
#     is not proof that no commit carries the task, so SKILL.md must not demote on it.
#   - SKILL.md no longer carries an inline `git log --grep`; Phases 2 and 3 call the helper.
#
# Every repository here is a throwaway under $BATS_TEST_TMPDIR, handed to the script with --repo. This repository's
# history, board and event log are never touched. The script is invoked through `bash`, as SKILL.md invokes it.

bats_require_minimum_version 1.5.0
load helpers/assertions

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
SCRIPT="$REPO_ROOT/skills/j-reconcile/scripts/commit-evidence.sh"
SKILL="$REPO_ROOT/skills/j-reconcile/SKILL.md"
REPORT="$REPO_ROOT/skills/j-reconcile/assets/report_format.md"

setup() {
  FIX="$BATS_TEST_TMPDIR/fixture"
  git init -q -b main "$FIX"
  git -C "$FIX" config user.email test@example.com
  git -C "$FIX" config user.name "Test"
  git -C "$FIX" config commit.gpgsign false
  git -C "$FIX" config core.hooksPath /dev/null
  CLOCK=1700000000
}

commit() {
  CLOCK=$((CLOCK + 60))
  local when="$CLOCK +0000"
  if [ $# -ge 2 ]; then
    GIT_AUTHOR_DATE="$when" GIT_COMMITTER_DATE="$when" git -C "$FIX" commit -q --allow-empty -m "$1" -m "$2"
  else
    GIT_AUTHOR_DATE="$when" GIT_COMMITTER_DATE="$when" git -C "$FIX" commit -q --allow-empty -m "$1"
  fi
}

evidence() { run --separate-stderr bash "$SCRIPT" "$@" --repo "$FIX"; }

# --------------------------------------------------------------------------------------------------------------
# The script
# --------------------------------------------------------------------------------------------------------------

@test "script exists and passes bash -n" {
  [ -f "$SCRIPT" ]
  run bash -n "$SCRIPT"
  [ "$status" -eq 0 ]
}

@test "script has no bashisms beyond bash 3.2" {
  run bash -c 'grep -vE "^[[:space:]]*#" "$1" | grep -nE "mapfile|readarray|declare -A|\\$\\{[A-Za-z_]+(,,|\\^\\^)"' _ "$SCRIPT"
  [ "$status" -eq 1 ]
}

@test "script runs no inline git log --grep of its own: it goes through the resolver" {
  run bash -c 'grep -vE "^[[:space:]]*#" "$1" | grep -c -- "--grep"' _ "$SCRIPT"
  [ "$output" = "0" ]
  run grep -c 'commits-for-item.sh' "$SCRIPT"
  [ "$output" -ge 1 ]
}

@test "--help prints usage on stdout and exits 0" {
  run --separate-stderr bash "$SCRIPT" --help
  [ "$status" -eq 0 ]
  assert_contains "$output" "commit-evidence.sh <task_id>"
  assert_contains "$output" "status: unavailable"
}

# --------------------------------------------------------------------------------------------------------------
# found
# --------------------------------------------------------------------------------------------------------------

@test "found: an EST commit gives status found, a count and a short-sha subject line" {
  commit "task(E10_S01_T01): do the thing"
  commit "task(E10_S01_T02): other"
  evidence E10_S01_T01
  [ "$status" -eq 0 ]
  local short
  short="$(git -C "$FIX" log -1 --format=%h --grep='E10_S01_T01')"
  [ "$(printf '%s\n' "$output" | sed -n 1p)" = "status: found" ]
  [ "$(printf '%s\n' "$output" | sed -n 2p)" = "count: 1" ]
  [ "$(printf '%s\n' "$output" | sed -n 3p)" = "$short task(E10_S01_T01): do the thing" ]
  [ "$(printf '%s\n' "$output" | wc -l | tr -d ' ')" = "3" ]
}

@test "found: several commits are counted and listed newest first" {
  commit "task(E10_S01_T01): first"
  commit "chore: unrelated"
  commit "task(E10_S01_T01): second"
  evidence E10_S01_T01
  [ "$status" -eq 0 ]
  assert_contains "$output" "count: 2"
  [ "$(printf '%s\n' "$output" | sed -n 3p | cut -d' ' -f2-)" = "task(E10_S01_T01): second" ]
  [ "$(printf '%s\n' "$output" | sed -n 4p | cut -d' ' -f2-)" = "task(E10_S01_T01): first" ]
}

@test "found: a template-form commit is found through its Jenga-Task trailer (what the old grep missed)" {
  commit "ASD-001 add retry" "Jenga-Task: E10_S01_T03"
  evidence E10_S01_T03
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | sed -n 1p)" = "status: found" ]
  assert_contains "$output" "ASD-001 add retry"
}

# --------------------------------------------------------------------------------------------------------------
# none: empty is "no evidence", not an error
# --------------------------------------------------------------------------------------------------------------

@test "none: no commit carries the id; exit 0, a single status line, nothing on stderr" {
  commit "task(E10_S01_T02): other"
  evidence E10_S01_T01
  [ "$status" -eq 0 ]
  [ "$output" = "status: none" ]
  [ -z "$stderr" ]
}

@test "none: an id that is only a prefix of another (T01 versus T010) is not evidence" {
  commit "task(E10_S01_T010): longer id"
  evidence E10_S01_T01
  [ "$status" -eq 0 ]
  [ "$output" = "status: none" ]
}

@test "none: a repository with no commits at all is still just 'none'" {
  evidence E10_S01_T01
  [ "$status" -eq 0 ]
  [ "$output" = "status: none" ]
}

# --------------------------------------------------------------------------------------------------------------
# unavailable: empty in a shallow clone is distinguishable from 'no commit exists'
# --------------------------------------------------------------------------------------------------------------

@test "unavailable: an empty result in a shallow clone is reported as unavailable, exit 0, reason on stderr" {
  commit "task(E10_S04_T03): old work"
  commit "chore: newer 1"
  commit "chore: newer 2"
  local clone="$BATS_TEST_TMPDIR/shallow"
  git clone -q --depth 1 "file://$FIX" "$clone"
  [ "$(git -C "$clone" rev-parse --is-shallow-repository)" = "true" ]
  run --separate-stderr bash "$SCRIPT" E10_S04_T03 --repo "$clone"
  [ "$status" -eq 0 ]
  [ "$output" = "status: unavailable" ]
  assert_contains "$stderr" "shallow"
  assert_contains "$stderr" "E10_S04_T03"
  # The same id in the full repository is plainly found: unavailable is about depth, not about the task.
  evidence E10_S04_T03
  [ "$(printf '%s\n' "$output" | sed -n 1p)" = "status: found" ]
}

@test "unavailable does not mask evidence: a shallow clone that does contain the commit reports found" {
  commit "chore: older"
  commit "task(E10_S04_T03): recent work"
  local clone="$BATS_TEST_TMPDIR/shallow"
  git clone -q --depth 1 "file://$FIX" "$clone"
  run --separate-stderr bash "$SCRIPT" E10_S04_T03 --repo "$clone"
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | sed -n 1p)" = "status: found" ]
  assert_contains "$output" "count: 1"
}

# --------------------------------------------------------------------------------------------------------------
# errors
# --------------------------------------------------------------------------------------------------------------

@test "usage errors exit 2: no id, two ids, unknown flag, malformed id, --repo without value" {
  run --separate-stderr bash "$SCRIPT"
  [ "$status" -eq 2 ]
  run --separate-stderr bash "$SCRIPT" E10_S01_T01 E10_S01_T02
  [ "$status" -eq 2 ]
  run --separate-stderr bash "$SCRIPT" E10_S01_T01 --nope
  [ "$status" -eq 2 ]
  run --separate-stderr bash "$SCRIPT" 'not-an-id' --repo "$FIX"
  [ "$status" -eq 2 ]
  run --separate-stderr bash "$SCRIPT" E10_S01_T01 --repo
  [ "$status" -eq 2 ]
}

@test "a directory that is not a git repository exits 4 with nothing on stdout (cannot verify, not 'none')" {
  mkdir "$BATS_TEST_TMPDIR/plain"
  run --separate-stderr bash "$SCRIPT" E10_S01_T01 --repo "$BATS_TEST_TMPDIR/plain"
  [ "$status" -eq 4 ]
  [ -z "$output" ]
  [ -n "$stderr" ]
}

# --------------------------------------------------------------------------------------------------------------
# SKILL.md structure
# --------------------------------------------------------------------------------------------------------------

@test "SKILL.md carries no inline git log --grep" {
  run grep -c -E 'git log[^`]*--grep' "$SKILL"
  [ "$output" = "0" ]
}

@test "SKILL.md Phase 2 and Phase 3 evidence steps call the helper and name the resolver" {
  local sec
  for sec in '### 2\. Verify' '### 3\. Verify'; do
    run sed -n "/^${sec}/,/^###\{0,1\}#* [0-9A-Z]/p" "$SKILL"
    [ "$status" -eq 0 ]
    assert_contains "$output" "skills/j-reconcile/scripts/commit-evidence.sh"
  done
  run sed -n '/^### 2\. Verify/,/^### 3\. Verify/p' "$SKILL"
  assert_contains "$output" "scripts/commits-for-item.sh"
}

@test "SKILL.md Phase 2 treats none as 'no evidence' (not an error) and never demotes on unavailable" {
  run sed -n '/^### 2\. Verify/,/^### 3\. Verify/p' "$SKILL"
  assert_contains "$output" "status: none"
  assert_contains "$output" "not an error"
  assert_contains "$output" "do not demote"
  assert_contains "$output" "HISTORY UNAVAILABLE"
  # --require-nonempty is the helper's business; reconcile itself must not pass it.
  assert_not_contains "$output" "--require-nonempty"
}

@test "the report format has a HISTORY UNAVAILABLE section" {
  run grep -c 'HISTORY UNAVAILABLE' "$REPORT"
  [ "$output" -ge 2 ]
}
