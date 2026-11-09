#!/usr/bin/env bats
#
# Coverage for the per-branch git evidence gatherer used by /j-reconcile (E78_S05_T03).
#
# Contract under test:
#   - skills/j-reconcile/scripts/gather-perceived-branch-evidence.sh   header comment: USAGE, OUTPUT and EXIT CODES (E78_S05_T01)
#   - scripts/perceived-branch.sh                                      the per-session state it reads (E78_S01_T02)
#
# Isolation. Every test builds its own throwaway git repository ($PROJ, under $BATS_TEST_TMPDIR) on branch "main", with
# a branch "feat-a", no remote, and nothing pushed or fetched. The gather script resolves scripts/perceived-branch.sh
# relative to its own location (../../../scripts/perceived-branch.sh), and perceived-branch.sh locates its state
# directory through scripts/resolve-root.sh. The suite therefore COPIES the three scripts into $TOOLS, a directory
# OUTSIDE the fixture repository, at the same relative layout, and points JENGA_PROJECT_ROOT at the fixture so every
# state file lands inside the fixture. The repository this suite lives in is only READ (the scripts are copied out of
# it); its branches, worktrees, project/logs and project/queue are never written. The fixture ignores
# "project/queue/perceived-branch/" exactly as the real .gitignore does, so `git status` stays comparable.
#
# Fixture history: an initial commit on main (workflow.json, .gitignore), then one commit on main whose message names
# task E99_S01_T01, and a branch feat-a cut from the INITIAL commit with one commit naming E99_S01_T02. So T01 exists
# only on main and T02 only on feat-a. A second worktree (branch wt-side) and a dirty main tree (an untracked file and
# a modified tracked file) make the "left untouched" snapshot meaningful.
#
# Session identity is injected through --session <key>, never through the developer's real environment: setup unsets
# CLAUDE_CODE_SESSION_ID, JENGA_SESSION_ID, CLAUDE_SESSION_ID and JENGA_CHECKLIST_SESSION_ID.
#
# Read-only guarantee (every case). Every call to the script goes through gather(), which snapshots the fixture's
# `git branch --show-current`, `git status --porcelain`, `git branch --list`, `git worktree list`, HEAD and the content
# of the dirty files before and after the run and fails the test when they differ.
#
# bats `run` merges stderr into $output unless `run --separate-stderr` is used, so gather() uses it and tests can look
# at stdout ($output, $lines) and stderr ($stderr) on their own. Assertions use `[ ... ]` and the helpers in
# tests/helpers/assertions.bash, never a bare `[[ ... ]]` (inert under bats), and no assertion negates a command with
# `!` (also exempt from errexit).
#
# Public mirror. Everything exercised here classifies PUBLIC, so the suite ships too. It reads no board file, no
# project/documentation file and nothing untracked; a script it copies that is absent from the tree makes setup skip
# with the script named in the reason; it never passes silently.

bats_require_minimum_version 1.5.0
load helpers/assertions

REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
GATHER_REL="skills/j-reconcile/scripts/gather-perceived-branch-evidence.sh"

setup() {
  command -v jq >/dev/null 2>&1 || skip "jq is not installed (scripts/perceived-branch.sh requires it)"
  command -v git >/dev/null 2>&1 || skip "git is not installed"

  # The developer's real environment must not leak a session key, a project dir or a git context into the fixture.
  unset CLAUDE_CODE_SESSION_ID JENGA_SESSION_ID CLAUDE_SESSION_ID JENGA_CHECKLIST_SESSION_ID
  unset CLAUDE_PROJECT_DIR COPILOT_WORKSPACE_FOLDER JENGA_PROJECT_DIR JENGA_AGENT_TYPE CLAUDE_AGENT_TYPE
  unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE
  : >"$BATS_TEST_TMPDIR/gitconfig"
  export GIT_CONFIG_GLOBAL="$BATS_TEST_TMPDIR/gitconfig" GIT_CONFIG_NOSYSTEM=1

  local base f
  base="$(cd "$BATS_TEST_TMPDIR" && pwd -P)"
  PROJ="$base/proj"
  TOOLS="$base/tools"

  for f in "$GATHER_REL" scripts/perceived-branch.sh scripts/resolve-root.sh; do
    [ -f "$REPO_ROOT/$f" ] || skip "$f is not in this tree"
    mkdir -p "$TOOLS/$(dirname "$f")"
    cp "$REPO_ROOT/$f" "$TOOLS/$f"
  done
  GATHER="$TOOLS/$GATHER_REL"

  mkdir -p "$PROJ/project/configs"
  printf '{"paths":{"queue":"project/queue"}}\n' >"$PROJ/project/configs/workflow.json"
  printf 'project/queue/perceived-branch/\n' >"$PROJ/.gitignore"
  printf 'tracked\n' >"$PROJ/notes.txt"

  git -C "$PROJ" init -q
  git -C "$PROJ" symbolic-ref HEAD refs/heads/main
  git -C "$PROJ" config user.name "bats"
  git -C "$PROJ" config user.email "bats@example.invalid"
  git -C "$PROJ" config commit.gpgsign false
  git -C "$PROJ" add -A
  git -C "$PROJ" commit -q -m "initial commit"

  git -C "$PROJ" branch feat-a
  git -C "$PROJ" checkout -q feat-a
  git -C "$PROJ" commit -q --allow-empty -m "task(E99_S01_T02): work that exists only on feat-a"
  git -C "$PROJ" checkout -q main
  git -C "$PROJ" commit -q --allow-empty -m "task(E99_S01_T01): work that exists only on main"

  # A second worktree and a dirty main tree, so the unchanged-state snapshot has something to lose.
  git -C "$PROJ" worktree add -q -b wt-side "$base/wt-side" main
  printf 'uncommitted\n' >"$PROJ/scratch.txt"
  printf 'modified\n' >>"$PROJ/notes.txt"

  export JENGA_PROJECT_ROOT="$PROJ"
  cd "$PROJ"
}

# --- helpers ------------------------------------------------------------------------------------------------------

# Everything "the script did not move or create anything" means, for the fixture.
snap() {
  printf 'current=%s\nhead=%s\n' "$(git -C "$PROJ" branch --show-current)" "$(git -C "$PROJ" rev-parse HEAD)"
  printf -- '--- status\n%s\n' "$(git -C "$PROJ" status --porcelain)"
  printf -- '--- branches\n%s\n' "$(git -C "$PROJ" branch --list)"
  printf -- '--- worktrees\n%s\n' "$(git -C "$PROJ" worktree list)"
  printf -- '--- files\n'
  cksum <"$PROJ/notes.txt"
  cksum <"$PROJ/scratch.txt"
}

# gather <args...>: runs the script under test from the fixture root, stdout in $output/$lines, stderr in $stderr,
# exit status in $status, and fails when the fixture changed. Every case goes through here.
gather() {
  local before after
  before="$(snap)"
  run --separate-stderr bash "$GATHER" "$@"
  after="$(snap)"
  if [ "$before" != "$after" ]; then
    printf 'the script changed the fixture\n--- before\n%s\n--- after\n%s\n' "$before" "$after"
    return 1
  fi
  return 0
}

# Records <branch> as the perceived branch of session <key> (through the copied perceived-branch.sh).
seed() {
  bash "$TOOLS/scripts/perceived-branch.sh" set "$2" --session "$1" >/dev/null 2>&1
}

# field <name>: the value of one key=value pair of the record line in $output ("" when empty).
field() {
  printf '%s\n' "$output" | tr ' ' '\n' | sed -n "s/^$1=//p"
}

# --- no perceived branch: today's behaviour ------------------------------------------------------------------------------

@test "no perceived branch: exactly the documented record, exit 0, nothing on stderr" {
  gather E99_S01_T01 --session sess-A
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 1 ]
  [ "$output" = "task_id=E99_S01_T01 real_branch=main perceived_branch= perceived_stale=no evidence_on_real=yes evidence_on_perceived=no evidence_branch=real" ]
  [ -z "$stderr" ]
  [ -z "$(field perceived_branch)" ]
}

@test "no perceived branch: a task with no commit anywhere reads evidence_branch=none" {
  gather E99_S01_T02 --session sess-A
  [ "$status" -eq 0 ]
  [ "$(field evidence_on_real)" = "no" ]
  [ "$(field evidence_on_perceived)" = "no" ]
  [ "$(field evidence_branch)" = "none" ]
  [ -z "$(field perceived_branch)" ]
}

@test "the real branch is read from the main tree even when run from another worktree" {
  cd "$BATS_TEST_TMPDIR/wt-side"
  gather E99_S01_T01 --session sess-A
  [ "$status" -eq 0 ]
  [ "$(field real_branch)" = "main" ]
  [ "$(field evidence_branch)" = "real" ]
}

# --- feat-a perceived ------------------------------------------------------------------------------------------------

@test "feat-a perceived: E99_S01_T02 is evidenced on the perceived branch only" {
  seed sess-A feat-a
  gather E99_S01_T02 --session sess-A
  [ "$status" -eq 0 ]
  [ "$(field perceived_branch)" = "feat-a" ]
  [ "$(field perceived_stale)" = "no" ]
  [ "$(field evidence_on_perceived)" = "yes" ]
  [ "$(field evidence_on_real)" = "no" ]
  [ "$(field evidence_branch)" = "perceived" ]
  [ -z "$stderr" ]
}

@test "feat-a perceived: E99_S01_T01 is still evidenced on the real branch, not the perceived one" {
  seed sess-A feat-a
  gather E99_S01_T01 --session sess-A
  [ "$status" -eq 0 ]
  [ "$(field real_branch)" = "main" ]
  [ "$(field perceived_branch)" = "feat-a" ]
  [ "$(field evidence_on_real)" = "yes" ]
  [ "$(field evidence_on_perceived)" = "no" ]
  [ "$(field evidence_branch)" = "real" ]
}

@test "a task on both branches reads evidence_branch=both" {
  git -C "$PROJ" branch feat-both main
  seed sess-A feat-both
  gather E99_S01_T01 --session sess-A
  [ "$status" -eq 0 ]
  [ "$(field evidence_on_real)" = "yes" ]
  [ "$(field evidence_on_perceived)" = "yes" ]
  [ "$(field evidence_branch)" = "both" ]
}

@test "a perceived branch equal to the real branch is never reported as both" {
  seed sess-A main
  gather E99_S01_T01 --session sess-A
  [ "$status" -eq 0 ]
  [ "$(field perceived_branch)" = "main" ]
  [ "$(field evidence_branch)" = "real" ]
}

@test "a task id that is only a prefix of a commit's id does not match" {
  seed sess-A feat-a
  gather E99_S01_T0 --session sess-A
  [ "$status" -eq 0 ]
  [ "$(field evidence_branch)" = "none" ]
}

# --- stale perceived branch ------------------------------------------------------------------------------------------

@test "after feat-a is deleted: exit 0, perceived_stale=yes naming feat-a, no perceived evidence" {
  seed sess-A feat-a
  git -C "$PROJ" branch -D feat-a >/dev/null 2>&1
  gather E99_S01_T02 --session sess-A
  [ "$status" -eq 0 ]
  [ "$(field perceived_branch)" = "feat-a" ]
  [ "$(field perceived_stale)" = "yes" ]
  [ "$(field evidence_on_perceived)" = "no" ]
  [ "$(field evidence_branch)" = "none" ]
  [ -z "$stderr" ]
}

@test "after feat-a is deleted: real-branch evidence is still found" {
  seed sess-A feat-a
  git -C "$PROJ" branch -D feat-a >/dev/null 2>&1
  gather E99_S01_T01 --session sess-A
  [ "$status" -eq 0 ]
  [ "$(field perceived_stale)" = "yes" ]
  [ "$(field evidence_on_real)" = "yes" ]
  [ "$(field evidence_branch)" = "real" ]
}

# --- session isolation -------------------------------------------------------------------------------------------------

@test "a perceived branch set for session A is not used when asking as session B" {
  seed sess-A feat-a
  gather E99_S01_T02 --session sess-B
  [ "$status" -eq 0 ]
  [ -z "$(field perceived_branch)" ]
  [ "$(field perceived_stale)" = "no" ]
  [ "$(field evidence_on_perceived)" = "no" ]
  [ "$(field evidence_branch)" = "none" ]
}

@test "session A still sees its own perceived branch after session B asked" {
  seed sess-A feat-a
  gather E99_S01_T02 --session sess-B
  gather E99_S01_T02 --session sess-A
  [ "$status" -eq 0 ]
  [ "$(field perceived_branch)" = "feat-a" ]
  [ "$(field evidence_branch)" = "perceived" ]
}

@test "the session can be injected with --session=<key> as well" {
  seed sess-A feat-a
  gather E99_S01_T02 --session=sess-A
  [ "$status" -eq 0 ]
  [ "$(field perceived_branch)" = "feat-a" ]
}

# --- usage and failures ------------------------------------------------------------------------------------------------

@test "usage errors exit 2 with nothing on stdout" {
  gather --session sess-A
  [ "$status" -eq 2 ]
  [ -z "$output" ]
  [ -n "$stderr" ]

  gather not-a-task-id --session sess-A
  [ "$status" -eq 2 ]
  [ -z "$output" ]

  gather E99_S01_T01 E99_S01_T02 --session sess-A
  [ "$status" -eq 2 ]
  [ -z "$output" ]

  gather E99_S01_T01 --bogus
  [ "$status" -eq 2 ]
  [ -z "$output" ]
}

@test "a malformed --session key exits 2 with nothing on stdout" {
  gather E99_S01_T01 --session "../escape"
  [ "$status" -eq 2 ]
  [ -z "$output" ]
}

@test "--help prints the usage and exits 0" {
  gather --help
  [ "$status" -eq 0 ]
  assert_output_contains "gather-perceived-branch-evidence.sh <task_id>"
}

@test "a missing perceived-branch.sh exits 4 with nothing on stdout" {
  rm -f "$TOOLS/scripts/perceived-branch.sh"
  gather E99_S01_T01 --session sess-A
  [ "$status" -eq 4 ]
  [ -z "$output" ]
  assert_contains "$stderr" "perceived-branch.sh"
}

@test "outside a git repository the script exits 3 with nothing on stdout" {
  mkdir -p "$BATS_TEST_TMPDIR/not-a-repo"
  cd "$BATS_TEST_TMPDIR/not-a-repo"
  run --separate-stderr env GIT_CEILING_DIRECTORIES="$BATS_TEST_TMPDIR" bash "$GATHER" E99_S01_T01 --session sess-A
  [ "$status" -eq 3 ]
  [ -z "$output" ]
}
