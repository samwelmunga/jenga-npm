#!/usr/bin/env bats
#
# Coverage for the worktree commit guard with a task branch cut from a perceived branch (E78_S03_T01).
#
# Contract under test:
#   - scripts/install-worktree-commit-guard.sh   bakes the worktree's OWN task branch into a per-worktree pre-commit
#                                                hook (core.hooksPath via `git config --worktree`) and rejects a commit
#                                                made while HEAD is on any other branch
#   - scripts/create-task-worktree.sh            cuts the task branch from the session's perceived branch (E78_S02_T02)
#   - scripts/perceived-branch.sh                the per-session state that script reads (E78_S01_T02)
# The WorktreeCreate hook (settings.json, E78_S02_T03) runs the first two in that order, so the fixture does the same:
# create-task-worktree.sh <dir> <name> --session <key>, then install-worktree-commit-guard.sh <dir> <name>.
#
# What is proved. The guard never compares against a base branch, so a task branch cut from a perceived branch (feat-a,
# distinct from the checked-out main) must be accepted, while a commit made in the same worktree with HEAD on main, on
# the perceived branch, on another branch or detached must be blocked with the guard's existing "commit blocked"
# message and a non-zero exit, and must not create a commit. Two worktrees cut from two different perceived bases
# (two sessions) each keep their own guard.
#
# Isolation. Every test builds its own throwaway git repository ($PROJ, under $BATS_TEST_TMPDIR) on branch "main", with
# one commit, no remote and nothing pushed or fetched, plus branches feat-a and feat-b that each carry a distinct
# commit. The scripts under test are COPIED into the fixture's scripts/ directory and committed there; the repository
# this suite lives in is only READ. Git commits happen only in the fixture ($PROJ and its task worktrees), with a global
# git config that is empty and a repo-local identity. The pre-commit hook only runs for a real `git commit`, so every
# commit here is one.
#
# Session identity is injected through --session <key>, never through the developer's real environment: setup unsets
# CLAUDE_CODE_SESSION_ID, JENGA_SESSION_ID, CLAUDE_SESSION_ID and JENGA_CHECKLIST_SESSION_ID. The queue directory is
# redirected into the fixture through JENGA_PROJECT_ROOT, which scripts/resolve-root.sh honours.
#
# bats `run` merges stderr into $output unless `run --separate-stderr` is used, so a test that looks at stderr on its own
# goes through try_commit below, which uses it. Assertions use `[ ... ]` and the helpers in tests/helpers/assertions.bash,
# never a bare `[[ ... ]]` (inert under bats), and no assertion negates a command with `!` (also exempt from errexit).
#
# Public mirror. Everything this suite reads classifies PUBLIC (scripts/check-publicignore-match.sh): the three scripts
# named above and scripts/resolve-root.sh. It reads no board file, no project/documentation file and nothing untracked.
# A repo file the suite needs that is absent from the tree makes the test skip, naming the file in the reason; it never
# passes silently.

bats_require_minimum_version 1.5.0
load helpers/assertions

REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"

SESS_A="sess-A"
SESS_B="sess-B"

setup() {
  command -v jq >/dev/null 2>&1 || skip "jq is not installed (scripts/perceived-branch.sh needs it)"
  command -v git >/dev/null 2>&1 || skip "git is not installed"

  # The developer's real environment must not leak a session key, a project dir or a git context into the fixture.
  unset CLAUDE_CODE_SESSION_ID JENGA_SESSION_ID CLAUDE_SESSION_ID JENGA_CHECKLIST_SESSION_ID
  unset CLAUDE_PROJECT_DIR COPILOT_WORKSPACE_FOLDER JENGA_PROJECT_DIR JENGA_AGENT_TYPE CLAUDE_AGENT_TYPE
  unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR GIT_PREFIX
  : >"$BATS_TEST_TMPDIR/gitconfig"
  export GIT_CONFIG_GLOBAL="$BATS_TEST_TMPDIR/gitconfig" GIT_CONFIG_NOSYSTEM=1

  PROJ="$(cd "$BATS_TEST_TMPDIR" && pwd -P)/proj"
  mkdir -p "$PROJ/scripts" "$PROJ/project/configs"
  local f
  for f in create-task-worktree perceived-branch resolve-root install-worktree-commit-guard; do
    [ -f "$REPO_ROOT/scripts/$f.sh" ] || skip "scripts/$f.sh is not in this tree (the suite exercises it)"
    cp "$REPO_ROOT/scripts/$f.sh" "$PROJ/scripts/$f.sh"
  done

  printf '{"paths":{"queue":"project/queue"}}\n' >"$PROJ/project/configs/workflow.json"
  printf 'project/queue/perceived-branch/\n.claude/worktrees/\n' >"$PROJ/.gitignore"
  printf 'base\n' >"$PROJ/shared.txt"

  git -C "$PROJ" init -q
  git -C "$PROJ" symbolic-ref HEAD refs/heads/main
  git -C "$PROJ" config user.name "bats"
  git -C "$PROJ" config user.email "bats@example.invalid"
  git -C "$PROJ" config commit.gpgsign false
  git -C "$PROJ" add -A
  git -C "$PROJ" commit -q -m "initial commit"
  # Safety net for every helper below that writes: they all act on $PROJ, and $PROJ must be its own repository.
  [ "$(git -C "$PROJ" rev-parse --show-toplevel)" = "$PROJ" ]

  export PROJ JENGA_PROJECT_ROOT="$PROJ"

  # Two branches, each with a distinct commit, cut from main. main stays checked out and carries neither commit.
  branch_with_commit feat-a "feature a"
  branch_with_commit feat-b "feature b"
}

# --- helpers ------------------------------------------------------------------------------------------------------

# branch_with_commit <branch> <content>: creates <branch> from main with one extra commit, through a throwaway worktree
# outside the repository, so the main tree's checkout is never moved.
branch_with_commit() {
  local branch="$1" content="$2" tmp="$BATS_TEST_TMPDIR/seed-$1"
  git -C "$PROJ" worktree add -q -b "$branch" "$tmp" main
  printf '%s\n' "$content" >"$tmp/$branch.txt"
  git -C "$tmp" add "$branch.txt"
  git -C "$tmp" commit -q -m "commit on $branch"
  git -C "$PROJ" worktree remove "$tmp"
}

# pb <args...>: the perceived-branch script, run from the fixture's main tree (output discarded; setup of a state).
pb() {
  (cd "$PROJ" && bash "$PROJ/scripts/perceived-branch.sh" "$@") >/dev/null 2>&1
}

tw_path() {
  printf '%s/.claude/worktrees/%s' "$PROJ" "$1"
}

sha() {
  git -C "$PROJ" rev-parse "$1"
}

# make_task <name> <session>: what the WorktreeCreate hook does, in the same order. Cuts <name> from the session's
# perceived branch, then installs the guard for <name> in the new worktree. Fails the test if either step fails.
make_task() {
  local name="$1" session="$2" d
  d="$(tw_path "$name")"
  (cd "$PROJ" && bash "$PROJ/scripts/create-task-worktree.sh" "$d" "$name" --session "$session") >/dev/null 2>&1
  (cd "$PROJ" && bash "$PROJ/scripts/install-worktree-commit-guard.sh" "$d" "$name") >/dev/null 2>&1
  [ "$(git -C "$d" branch --show-current)" = "$name" ]
}

# stage_change <dir> <tag>: stages a new file in <dir>, so a following commit has something to commit.
stage_change() {
  printf '%s\n' "$2" >"$1/change-$2.txt"
  git -C "$1" add "change-$2.txt"
}

# try_commit <dir> <message>: a real `git commit` in <dir> (so the pre-commit hook runs). Status in $status, hook and git
# messages in $stderr, never merged into $output.
try_commit() {
  run --separate-stderr git -C "$1" commit -q -m "$2"
}

# switch_to <dir> <branch>: puts the worktree's HEAD on <branch>, including a branch checked out in another worktree
# (main in the main tree), which a plain checkout would refuse.
switch_to() {
  git -C "$1" checkout -q --ignore-other-worktrees "$2"
  [ "$(git -C "$1" branch --show-current)" = "$2" ]
}

# assert_blocked <task-branch> <current-branch>: the last try_commit was refused by the guard, with its existing message
# naming the assigned branch and the one HEAD was on.
assert_blocked() {
  [ "$status" -ne 0 ]
  assert_contains "$stderr" "pre-commit: commit blocked"
  assert_contains "$stderr" "this worktree is assigned to branch '$1' but HEAD is currently on '$2'"
}

# --- AC: the accept case ------------------------------------------------------------------------------------------

@test "accept: a commit on a task branch cut from a perceived branch succeeds with the guard installed" {
  pb set feat-a --session "$SESS_A"
  make_task t1 "$SESS_A"
  local d="$(tw_path t1)" main_before feat_a_before
  main_before="$(sha main)"
  feat_a_before="$(sha feat-a)"

  # The situation under test: the base is the perceived branch, not the checked-out one.
  [ "$(git -C "$PROJ" branch --show-current)" = "main" ]
  [ "$(sha t1)" = "$feat_a_before" ]
  [ "$feat_a_before" != "$main_before" ]
  # The guard is installed and active for this worktree.
  [ "$(git -C "$d" config --worktree --get core.hooksPath)" != "" ]

  stage_change "$d" one
  try_commit "$d" "work on t1"
  [ "$status" -eq 0 ]
  assert_not_contains "$stderr" "commit blocked"
  [ "$(git -C "$d" rev-parse HEAD^)" = "$feat_a_before" ]
  [ "$(git -C "$d" log -1 --format=%s)" = "work on t1" ]
  [ "$(sha t1)" = "$(git -C "$d" rev-parse HEAD)" ]

  # A second commit is accepted too, and no other branch moved.
  stage_change "$d" two
  try_commit "$d" "more work on t1"
  [ "$status" -eq 0 ]
  [ "$(git -C "$d" rev-list --count "$feat_a_before..HEAD")" = "2" ]
  [ "$(sha feat-a)" = "$feat_a_before" ]
  [ "$(sha main)" = "$main_before" ]
}

@test "accept: without a perceived branch the guard accepts the task branch just the same" {
  make_task t1 "$SESS_A"
  local d="$(tw_path t1)"
  [ "$(sha t1)" = "$(sha main)" ]
  stage_change "$d" one
  try_commit "$d" "work on t1"
  [ "$status" -eq 0 ]
}

# --- AC: the reject case ------------------------------------------------------------------------------------------

@test "reject: a commit with the worktree's HEAD on main is blocked with the guard's message and creates no commit" {
  pb set feat-a --session "$SESS_A"
  make_task t1 "$SESS_A"
  local d="$(tw_path t1)" main_before
  main_before="$(sha main)"
  switch_to "$d" main
  stage_change "$d" one
  try_commit "$d" "should not land on main"
  assert_blocked t1 main
  [ "$(sha main)" = "$main_before" ]
  [ "$(git -C "$d" rev-parse HEAD)" = "$main_before" ]
  # The change is still staged: the guard refused, it did not discard anything.
  [ "$(git -C "$d" diff --cached --name-only)" = "change-one.txt" ]
}

@test "reject: a commit with the worktree's HEAD on the perceived branch is blocked" {
  pb set feat-a --session "$SESS_A"
  make_task t1 "$SESS_A"
  local d="$(tw_path t1)" feat_a_before
  feat_a_before="$(sha feat-a)"
  switch_to "$d" feat-a
  stage_change "$d" one
  try_commit "$d" "should not land on feat-a"
  assert_blocked t1 feat-a
  [ "$(sha feat-a)" = "$feat_a_before" ]
}

@test "reject: a commit with the worktree's HEAD on any other branch is blocked" {
  pb set feat-a --session "$SESS_A"
  make_task t1 "$SESS_A"
  local d="$(tw_path t1)" feat_b_before
  feat_b_before="$(sha feat-b)"
  switch_to "$d" feat-b
  stage_change "$d" one
  try_commit "$d" "should not land on feat-b"
  assert_blocked t1 feat-b
  [ "$(sha feat-b)" = "$feat_b_before" ]

  # A fresh branch cut from the task branch is "another branch" as well.
  switch_to "$d" t1
  git -C "$d" checkout -q -b scratch
  try_commit "$d" "should not land on scratch"
  assert_blocked t1 scratch
  [ "$(git -C "$d" rev-list --count t1..scratch)" = "0" ]
}

@test "reject: a commit on a detached HEAD is blocked" {
  pb set feat-a --session "$SESS_A"
  make_task t1 "$SESS_A"
  local d="$(tw_path t1)" before
  before="$(git -C "$d" rev-parse HEAD)"
  git -C "$d" checkout -q --detach
  stage_change "$d" one
  try_commit "$d" "should not land detached"
  assert_blocked t1 HEAD
  [ "$(git -C "$d" rev-parse HEAD)" = "$before" ]
}

@test "the guard is not sticky: back on the task branch the same worktree commits again" {
  pb set feat-a --session "$SESS_A"
  make_task t1 "$SESS_A"
  local d="$(tw_path t1)"
  switch_to "$d" main
  stage_change "$d" one
  try_commit "$d" "blocked on main"
  assert_blocked t1 main
  switch_to "$d" t1
  try_commit "$d" "accepted on t1"
  [ "$status" -eq 0 ]
  [ "$(git -C "$d" log -1 --format=%s)" = "accepted on t1" ]
}

# --- AC: two worktrees, two bases ---------------------------------------------------------------------------------

@test "two worktrees cut from two different perceived bases each accept their own branch and reject everything else" {
  pb set feat-a --session "$SESS_A"
  pb set feat-b --session "$SESS_B"
  make_task from-a "$SESS_A"
  make_task from-b "$SESS_B"
  local da="$(tw_path from-a)" db="$(tw_path from-b)"
  [ "$(sha from-a)" = "$(sha feat-a)" ]
  [ "$(sha from-b)" = "$(sha feat-b)" ]

  # Each guard names only its own worktree's branch.
  local hook_a hook_b
  hook_a="$(git -C "$da" config --worktree --get core.hooksPath)/pre-commit"
  hook_b="$(git -C "$db" config --worktree --get core.hooksPath)/pre-commit"
  [ "$hook_a" != "$hook_b" ]
  assert_contains "$(cat "$hook_a")" "expected_branch=\"from-a\""
  assert_not_contains "$(cat "$hook_a")" "from-b"
  assert_contains "$(cat "$hook_b")" "expected_branch=\"from-b\""
  assert_not_contains "$(cat "$hook_b")" "from-a"

  # Both accept a commit on their own task branch (in either order).
  stage_change "$db" b1
  try_commit "$db" "work in from-b"
  [ "$status" -eq 0 ]
  stage_change "$da" a1
  try_commit "$da" "work in from-a"
  [ "$status" -eq 0 ]
  [ "$(git -C "$da" rev-parse HEAD^)" = "$(sha feat-a)" ]
  [ "$(git -C "$db" rev-parse HEAD^)" = "$(sha feat-b)" ]

  # Each rejects the other's perceived base, the other's task branch and main, naming its own branch.
  switch_to "$da" feat-b
  stage_change "$da" a2
  try_commit "$da" "from-a on feat-b"
  assert_blocked from-a feat-b
  switch_to "$db" feat-a
  stage_change "$db" b2
  try_commit "$db" "from-b on feat-a"
  assert_blocked from-b feat-a

  switch_to "$da" from-b
  try_commit "$da" "from-a on from-b"
  assert_blocked from-a from-b
  switch_to "$db" main
  try_commit "$db" "from-b on main"
  assert_blocked from-b main

  # Neither refusal touched the other worktree: back on their own branches both still commit.
  switch_to "$da" from-a
  try_commit "$da" "from-a again"
  [ "$status" -eq 0 ]
  switch_to "$db" from-b
  try_commit "$db" "from-b again"
  [ "$status" -eq 0 ]
}

@test "the guards are per worktree: the main tree has none and still commits on main" {
  pb set feat-a --session "$SESS_A"
  make_task t1 "$SESS_A"
  # No repo-wide hooksPath was written, and the main tree resolves none of its own.
  run --separate-stderr git -C "$PROJ" config --get core.hooksPath
  [ "$status" -ne 0 ]
  [ -z "$output" ]
  run --separate-stderr git -C "$PROJ" config --worktree --get core.hooksPath
  [ -z "$output" ]

  stage_change "$PROJ" main1
  try_commit "$PROJ" "commit on main in the main tree"
  [ "$status" -eq 0 ]
  assert_not_contains "$stderr" "commit blocked"
  [ "$(git -C "$PROJ" log -1 --format=%s)" = "commit on main in the main tree" ]
}
