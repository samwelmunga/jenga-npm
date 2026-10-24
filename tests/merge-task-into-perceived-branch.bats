#!/usr/bin/env bats
#
# Coverage for merging finished task work into the session's perceived branch (E78_S02_T07).
#
# Contract under test:
#   - scripts/merge-task-into-perceived-branch.sh   header comment: USAGE, EXIT STATUSES, DEDICATED WORKTREE (E78_S02_T04)
#   - scripts/create-task-worktree.sh               cuts a task worktree from the perceived branch (E78_S02_T02)
#   - scripts/perceived-branch.sh                   the per-session state both scripts read (E78_S01_T02)
#   - scripts/install-worktree-commit-guard.sh      the task-worktree commit guard the dedicated worktree must escape
#   - scripts/worktree-remove-guard.sh              the liveness-checked removal that --cleanup goes through
#
# Isolation. Every test builds its own throwaway git repository ($PROJ, under $BATS_TEST_TMPDIR) on branch "main", with
# one commit, no remote and nothing pushed or fetched. The scripts under test are COPIED into $BIN, a directory outside
# that repository, so the fixture's own history, status and branches hold nothing but fixture content. The repository
# this suite lives in is only READ (the scripts are copied out of it); its branches, worktrees, project/logs and
# project/queue are never written. The fixture ignores ".claude/worktrees/" and "project/queue/perceived-branch/"
# exactly as the real .gitignore does, so `git status` in the fixture's main tree stays comparable.
#
# Session identity is injected through --session <key> (or one explicit variable for one test), never through the
# developer's real environment: setup unsets CLAUDE_CODE_SESSION_ID, JENGA_SESSION_ID, CLAUDE_SESSION_ID and
# JENGA_CHECKLIST_SESSION_ID. The queue directory is redirected into the fixture through JENGA_PROJECT_ROOT, which
# scripts/resolve-root.sh honours. Every test starts with perceived branch "feat-a" set for session "sess-A" (the
# fixture of the task description); tests that need another state use other session keys.
#
# bats `run` merges stderr into $output unless `run --separate-stderr` is used, so every test that looks at stdout or
# stderr on its own goes through run_mt / run_pb below, which use it. Assertions use `[ ... ]` and the helpers in
# tests/helpers/assertions.bash, never a bare `[[ ... ]]` (inert under bats), and no assertion negates a command with
# `!` (also exempt from errexit): "absent" checks go through the not_* / no_* functions below, which are ordinary
# commands whose failure aborts the test.
#
# Public mirror. Every script exercised here classifies PUBLIC (scripts/check-publicignore-match.sh), so the suite
# ships too and must pass in the ship set. It reads no board file, no project/documentation file and nothing
# untracked. A script it copies that is absent from the tree makes setup skip, with the script named in the reason; it
# never passes silently.
#
# Fixed expectations worth knowing when one of them fails:
#   - exit statuses: 0 applied, 1 usage, 2 conflict, 3 not applicable, 4 perceived branch missing, 6 perceived branch
#     checked out elsewhere, 7 worktree or git problem (header of the merge script);
#   - the dedicated worktree is <main tree>/.claude/worktrees/perceived-<sanitised branch>-<cksum of the branch name>;
#   - a merge commit has the subject "merge: <task-branch> into <perceived>".

bats_require_minimum_version 1.5.0
load helpers/assertions

REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"

SESS="sess-A"

setup() {
  command -v jq >/dev/null 2>&1 || skip "jq is not installed (scripts/perceived-branch.sh requires it)"
  command -v git >/dev/null 2>&1 || skip "git is not installed"

  # The developer's real environment must not leak a session key, a project dir or a git context into the fixture.
  unset CLAUDE_CODE_SESSION_ID JENGA_SESSION_ID CLAUDE_SESSION_ID JENGA_CHECKLIST_SESSION_ID
  unset CLAUDE_PROJECT_DIR COPILOT_WORKSPACE_FOLDER JENGA_PROJECT_DIR JENGA_AGENT_TYPE CLAUDE_AGENT_TYPE
  unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR GIT_PREFIX WORKTREE_REMOVE_FORCE_IGNORE_LIVENESS
  : >"$BATS_TEST_TMPDIR/gitconfig"
  export GIT_CONFIG_GLOBAL="$BATS_TEST_TMPDIR/gitconfig" GIT_CONFIG_NOSYSTEM=1

  BIN="$(cd "$BATS_TEST_TMPDIR" && pwd -P)/bin"
  PROJ="$(cd "$BATS_TEST_TMPDIR" && pwd -P)/proj"
  mkdir -p "$BIN" "$PROJ/project/configs"
  local f
  for f in perceived-branch resolve-root merge-task-into-perceived-branch create-task-worktree \
    install-worktree-commit-guard worktree-remove-guard check-worktree-liveness; do
    [ -f "$REPO_ROOT/scripts/$f.sh" ] || skip "scripts/$f.sh is not in this tree (the suite exercises it)"
    cp "$REPO_ROOT/scripts/$f.sh" "$BIN/$f.sh"
  done

  printf '{"paths":{"queue":"project/queue"}}\n' >"$PROJ/project/configs/workflow.json"
  printf 'project/queue/perceived-branch/\n.claude/worktrees/\n' >"$PROJ/.gitignore"
  printf 'base\n' >"$PROJ/shared.txt"
  printf 'base\n' >"$PROJ/second.txt"

  git -C "$PROJ" init -q
  git -C "$PROJ" symbolic-ref HEAD refs/heads/main
  git -C "$PROJ" config user.name "bats"
  git -C "$PROJ" config user.email "bats@example.invalid"
  git -C "$PROJ" config commit.gpgsign false
  git -C "$PROJ" add -A
  git -C "$PROJ" commit -q -m "initial commit"
  # Safety net for every helper below that writes: they all act on $PROJ, and $PROJ must be its own repository.
  [ "$(git -C "$PROJ" rev-parse --show-toplevel)" = "$PROJ" ]

  export BIN PROJ JENGA_PROJECT_ROOT="$PROJ"

  # The fixture of the task description: a perceived branch feat-a (created from main, main stays checked out).
  (cd "$PROJ" && bash "$BIN/perceived-branch.sh" set feat-a --session "$SESS") >/dev/null 2>&1
}

# --- helpers ------------------------------------------------------------------------------------------------------

# mt [args...]: the merge script, run from the fixture's main tree.
mt() {
  (cd "$PROJ" && bash "$BIN/merge-task-into-perceived-branch.sh" "$@")
}

# run_mt [args...]: runs the merge script with stdout in $output and stderr in $stderr (never merged). The session key
# is NOT added: pass --session yourself, so a test can also exercise the other ways of supplying one.
run_mt() {
  run --separate-stderr mt "$@"
}

# run_pb [args...]: runs scripts/perceived-branch.sh from the fixture's main tree, stdout and stderr kept apart.
run_pb() {
  run --separate-stderr bash -c 'cd "$0" && bash "$BIN/perceived-branch.sh" "$@"' "$PROJ" "$@"
}

# run_ctw <dir> <name> [args...]: runs scripts/create-task-worktree.sh from the fixture's main tree.
run_ctw() {
  run --separate-stderr bash -c 'cd "$0" && bash "$BIN/create-task-worktree.sh" "$@"' "$PROJ" "$@"
}

sha() {
  git -C "$PROJ" rev-parse "$1"
}

# tw_path <name>: where a task worktree of this fixture lives.
tw_path() {
  printf '%s/.claude/worktrees/%s' "$PROJ" "$1"
}

# ded_path <perceived-branch>: where the dedicated worktree for that branch must live (the documented naming rule:
# characters outside [A-Za-z0-9._-] become "-", shortened to 60, then "-" and the cksum of the unmodified name).
ded_path() {
  local slug sum
  slug="$(printf '%s' "$1" | tr -c 'A-Za-z0-9._-' '-' | cut -c1-60)"
  sum="$(printf '%s' "$1" | cksum | awk '{ print $1 }')"
  printf '%s/.claude/worktrees/perceived-%s-%s' "$PROJ" "$slug" "$sum"
}

# new_task <name> <file> <content> [session]: cuts task worktree <name> from the perceived branch through
# create-task-worktree.sh (as the WorktreeCreate hook does), then commits <file> in it.
new_task() {
  local name="$1" file="$2" content="$3" key="${4:-$SESS}"
  (cd "$PROJ" && bash "$BIN/create-task-worktree.sh" "$(tw_path "$name")" "$name" --session "$key") >/dev/null 2>&1
  printf '%s\n' "$content" >"$(tw_path "$name")/$file"
  git -C "$(tw_path "$name")" add "$file"
  git -C "$(tw_path "$name")" commit -q -m "task $name"
}

# commit_on <branch> <file> <content>: commits <file> on <branch> without moving any checkout of the fixture, through a
# throwaway worktree outside the repository. The branch must not be checked out anywhere.
commit_on() {
  local branch="$1" file="$2" content="$3" tmp="$BATS_TEST_TMPDIR/commit-on"
  git -C "$PROJ" worktree add -q "$tmp" "$branch"
  printf '%s\n' "$content" >"$tmp/$file"
  git -C "$tmp" add "$file"
  git -C "$tmp" commit -q -m "advance $branch"
  git -C "$PROJ" worktree remove "$tmp"
}

# A fingerprint of everything "the main tree was not touched" means: branch, HEAD, `git status --porcelain`, the
# content of the tracked changes and of the untracked dirt file.
snap() {
  printf 'branch=%s\nhead=%s\n' "$(git -C "$PROJ" branch --show-current)" "$(git -C "$PROJ" rev-parse HEAD)"
  git -C "$PROJ" status --porcelain
  git -C "$PROJ" diff | cksum
  if [ -f "$PROJ/dirty.txt" ]; then cksum <"$PROJ/dirty.txt"; fi
}

# dirty_main: leaves a tracked modification and an untracked file in the main tree, so a stray checkout, reset or
# stash somewhere would have something visible to destroy.
dirty_main() {
  printf 'local edit\n' >>"$PROJ/second.txt"
  printf 'untracked work\n' >"$PROJ/dirty.txt"
}

# all_refs: every ref and the commit it points at (a snapshot of "no ref was created or moved").
all_refs() {
  git -C "$PROJ" for-each-ref --format='%(refname) %(objectname)'
}

# wt_count: the number of registered worktrees (the main tree counts as one).
wt_count() {
  git -C "$PROJ" worktree list --porcelain | grep -c '^worktree '
}

# holders_of <branch>: the number of registered worktrees that have <branch> checked out.
holders_of() {
  git -C "$PROJ" worktree list --porcelain | grep -c "^branch refs/heads/$1\$" || true
}

is_ancestor() {
  git -C "$PROJ" merge-base --is-ancestor "$1" "$2"
}

not_ancestor() {
  if git -C "$PROJ" merge-base --is-ancestor "$1" "$2"; then
    return 1
  fi
  return 0
}

no_merge_in_progress() {
  if git -C "$1" rev-parse -q --verify MERGE_HEAD >/dev/null 2>&1; then
    return 1
  fi
  return 0
}

no_branch() {
  if git -C "$PROJ" show-ref --verify --quiet "refs/heads/$1"; then
    return 1
  fi
  return 0
}

no_path() {
  [ ! -e "$1" ]
}

# --- usage -----------------------------------------------------------------------------------------------------------

@test "help prints the usage block on stdout and exits 0, for -h, --help and help" {
  local flag
  for flag in -h --help help; do
    run_mt "$flag"
    [ "$status" -eq 0 ]
    assert_output_contains "merge-task-into-perceived-branch.sh <task-branch> [--session <key>]"
    assert_output_contains "--cleanup [--branch <name> | --all]"
    [ -z "$stderr" ]
  done
}

@test "usage errors exit 1, name the problem on stderr, print nothing on stdout and create no worktree" {
  git -C "$PROJ" branch T-x feat-a
  local before_refs before_count
  before_refs="$(all_refs)"
  before_count="$(wt_count)"

  run_mt
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  assert_contains "$stderr" "missing <task-branch>"

  run_mt --bogus T-x --session "$SESS"
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  assert_contains "$stderr" "unknown option '--bogus'"

  run_mt T-x other --session "$SESS"
  [ "$status" -eq 1 ]
  assert_contains "$stderr" "only one <task-branch>"

  run_mt T-x --session
  [ "$status" -eq 1 ]
  assert_contains "$stderr" "--session needs a key"

  run_mt T-x --branch feat-a --session "$SESS"
  [ "$status" -eq 1 ]
  assert_contains "$stderr" "only apply to --cleanup"

  run_mt T-x --all --session "$SESS"
  [ "$status" -eq 1 ]
  assert_contains "$stderr" "only apply to --cleanup"

  run_mt --cleanup T-x --session "$SESS"
  [ "$status" -eq 1 ]
  assert_contains "$stderr" "--cleanup takes no <task-branch>"

  run_mt --cleanup --branch feat-a --all --session "$SESS"
  [ "$status" -eq 1 ]
  assert_contains "$stderr" "mutually exclusive"

  run_mt T-x --session "../escape"
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  assert_contains "$stderr" "rejected the session key"

  [ "$(all_refs)" = "$before_refs" ]
  [ "$(wt_count)" = "$before_count" ]
  no_path "$(ded_path feat-a)"
}

@test "a task branch that is not a local branch, and the perceived branch itself, exit 1 and create no worktree" {
  local before_refs
  before_refs="$(all_refs)"

  run_mt no-such-branch --session "$SESS"
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  assert_contains "$stderr" "'no-such-branch' is not a local branch"

  run_mt feat-a --session "$SESS"
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  assert_contains "$stderr" "is the perceived branch itself"

  [ "$(all_refs)" = "$before_refs" ]
  [ "$(wt_count)" = "1" ]
  no_path "$(ded_path feat-a)"
}

@test "outside a git repository the script exits 7 and says so" {
  mkdir -p "$BATS_TEST_TMPDIR/nogit"
  run --separate-stderr env GIT_CEILING_DIRECTORIES="$BATS_TEST_TMPDIR" \
    bash -c 'cd "$0" && bash "$BIN/merge-task-into-perceived-branch.sh" T-x --session sess-A' "$BATS_TEST_TMPDIR/nogit"
  [ "$status" -eq 7 ]
  [ -z "$output" ]
  assert_contains "$stderr" "not inside a git repository"
}

# --- AC: a full task cycle ends with the work on the perceived branch and the main tree untouched ----------------------

@test "full task cycle: create worktree from feat-a, commit, merge, remove - work is on feat-a, not main, main tree untouched" {
  dirty_main
  local before main_tip feat_tip
  before="$(snap)"
  main_tip="$(sha main)"
  feat_tip="$(sha feat-a)"
  # Sanity: the fingerprint really sees the dirt and the branch (a vacuous snapshot would make this test inert), and
  # the fixture's ignore rules keep the worktree directory out of `git status`.
  assert_contains "$before" "branch=main"
  assert_contains "$before" " M second.txt"
  assert_contains "$before" "?? dirty.txt"
  assert_not_contains "$before" ".claude"

  new_task T-cycle task.txt "task work"
  # The task branch was cut from the perceived branch's tip (create-task-worktree.sh), not from main's HEAD.
  [ "$(sha T-cycle~1)" = "$feat_tip" ]
  local task_commit
  task_commit="$(sha T-cycle)"

  run_mt T-cycle --session "$SESS"
  [ "$status" -eq 0 ]
  assert_output_contains "applied: merged T-cycle into feat-a as "
  assert_output_contains "$(ded_path feat-a)"
  [ -z "$stderr" ]

  # The task commit is reachable from feat-a and from nothing main points at.
  is_ancestor "$task_commit" feat-a
  not_ancestor "$task_commit" main
  [ "$(sha main)" = "$main_tip" ]
  # feat-a moved by a real merge commit (two parents), with the documented subject.
  [ "$(git -C "$PROJ" log -1 --format=%s feat-a)" = "merge: T-cycle into feat-a" ]
  [ "$(git -C "$PROJ" log -1 --format=%p feat-a | wc -w | tr -d ' ')" = "2" ]
  [ "$(git -C "$PROJ" show feat-a:task.txt)" = "task work" ]

  # The task worktree is then removed; the merged work stays on feat-a.
  git -C "$PROJ" worktree remove "$(tw_path T-cycle)"
  no_path "$(tw_path T-cycle)"
  is_ancestor "$task_commit" feat-a

  # The main tree: same branch, same HEAD, same `git status --porcelain`, same dirt, and the merged file is not there.
  [ "$(git -C "$PROJ" branch --show-current)" = "main" ]
  [ "$(snap)" = "$before" ]
  no_path "$PROJ/task.txt"
}

@test "the merge can be started from inside a task worktree and still merges in the dedicated worktree, main tree untouched" {
  dirty_main
  local before
  before="$(snap)"
  new_task T-inside task.txt "from inside"
  local task_commit
  task_commit="$(sha T-inside)"

  run --separate-stderr bash -c 'cd "$0" && bash "$BIN/merge-task-into-perceived-branch.sh" T-inside --session sess-A' "$(tw_path T-inside)"
  [ "$status" -eq 0 ]
  assert_output_contains "applied: merged T-inside into feat-a"
  # Located through "git worktree list", so the dedicated worktree sits under the MAIN tree, not under the task worktree.
  assert_output_contains "worktree $(ded_path feat-a))"
  is_ancestor "$task_commit" feat-a
  not_ancestor "$task_commit" main
  [ "$(snap)" = "$before" ]
}

@test "the session can come from JENGA_CHECKLIST_SESSION_ID and from --session=<key> instead of --session <key>" {
  new_task T-env env.txt "env"
  new_task T-form form.txt "form"

  export JENGA_CHECKLIST_SESSION_ID="$SESS"
  run_mt T-env
  unset JENGA_CHECKLIST_SESSION_ID
  [ "$status" -eq 0 ]
  assert_output_contains "applied: merged T-env into feat-a"

  run_mt T-form "--session=$SESS"
  [ "$status" -eq 0 ]
  assert_output_contains "applied: merged T-form into feat-a"
  is_ancestor T-env feat-a
  is_ancestor T-form feat-a
}

# --- AC: "not applicable" ---------------------------------------------------------------------------------------------

@test "no perceived branch set: exit 3, one line saying so on stdout, no ref or worktree created or moved" {
  dirty_main
  git -C "$PROJ" branch T-x feat-a
  local before before_refs
  before="$(snap)"
  before_refs="$(all_refs)"

  # A session that never set one, then the same with no resolvable session key at all.
  run_mt T-x --session sess-none
  [ "$status" -eq 3 ]
  assert_output_contains "not applicable: no perceived branch is set for this session"
  [ "$(printf '%s\n' "$output" | wc -l | tr -d ' ')" = "1" ]
  [ -z "$stderr" ]

  run_mt T-x
  [ "$status" -eq 3 ]
  assert_output_contains "not applicable: no perceived branch is set for this session"

  [ "$(all_refs)" = "$before_refs" ]
  [ "$(wt_count)" = "1" ]
  no_path "$(ded_path feat-a)"
  no_path "$PROJ/.claude/worktrees"
  [ "$(snap)" = "$before" ]
}

@test "perceived branch equal to the checked-out branch: exit 3, nothing created, nothing moved" {
  dirty_main
  run_pb set main --session sess-main
  [ "$status" -eq 0 ]
  git -C "$PROJ" branch T-x feat-a
  local before before_refs
  before="$(snap)"
  before_refs="$(all_refs)"

  run_mt T-x --session sess-main
  [ "$status" -eq 3 ]
  assert_output_contains "not applicable: the perceived branch main is the main tree's checked-out branch"
  [ -z "$stderr" ]

  [ "$(all_refs)" = "$before_refs" ]
  [ "$(wt_count)" = "1" ]
  no_path "$PROJ/.claude/worktrees"
  [ "$(snap)" = "$before" ]
}

@test "a detached HEAD in the main tree has no real branch name, so a set perceived branch still applies" {
  new_task T-x x.txt "x"
  git -C "$PROJ" checkout -q --detach
  local head_before
  head_before="$(sha HEAD)"

  run_mt T-x --session "$SESS"
  [ "$status" -eq 0 ]
  assert_output_contains "applied: merged T-x into feat-a"
  [ "$(sha HEAD)" = "$head_before" ]
  [ "$(git -C "$PROJ" branch --show-current)" = "" ]
}

# --- AC: conflicts ---------------------------------------------------------------------------------------------------

@test "a conflicting task branch: exit 2, conflicted paths named, dedicated worktree clean with no merge in progress, main tree untouched" {
  dirty_main
  new_task T-conf shared.txt "task side"
  # A second conflicting file, written in the same task commit stack.
  printf 'task side 2\n' >"$(tw_path T-conf)/second.txt"
  git -C "$(tw_path T-conf)" add second.txt
  git -C "$(tw_path T-conf)" commit -q -m "task T-conf second file"
  # feat-a moves on, editing the same two files differently.
  commit_on feat-a shared.txt "perceived side"
  commit_on feat-a second.txt "perceived side 2"
  local before feat_tip
  feat_tip="$(sha feat-a)"
  before="$(snap)"

  run_mt T-conf --session "$SESS"
  [ "$status" -eq 2 ]
  assert_output_contains "conflict: merging T-conf into feat-a conflicted; the merge was aborted"
  # The paths follow the "conflict:" line, one per line.
  printf '%s\n' "$output" | grep -qx 'shared.txt'
  printf '%s\n' "$output" | grep -qx 'second.txt'

  local ded
  ded="$(ded_path feat-a)"
  [ -d "$ded" ]
  no_merge_in_progress "$ded"
  [ -z "$(git -C "$ded" status --porcelain)" ]
  # feat-a is where it was and its files carry no conflict markers.
  [ "$(sha feat-a)" = "$feat_tip" ]
  [ "$(cat "$ded/shared.txt")" = "perceived side" ]
  not_ancestor T-conf feat-a
  [ "$(snap)" = "$before" ]
}

@test "after a conflict the same dedicated worktree is reused for the next, clean merge" {
  new_task T-conf shared.txt "task side"
  commit_on feat-a shared.txt "perceived side"

  run_mt T-conf --session "$SESS"
  [ "$status" -eq 2 ]
  assert_output_contains "shared.txt"

  new_task T-ok ok.txt "fine"
  # T-ok was cut from the (advanced) feat-a, so it merges cleanly.
  run_mt T-ok --session "$SESS"
  [ "$status" -eq 0 ]
  assert_output_contains "applied: merged T-ok into feat-a"
  [ "$(holders_of feat-a)" = "1" ]
  [ "$(printf '%s\n' "$(git -C "$PROJ" worktree list --porcelain | grep '^worktree .*/perceived-')" | wc -l | tr -d ' ')" = "1" ]
}

# --- AC: deleted perceived branch -------------------------------------------------------------------------------------

@test "a deleted perceived branch: exit 4, names it on stderr, merges nothing and never falls back to HEAD" {
  dirty_main
  new_task T-orphan o.txt "orphaned work"
  local task_commit
  task_commit="$(sha T-orphan)"
  git -C "$PROJ" worktree remove "$(tw_path T-orphan)"
  git -C "$PROJ" branch -D feat-a >/dev/null
  no_branch feat-a
  local before before_refs
  before="$(snap)"
  before_refs="$(all_refs)"

  run_mt T-orphan --session "$SESS"
  [ "$status" -eq 4 ]
  [ -z "$output" ]
  assert_contains "$stderr" "the perceived branch feat-a no longer exists; nothing was merged"

  # Nothing merged: the task commit is not on main (the HEAD it must not fall back to), no ref moved or was created,
  # no dedicated worktree was made, and the main tree is as it was.
  not_ancestor "$task_commit" main
  [ "$(all_refs)" = "$before_refs" ]
  [ "$(wt_count)" = "1" ]
  no_path "$(ded_path feat-a)"
  [ "$(snap)" = "$before" ]
  no_path "$PROJ/o.txt"
}

# --- AC: a second merge reuses the dedicated worktree ---------------------------------------------------------------

@test "a second merge reuses the dedicated worktree: exactly one worktree for feat-a in git worktree list" {
  new_task T-one one.txt "one"
  new_task T-two two.txt "two"

  run_mt T-one --session "$SESS"
  [ "$status" -eq 0 ]
  local first_wt
  first_wt="$(printf '%s\n' "$output" | sed -n 's/.*(worktree \(.*\))$/\1/p')"
  [ "$first_wt" = "$(ded_path feat-a)" ]
  [ "$(holders_of feat-a)" = "1" ]

  run_mt T-two --session "$SESS"
  [ "$status" -eq 0 ]
  assert_output_contains "(worktree $first_wt)"
  [ "$(holders_of feat-a)" = "1" ]
  # main tree, two task worktrees, one dedicated worktree: four in all, and one directory named perceived-*.
  [ "$(wt_count)" = "4" ]
  [ "$(ls "$PROJ/.claude/worktrees" | grep -c '^perceived-')" = "1" ]

  # Both task commits ended up on feat-a, which is a chain of two merge commits.
  is_ancestor T-one feat-a
  is_ancestor T-two feat-a
  [ "$(git -C "$PROJ" log -1 --format=%s feat-a)" = "merge: T-two into feat-a" ]
  [ "$(git -C "$PROJ" log -1 --format=%s feat-a~1)" = "merge: T-one into feat-a" ]
}

@test "merging an already merged branch is a successful no-op: exit 0, no new commit" {
  new_task T-once once.txt "once"
  run_mt T-once --session "$SESS"
  [ "$status" -eq 0 ]
  local tip
  tip="$(sha feat-a)"

  run_mt T-once --session "$SESS"
  [ "$status" -eq 0 ]
  assert_output_contains "applied: T-once is already merged into feat-a"
  [ "$(sha feat-a)" = "$tip" ]
  [ "$(holders_of feat-a)" = "1" ]
}

@test "a dedicated worktree whose directory was deleted by hand is re-created by the next merge" {
  new_task T-one one.txt "one"
  new_task T-two two.txt "two"
  run_mt T-one --session "$SESS"
  [ "$status" -eq 0 ]
  rm -rf "$(ded_path feat-a)"

  run_mt T-two --session "$SESS"
  [ "$status" -eq 0 ]
  assert_output_contains "applied: merged T-two into feat-a"
  [ -d "$(ded_path feat-a)" ]
  is_ancestor T-one feat-a
  is_ancestor T-two feat-a
}

# --- dedicated worktree: naming --------------------------------------------------------------------------------------

@test "the dedicated worktree is named perceived-<sanitised branch>-<cksum>, so a/b and a-b get different directories" {
  git -C "$PROJ" branch team/feat-b main
  git -C "$PROJ" branch team-feat-b main
  run_pb set team/feat-b --session sess-slash
  [ "$status" -eq 0 ]
  run_pb set team-feat-b --session sess-dash
  [ "$status" -eq 0 ]
  git -C "$PROJ" branch T-n main

  run_mt T-n --session sess-slash
  [ "$status" -eq 0 ]
  run_mt T-n --session sess-dash
  [ "$status" -eq 0 ]

  [ -d "$(ded_path team/feat-b)" ]
  [ -d "$(ded_path team-feat-b)" ]
  [ "$(ded_path team/feat-b)" != "$(ded_path team-feat-b)" ]
  assert_starts_with "$(basename "$(ded_path team/feat-b)")" "perceived-team-feat-b-"
  # Both live under the main tree's .claude/worktrees, next to the task worktrees.
  assert_starts_with "$(ded_path team/feat-b)" "$PROJ/.claude/worktrees/"
}

# --- other exit statuses ---------------------------------------------------------------------------------------------

@test "perceived branch checked out in another worktree: exit 6, the path named on stderr, nothing merged" {
  local elsewhere
  elsewhere="$(cd "$BATS_TEST_TMPDIR" && pwd -P)/elsewhere"
  git -C "$PROJ" worktree add -q "$elsewhere" feat-a
  git -C "$PROJ" branch T-x main
  local tip
  tip="$(sha feat-a)"

  run_mt T-x --session "$SESS"
  [ "$status" -eq 6 ]
  [ -z "$output" ]
  assert_contains "$stderr" "$elsewhere"
  assert_contains "$stderr" "already checked out"
  assert_contains "$stderr" "Nothing was merged"
  [ "$(sha feat-a)" = "$tip" ]
  no_path "$(ded_path feat-a)"
}

@test "the dedicated path taken by something that is not a worktree: exit 7, left alone, nothing merged" {
  mkdir -p "$(ded_path feat-a)"
  printf 'precious\n' >"$(ded_path feat-a)/keep.txt"
  git -C "$PROJ" branch T-x main
  local tip
  tip="$(sha feat-a)"

  run_mt T-x --session "$SESS"
  [ "$status" -eq 7 ]
  [ -z "$output" ]
  assert_contains "$stderr" "is not a worktree; refusing to use it"
  [ "$(cat "$(ded_path feat-a)/keep.txt")" = "precious" ]
  [ "$(sha feat-a)" = "$tip" ]
}

@test "a dirty dedicated worktree: exit 7, the stray file kept, nothing merged" {
  new_task T-one one.txt "one"
  new_task T-two two.txt "two"
  run_mt T-one --session "$SESS"
  [ "$status" -eq 0 ]
  printf 'stray\n' >"$(ded_path feat-a)/stray.txt"
  local tip
  tip="$(sha feat-a)"

  run_mt T-two --session "$SESS"
  [ "$status" -eq 7 ]
  [ -z "$output" ]
  assert_contains "$stderr" "has changes or a merge in progress; refusing to merge into it"
  [ "$(sha feat-a)" = "$tip" ]
  [ "$(cat "$(ded_path feat-a)/stray.txt")" = "stray" ]
}

@test "a dedicated worktree that was moved off the perceived branch: exit 7 and the reason on stderr" {
  new_task T-one one.txt "one"
  new_task T-two two.txt "two"
  run_mt T-one --session "$SESS"
  [ "$status" -eq 0 ]
  git -C "$(ded_path feat-a)" checkout -q --detach
  local tip
  tip="$(sha feat-a)"

  run_mt T-two --session "$SESS"
  [ "$status" -eq 7 ]
  [ -z "$output" ]
  assert_contains "$stderr" "is registered as a worktree of another branch"
  [ "$(sha feat-a)" = "$tip" ]
}

# --- --cleanup -------------------------------------------------------------------------------------------------------

@test "--cleanup removes the dedicated worktree and leaves the perceived branch, the merged commits and the task worktrees" {
  new_task T-one one.txt "one"
  run_mt T-one --session "$SESS"
  [ "$status" -eq 0 ]
  local tip
  tip="$(sha feat-a)"
  [ -d "$(ded_path feat-a)" ]

  run_mt --cleanup --session "$SESS"
  [ "$status" -eq 0 ]
  assert_output_contains "removed dedicated worktree $(ded_path feat-a)"
  no_path "$(ded_path feat-a)"
  [ "$(holders_of feat-a)" = "0" ]
  [ "$(sha feat-a)" = "$tip" ]
  is_ancestor T-one feat-a
  [ -d "$(tw_path T-one)" ]

  # A later merge simply creates a fresh dedicated worktree.
  new_task T-two two.txt "two"
  run_mt T-two --session "$SESS"
  [ "$status" -eq 0 ]
  [ -d "$(ded_path feat-a)" ]
  is_ancestor T-two feat-a
}

@test "--cleanup with nothing to remove, or no perceived branch, is a successful no-op that says so" {
  run_mt --cleanup --session "$SESS"
  [ "$status" -eq 0 ]
  assert_output_contains "nothing to remove: $(ded_path feat-a) is not a worktree"

  run_mt --cleanup --session sess-none
  [ "$status" -eq 0 ]
  assert_output_contains "nothing to remove: no perceived branch is set"

  run_mt --cleanup --all --session "$SESS"
  [ "$status" -eq 0 ]
  assert_output_contains "nothing to remove: no dedicated perceived-branch worktrees"
  [ "$(wt_count)" = "1" ]
}

@test "--cleanup --branch removes the worktree of a perceived branch that has since been cleared" {
  new_task T-one one.txt "one"
  run_mt T-one --session "$SESS"
  [ "$status" -eq 0 ]
  run_pb clear --session "$SESS"
  [ "$status" -eq 0 ]

  # With the perceived branch cleared, a bare --cleanup cannot know which worktree is meant ...
  run_mt --cleanup --session "$SESS"
  [ "$status" -eq 0 ]
  assert_output_contains "nothing to remove: no perceived branch is set"
  [ -d "$(ded_path feat-a)" ]

  # ... and --branch names it.
  run_mt --cleanup --branch feat-a --session "$SESS"
  [ "$status" -eq 0 ]
  assert_output_contains "removed dedicated worktree $(ded_path feat-a)"
  no_path "$(ded_path feat-a)"
}

@test "--cleanup --all removes every dedicated worktree and nothing else" {
  git -C "$PROJ" branch team/feat-b main
  run_pb set team/feat-b --session sess-B
  [ "$status" -eq 0 ]
  new_task T-one one.txt "one"
  run_mt T-one --session "$SESS"
  [ "$status" -eq 0 ]
  run_mt T-one --session sess-B
  [ "$status" -eq 0 ]
  [ -d "$(ded_path feat-a)" ]
  [ -d "$(ded_path team/feat-b)" ]

  run_mt --cleanup --all --session "$SESS"
  [ "$status" -eq 0 ]
  assert_output_contains "removed dedicated worktree $(ded_path feat-a)"
  assert_output_contains "removed dedicated worktree $(ded_path team/feat-b)"
  no_path "$(ded_path feat-a)"
  no_path "$(ded_path team/feat-b)"
  # The main tree and the task worktree remain.
  [ "$(wt_count)" = "2" ]
  [ -d "$(tw_path T-one)" ]
}

@test "--cleanup refuses a dirty dedicated worktree: exit 7, the files kept" {
  new_task T-one one.txt "one"
  run_mt T-one --session "$SESS"
  [ "$status" -eq 0 ]
  printf 'stray\n' >"$(ded_path feat-a)/stray.txt"

  run_mt --cleanup --session "$SESS"
  [ "$status" -eq 7 ]
  assert_contains "$stderr" "refusing to remove $(ded_path feat-a): it has changes or a merge in progress"
  [ "$(cat "$(ded_path feat-a)/stray.txt")" = "stray" ]
  [ "$(holders_of feat-a)" = "1" ]
}

# --- pinned coupling: "unset" versus "set but deleted" -----------------------------------------------------------------
#
# scripts/create-task-worktree.sh and scripts/merge-task-into-perceived-branch.sh both ask `perceived-branch.sh get
# --perceived`, which exits 1 with EMPTY stdout in two different situations: nothing is set, and the recorded branch
# was deleted. The only thing that tells them apart is the notice "perceived branch <name> no longer exists" on stderr.
# If that wording drifted, a deleted perceived branch would be read as "unset": task worktrees would be cut from HEAD
# and merges would report "not applicable" and fall back to the checked-out branch. These tests turn that into a red
# test instead of silent mis-routing.

@test "pinned coupling: 'get --perceived' exits 1 with empty stdout when nothing is set, and says nothing about a missing branch" {
  run_pb get --perceived --session sess-none
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  assert_not_contains "$stderr" "no longer exists"

  # Positive control: with a branch set and present the same command prints it and exits 0.
  run_pb get --perceived --session "$SESS"
  [ "$status" -eq 0 ]
  [ "$output" = "feat-a" ]
}

@test "pinned coupling: 'get --perceived' exits 1 with empty stdout when the recorded branch was deleted, told apart only by the 'no longer exists' notice" {
  git -C "$PROJ" branch -D feat-a >/dev/null
  no_branch feat-a

  run_pb get --perceived --session "$SESS"
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  # The exact phrase both consumers match on ...
  assert_contains "$stderr" "no longer exists"
  # ... in the exact shape both consumers extract the branch name from.
  [ "$(printf '%s\n' "$stderr" | sed -n 's/.*perceived branch \([^ ]*\) no longer exists.*/\1/p' | head -n 1)" = "feat-a" ]
  [ "$(printf '%s\n' "$stderr" | sed -n 's/^perceived-branch: note: perceived branch \(.*\) no longer exists.*/\1/p' | head -n 1)" = "feat-a" ]
}

@test "pinned coupling: both consumers still match on the phrase 'no longer exists'" {
  grep -qF "grep -q 'no longer exists'" "$BIN/create-task-worktree.sh"
  grep -qF 'NO_LONGER_EXISTS="no longer exists"' "$BIN/merge-task-into-perceived-branch.sh"
  # The producer still writes that phrase, in its notice and its documented contract.
  grep -qF "no longer exists" "$BIN/perceived-branch.sh"
}

@test "pinned coupling, end to end: unset and deleted are routed differently by both consumers" {
  git -C "$PROJ" branch T-x main

  # Unset: the merge script says 'not applicable' (3); the worktree script cuts the task branch from HEAD.
  run_mt T-x --session sess-none
  [ "$status" -eq 3 ]
  run_ctw "$(tw_path T-unset)" T-unset --session sess-none
  [ "$status" -eq 0 ]
  [ "$output" = "$(tw_path T-unset)" ]
  [ "$(sha T-unset)" = "$(sha main)" ]

  # Deleted: both refuse with 4, the worktree script creating nothing and not falling back to HEAD.
  git -C "$PROJ" branch -D feat-a >/dev/null
  local before_refs
  before_refs="$(all_refs)"
  run_mt T-x --session "$SESS"
  [ "$status" -eq 4 ]
  assert_contains "$stderr" "feat-a"
  run_ctw "$(tw_path T-deleted)" T-deleted --session "$SESS"
  [ "$status" -eq 4 ]
  [ -z "$output" ]
  assert_contains "$stderr" "perceived branch 'feat-a' no longer exists"
  assert_contains "$stderr" "HEAD was not used as a fallback"
  no_branch T-deleted
  no_path "$(tw_path T-deleted)"
  [ "$(all_refs)" = "$before_refs" ]
}

# --- the dedicated worktree is not subject to the task-branch commit guard -----------------------------------------------
#
# scripts/install-worktree-commit-guard.sh gives a TASK worktree a pre-commit hook (via a per-worktree core.hooksPath)
# that rejects any commit whose branch is not the task branch. The dedicated worktree is created with a plain
# `git worktree add`, never through that script, so it must not inherit a guard from a sibling task worktree - a guard
# there would reject the dedicated worktree's own commits, whose branch is the perceived branch.
# Note: git does not run the pre-commit hook for an automatic merge commit, so the merge succeeding is the weaker
# half of the evidence. The stronger half is that a plain `git commit` in the dedicated worktree succeeds under the
# same sibling guard, and that core.hooksPath is set for the sibling and not for the dedicated worktree.

@test "the dedicated worktree is not subject to the task-branch commit guard installed in a sibling task worktree" {
  new_task T-one one.txt "one"
  new_task T-two two.txt "two"
  run bash "$BIN/install-worktree-commit-guard.sh" "$(tw_path T-one)" T-one
  [ "$status" -eq 0 ]
  # The guard is live in the sibling: a commit while its HEAD is on another branch is rejected.
  git -C "$(tw_path T-one)" checkout -q -b not-the-task-branch
  printf 'x\n' >"$(tw_path T-one)/x.txt"
  git -C "$(tw_path T-one)" add x.txt
  run git -C "$(tw_path T-one)" commit -q -m "should be blocked"
  [ "$status" -ne 0 ]
  assert_output_contains "commit blocked"
  git -C "$(tw_path T-one)" reset -q --hard
  git -C "$(tw_path T-one)" checkout -q T-one

  # The merge into the perceived branch succeeds with the guard in place (installed BEFORE the dedicated worktree).
  run_mt T-two --session "$SESS"
  [ "$status" -eq 0 ]
  assert_output_contains "applied: merged T-two into feat-a"
  is_ancestor T-two feat-a

  # The guard is private to the sibling: its hooksPath is set there and not in the dedicated worktree.
  [ -n "$(git -C "$(tw_path T-one)" config --get core.hooksPath)" ]
  [ -z "$(git -C "$(ded_path feat-a)" config --get core.hooksPath)" ]
  [ -z "$(git -C "$PROJ" config --get core.hooksPath)" ]

  # An ordinary commit (which does run pre-commit hooks) in the dedicated worktree is not rejected either.
  git -C "$(ded_path feat-a)" commit -q --allow-empty -m "plain commit on the perceived branch"
  [ "$(git -C "$PROJ" log -1 --format=%s feat-a)" = "plain commit on the perceived branch" ]

  # A guard installed in a second sibling AFTER the dedicated worktree exists changes nothing for the next merge.
  new_task T-three three.txt "three"
  run bash "$BIN/install-worktree-commit-guard.sh" "$(tw_path T-three)" T-three
  [ "$status" -eq 0 ]
  run_mt T-three --session "$SESS"
  [ "$status" -eq 0 ]
  assert_output_contains "applied: merged T-three into feat-a"
  is_ancestor T-three feat-a
  [ "$(holders_of feat-a)" = "1" ]
}
