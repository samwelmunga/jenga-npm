#!/usr/bin/env bats
#
# Group 2 of the E86_S05 audit (E86_S05_T02): task branches and worktrees named with three- and four-digit board IDs.
#
# Subject: a branch and worktree named E1001_S100_T100-some-slug is created, merged, listed, matched and removed with
# the repository's own scripts and hooks, and E10_S1_T1-x and E100_S10_T10-x are never taken for one another.
#
#   - settings.json WorktreeCreate / WorktreeRemove hook commands, run verbatim (extracted with jq)
#   - scripts/create-task-worktree.sh, scripts/install-worktree-commit-guard.sh, scripts/worktree-remove-guard.sh
#   - scripts/perceived-branch.sh, scripts/merge-task-into-perceived-branch.sh
#   - scripts/check-worktree-liveness.sh, skills/j-check-in/scripts/collect-liveness.sh (worktree matching, F5/F6)
#   - skills/j-tidy/scripts/classify.sh (the worktree and branch population that /reconcile's sweep hands to /tidy)
#   - skills/j-reconcile/scripts/gather-perceived-branch-evidence.sh (task-ID evidence on a branch)
#
# Isolation. Every test builds its own throwaway repository ($PROJ) under $BATS_TEST_TMPDIR, on branch main, with no
# remote. The scripts the hooks call are COPIED into $PROJ/scripts and $PROJ/lib and committed there, so the hook
# command strings (which resolve everything through `git rev-parse --show-toplevel`) run against the fixture and never
# against this repository. This repository is only read. Nothing here pushes, fetches or touches a real branch or
# worktree. Session identity is injected (JSON session_id, --session), never taken from the developer's environment.
#
# Fixed expectations: the ID prefix of a branch or directory name is never cut; E10_S1_T1-x and E100_S10_T10-x each
# match only themselves. Assertions use `[ ... ]` and tests/helpers/assertions.bash, never a bare `[[ ... ]]`.

bats_require_minimum_version 1.5.0
load helpers/assertions

REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
SETTINGS="$REPO_ROOT/settings.json"

WIDE="E1001_S100_T100-some-slug"
MID="E100_S10_T10-x"
NARROW="E10_S1_T1-x"
SESS="sess-W"

setup() {
  command -v jq >/dev/null 2>&1 || skip "jq is not installed"
  command -v git >/dev/null 2>&1 || skip "git is not installed"

  unset CLAUDE_CODE_SESSION_ID JENGA_SESSION_ID CLAUDE_SESSION_ID JENGA_CHECKLIST_SESSION_ID
  unset CLAUDE_PROJECT_DIR COPILOT_WORKSPACE_FOLDER JENGA_PROJECT_DIR JENGA_AGENT_TYPE CLAUDE_AGENT_TYPE
  unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR GIT_PREFIX WORKTREE_REMOVE_FORCE_IGNORE_LIVENESS
  : >"$BATS_TEST_TMPDIR/gitconfig"
  export GIT_CONFIG_GLOBAL="$BATS_TEST_TMPDIR/gitconfig" GIT_CONFIG_NOSYSTEM=1
  LIVE_PID=""

  PROJ="$(cd "$BATS_TEST_TMPDIR" && pwd -P)/proj"
  mkdir -p "$PROJ/scripts" "$PROJ/lib" "$PROJ/project/configs"
  local f
  for f in perceived-branch resolve-root merge-task-into-perceived-branch create-task-worktree \
    install-worktree-commit-guard worktree-remove-guard check-worktree-liveness; do
    [ -f "$REPO_ROOT/scripts/$f.sh" ] || skip "scripts/$f.sh is not in this tree (the suite exercises it)"
    cp "$REPO_ROOT/scripts/$f.sh" "$PROJ/scripts/$f.sh"
  done
  [ -f "$REPO_ROOT/lib/resolve-project-dir.sh" ] || skip "lib/resolve-project-dir.sh is not in this tree"
  cp "$REPO_ROOT/lib/resolve-project-dir.sh" "$PROJ/lib/resolve-project-dir.sh"

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
  [ "$(git -C "$PROJ" rev-parse --show-toplevel)" = "$PROJ" ]

  export PROJ JENGA_PROJECT_ROOT="$PROJ"
}

teardown() {
  if [ -n "${LIVE_PID:-}" ]; then kill "$LIVE_PID" 2>/dev/null || true; fi
  return 0
}

# --- helpers ------------------------------------------------------------------------------------------------------

tw_path() { printf '%s/.claude/worktrees/%s' "$PROJ" "$1"; }

# hook_cmd <create|remove>: the command string of the WorktreeCreate / WorktreeRemove hook in settings.json.
hook_cmd() {
  case "$1" in
    create) jq -r '.hooks.WorktreeCreate[0].hooks[0].command' "$SETTINGS" ;;
    remove) jq -r '.hooks.WorktreeRemove[0].hooks[0].command' "$SETTINGS" ;;
  esac
}

# run_hook_create <name>: the WorktreeCreate hook, run in the fixture with the JSON the harness sends on stdin.
run_hook_create() {
  local cmd
  cmd="$(hook_cmd create)"
  [ -n "$cmd" ] && [ "$cmd" != null ]
  run --separate-stderr bash -c 'cd "$1" && printf "%s" "$2" | bash -c "$3"' _ "$PROJ" \
    "$(jq -nc --arg n "$1" --arg s "$SESS" '{name: $n, session_id: $s}')" "$cmd"
}

# run_hook_remove <path>: the WorktreeRemove hook, run in the fixture with the JSON the harness sends on stdin.
run_hook_remove() {
  local cmd
  cmd="$(hook_cmd remove)"
  [ -n "$cmd" ] && [ "$cmd" != null ]
  run --separate-stderr bash -c 'cd "$1" && printf "%s" "$2" | bash -c "$3"' _ "$PROJ" \
    "$(jq -nc --arg p "$1" '{worktree_path: $p}')" "$cmd"
}

# wt_names: the basename of every registered worktree of the fixture, one per line.
wt_names() {
  git -C "$PROJ" worktree list --porcelain | awk '/^worktree / { n = split($0, a, "/"); print a[n] }'
}

# wt_branches: every branch checked out in a registered worktree, one per line.
wt_branches() {
  git -C "$PROJ" worktree list --porcelain | sed -n 's|^branch refs/heads/||p'
}

has_line() { printf '%s\n' "$1" | grep -Fxq -- "$2"; }
lacks_line() { ! printf '%s\n' "$1" | grep -Fxq -- "$2"; }

# commit_in <worktree> <file> <content>: one commit touching <file>.
commit_in() {
  printf '%s\n' "$3" >"$1/$2"
  git -C "$1" add "$2"
  git -C "$1" commit -q -m "work $2"
}

# plain_wt <name> [commit-file]: a worktree and branch <name> cut from main without hooks; optionally one commit on it.
plain_wt() {
  git -C "$PROJ" worktree add -q "$(tw_path "$1")" -b "$1" main
  if [ -n "${2:-}" ]; then commit_in "$(tw_path "$1")" "$2" "$1"; fi
}

# live_in <dir>: a process whose cwd is inside <dir>, and wait until the liveness script can see it.
live_in() {
  local i=0 seen=0
  (cd "$1" && exec sleep 120) >/dev/null 2>&1 </dev/null &
  LIVE_PID=$!
  while [ "$i" -lt 50 ]; do
    if ! bash "$REPO_ROOT/scripts/check-worktree-liveness.sh" "$1" >/dev/null 2>&1; then seen=1; break; fi
    i=$((i + 1))
    sleep 0.1
  done
  [ "$seen" -eq 1 ] || { echo "the liveness script never saw PID $LIVE_PID in $1" >&2; return 1; }
}

need_liveness_probe() {
  command -v lsof >/dev/null 2>&1 || [ -d /proc ] || skip "neither lsof nor /proc is available (no liveness probe)"
}

# ===========================================================================
# create, list, commit
# ===========================================================================

@test "WorktreeCreate hook creates branch and worktree $WIDE and prints the path" {
  (cd "$PROJ" && bash scripts/perceived-branch.sh set feat-a --session "$SESS") >/dev/null 2>&1
  run_hook_create "$WIDE"
  [ "$status" -eq 0 ]
  [ "$output" = "$(tw_path "$WIDE")" ]
  [ -d "$(tw_path "$WIDE")" ]
  git -C "$PROJ" show-ref --verify --quiet "refs/heads/$WIDE"
  # cut from the perceived branch, not from HEAD of main (they point at the same commit here, so check the name chain)
  [ "$(git -C "$PROJ" rev-parse "$WIDE")" = "$(git -C "$PROJ" rev-parse feat-a)" ]
  [ "$(git -C "$(tw_path "$WIDE")" symbolic-ref --short HEAD)" = "$WIDE" ]
}

@test "git worktree list shows $WIDE whole: path, directory name and branch keep every digit of the ID" {
  run_hook_create "$WIDE"
  [ "$status" -eq 0 ]
  has_line "$(wt_names)" "$WIDE"
  has_line "$(wt_branches)" "$WIDE"
  lacks_line "$(wt_branches)" "E1001_S100_T10"
  lacks_line "$(wt_branches)" "E1001_S10"
}

@test "the commit guard installed by the hook accepts a commit on $WIDE and refuses one on another branch" {
  run_hook_create "$WIDE"
  [ "$status" -eq 0 ]
  commit_in "$(tw_path "$WIDE")" a.txt one
  git -C "$PROJ" show "$WIDE:a.txt" >/dev/null
  git -C "$(tw_path "$WIDE")" checkout -q -b not-the-task-branch
  printf 'two\n' >"$(tw_path "$WIDE")/b.txt"
  git -C "$(tw_path "$WIDE")" add b.txt
  run git -C "$(tw_path "$WIDE")" commit -q -m "wrong branch"
  [ "$status" -ne 0 ]
  assert_contains "$output" "this worktree is assigned to branch '$WIDE'"
}

@test "create-task-worktree.sh names all three widths without altering them" {
  local n
  for n in "$NARROW" "$MID" "$WIDE"; do
    run --separate-stderr bash -c 'cd "$1" && bash scripts/create-task-worktree.sh "$2" "$3"' _ "$PROJ" "$(tw_path "$n")" "$n"
    [ "$status" -eq 0 ]
    [ "$output" = "$(tw_path "$n")" ]
  done
  local names branches
  names="$(wt_names)"
  branches="$(wt_branches)"
  for n in "$NARROW" "$MID" "$WIDE"; do
    has_line "$names" "$n"
    has_line "$branches" "$n"
  done
}

# ===========================================================================
# merge (perceived branch)
# ===========================================================================

@test "a wide task branch merges into the perceived branch and the merge subject keeps the whole branch name" {
  (cd "$PROJ" && bash scripts/perceived-branch.sh set feat-a --session "$SESS") >/dev/null 2>&1
  run_hook_create "$WIDE"
  [ "$status" -eq 0 ]
  commit_in "$(tw_path "$WIDE")" a.txt one
  run --separate-stderr bash -c 'cd "$1" && bash scripts/merge-task-into-perceived-branch.sh "$2" --session "$3"' _ "$PROJ" "$WIDE" "$SESS"
  [ "$status" -eq 0 ]
  assert_contains "$output" "applied: merged $WIDE into feat-a"
  [ "$(git -C "$PROJ" log -1 --format=%s feat-a)" = "merge: $WIDE into feat-a" ]
  git -C "$PROJ" show "feat-a:a.txt" >/dev/null
  # main was never moved
  [ "$(git -C "$PROJ" rev-parse main)" != "$(git -C "$PROJ" rev-parse feat-a)" ]
}

@test "a wide task branch can itself be the perceived branch: the dedicated worktree name keeps the ID prefix" {
  plain_wt "$WIDE" w.txt
  run --separate-stderr bash -c 'cd "$1" && bash scripts/perceived-branch.sh set "$2" --session "$3"' _ "$PROJ" "$WIDE" "$SESS"
  [ "$status" -eq 0 ]
  plain_wt "$NARROW" n.txt
  # the perceived branch is checked out in its own task worktree, so git forbids the dedicated one: exit 6 names it
  run --separate-stderr bash -c 'cd "$1" && bash scripts/merge-task-into-perceived-branch.sh "$2" --session "$3"' _ "$PROJ" "$NARROW" "$SESS"
  [ "$status" -eq 6 ]
  assert_contains "$stderr" "$WIDE"
  # free the branch, then merge: the dedicated worktree is perceived-<whole branch name>-<cksum>
  git -C "$PROJ" worktree remove "$(tw_path "$WIDE")"
  run --separate-stderr bash -c 'cd "$1" && bash scripts/merge-task-into-perceived-branch.sh "$2" --session "$3"' _ "$PROJ" "$NARROW" "$SESS"
  [ "$status" -eq 0 ]
  assert_contains "$output" "merged $NARROW into $WIDE"
  local sum
  sum="$(printf '%s' "$WIDE" | cksum | awk '{ print $1 }')"
  has_line "$(wt_names)" "perceived-$WIDE-$sum"
  [ "$(git -C "$PROJ" log -1 --format=%s "$WIDE")" = "merge: $NARROW into $WIDE" ]
}

@test "perceived-branch.sh sets, reads, clears and tests existence of a wide-ID branch name" {
  run --separate-stderr bash -c 'cd "$1" && bash scripts/perceived-branch.sh set "$2" --session "$3"' _ "$PROJ" "$WIDE" "$SESS"
  [ "$status" -eq 0 ]
  git -C "$PROJ" show-ref --verify --quiet "refs/heads/$WIDE"
  run --separate-stderr bash -c 'cd "$1" && bash scripts/perceived-branch.sh get --perceived --session "$2"' _ "$PROJ" "$SESS"
  [ "$status" -eq 0 ]
  [ "$output" = "$WIDE" ]
  run bash -c 'cd "$1" && bash scripts/perceived-branch.sh exists "$2"' _ "$PROJ" "$WIDE"
  [ "$status" -eq 0 ]
  run bash -c 'cd "$1" && bash scripts/perceived-branch.sh exists "$2"' _ "$PROJ" "E1001_S100_T10"
  [ "$status" -eq 1 ]
}

# ===========================================================================
# remove
# ===========================================================================

@test "WorktreeRemove hook removes the $WIDE worktree, lists it no more, and keeps the branch" {
  run_hook_create "$WIDE"
  [ "$status" -eq 0 ]
  run_hook_remove "$(tw_path "$WIDE")"
  [ "$status" -eq 0 ]
  [ ! -e "$(tw_path "$WIDE")" ]
  lacks_line "$(wt_names)" "$WIDE"
  git -C "$PROJ" show-ref --verify --quiet "refs/heads/$WIDE"
}

@test "removing one worktree leaves its sibling with the next-shorter ID intact" {
  plain_wt "$NARROW"
  plain_wt "$MID"
  run_hook_remove "$(tw_path "$MID")"
  [ "$status" -eq 0 ]
  lacks_line "$(wt_names)" "$MID"
  has_line "$(wt_names)" "$NARROW"
  [ -d "$(tw_path "$NARROW")" ]
}

# ===========================================================================
# liveness: check-worktree-liveness.sh, collect-liveness.sh
# ===========================================================================

@test "check-worktree-liveness.sh reports a process in $MID only for $MID, never for $NARROW" {
  need_liveness_probe
  plain_wt "$NARROW"
  plain_wt "$MID"
  live_in "$(tw_path "$MID")"
  run bash "$PROJ/scripts/check-worktree-liveness.sh" "$(tw_path "$MID")"
  [ "$status" -eq 1 ]
  run bash "$PROJ/scripts/check-worktree-liveness.sh" "$(tw_path "$NARROW")"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "check-worktree-liveness.sh reports a process in $NARROW only for $NARROW, never for $MID or $WIDE" {
  need_liveness_probe
  plain_wt "$NARROW"
  plain_wt "$MID"
  plain_wt "$WIDE"
  live_in "$(tw_path "$NARROW")"
  run bash "$PROJ/scripts/check-worktree-liveness.sh" "$(tw_path "$NARROW")"
  [ "$status" -eq 1 ]
  run bash "$PROJ/scripts/check-worktree-liveness.sh" "$(tw_path "$MID")"
  [ "$status" -eq 0 ]
  run bash "$PROJ/scripts/check-worktree-liveness.sh" "$(tw_path "$WIDE")"
  [ "$status" -eq 0 ]
}

# Board fixture for collect-liveness.sh: a separate evidence root with board files and worktree directories.
cl_setup() {
  CL="$BATS_TEST_TMPDIR/cl"
  mkdir -p "$CL/project/queue" "$CL/project/logs" "$CL/project/board/tasks" "$CL/.claude/worktrees"
  : >"$CL/project/logs/events.json"
}

cl_item() {
  printf -- '---\nid: %s\nstatus: In Progress\nexecution_scope: task\n---\n' "$1" >"$CL/project/board/tasks/$1_fixture.md"
}

cl_run() {
  export JENGA_PROJECT_ROOT="$CL"
  run --separate-stderr bash "$REPO_ROOT/skills/j-check-in/scripts/collect-liveness.sh" --no-agents
}

cl_codes_for() { printf '%s' "$output" | jq -r --arg id "$1" '[.findings[] | select(.subject.task_id == $id) | .code] | sort | join(",")'; }

@test "collect-liveness.sh matches each In Progress item only to its own worktree (stubbed liveness)" {
  cl_setup
  local id
  for id in E10_S1_T1 E100_S10_T10 E1001_S100_T100; do cl_item "$id"; done
  # only the middle width has a worktree; the other two ids must read as worktree-less (F6), not borrow its directory
  mkdir -p "$CL/.claude/worktrees/$MID"
  printf '#!/bin/bash\nexit 0\n' >"$BATS_TEST_TMPDIR/live-clear.sh"
  export JENGA_LIVENESS_SCRIPT="$BATS_TEST_TMPDIR/live-clear.sh"
  cl_run
  [ "$status" -eq 0 ]
  [ "$(cl_codes_for E100_S10_T10)" = "F5" ]
  [ "$(cl_codes_for E10_S1_T1)" = "F6" ]
  [ "$(cl_codes_for E1001_S100_T100)" = "F6" ]
}

@test "collect-liveness.sh: with only the narrow and wide worktrees present, the middle id is the one without a worktree" {
  cl_setup
  local id
  for id in E10_S1_T1 E100_S10_T10 E1001_S100_T100; do cl_item "$id"; done
  mkdir -p "$CL/.claude/worktrees/$NARROW" "$CL/.claude/worktrees/$WIDE"
  printf '#!/bin/bash\nexit 0\n' >"$BATS_TEST_TMPDIR/live-clear.sh"
  export JENGA_LIVENESS_SCRIPT="$BATS_TEST_TMPDIR/live-clear.sh"
  cl_run
  [ "$status" -eq 0 ]
  [ "$(cl_codes_for E10_S1_T1)" = "F5" ]
  [ "$(cl_codes_for E1001_S100_T100)" = "F5" ]
  [ "$(cl_codes_for E100_S10_T10)" = "F6" ]
}

@test "collect-liveness.sh with the real liveness probe: a live process in $MID silences F5 for $MID alone" {
  need_liveness_probe
  cl_setup
  local id
  for id in E10_S1_T1 E100_S10_T10 E1001_S100_T100; do cl_item "$id"; done
  mkdir -p "$CL/.claude/worktrees/$NARROW" "$CL/.claude/worktrees/$MID" "$CL/.claude/worktrees/$WIDE"
  live_in "$CL/.claude/worktrees/$MID"
  unset JENGA_LIVENESS_SCRIPT
  cl_run
  [ "$status" -eq 0 ]
  [ "$(cl_codes_for E100_S10_T10)" = "" ]
  [ "$(cl_codes_for E10_S1_T1)" = "F5" ]
  [ "$(cl_codes_for E1001_S100_T100)" = "F5" ]
}

# ===========================================================================
# orphan detection: /tidy's classifier (population and verdict) and /reconcile's evidence probe
# ===========================================================================

classify_all() { run --separate-stderr bash "$REPO_ROOT/skills/j-tidy/scripts/classify.sh" --repo "$PROJ" --no-disk; }
crec() { printf '%s\n' "$output" | awk -F'\t' -v n="$1" '$2 == n { print }'; }
cfld() { crec "$1" | cut -f"$2"; }

@test "j-tidy classify.sh tags all three widths board-task and judges each entry on its own content" {
  # the narrow id carries unique work (retained), the middle and wide ids carry none (reclaimable)
  plain_wt "$NARROW" narrow.txt
  plain_wt "$MID"
  plain_wt "$WIDE"
  classify_all
  [ "$status" -eq 0 ]
  local n
  for n in "$NARROW" "$MID" "$WIDE"; do
    [ "$(printf '%s\n' "$output" | awk -F'\t' -v n="$n" '$2 == n' | wc -l | tr -d ' ')" -eq 1 ]
    [ "$(cfld "$n" 1)" = "worktree" ]
    [ "$(cfld "$n" 3)" = "$(tw_path "$n")" ]
    [ "$(cfld "$n" 4)" = "board-task" ]
  done
  [ "$(cfld "$NARROW" 6)" = "retained" ]
  [ "$(cfld "$MID" 6)" = "reclaimable" ]
  [ "$(cfld "$WIDE" 6)" = "reclaimable" ]
}

@test "j-tidy classify.sh: the reverse split also holds (unique work on the middle id only)" {
  plain_wt "$NARROW"
  plain_wt "$MID" mid.txt
  plain_wt "$WIDE"
  classify_all
  [ "$status" -eq 0 ]
  [ "$(cfld "$NARROW" 6)" = "reclaimable" ]
  [ "$(cfld "$MID" 6)" = "retained" ]
  [ "$(cfld "$WIDE" 6)" = "reclaimable" ]
}

@test "j-tidy classify.sh: a live process in $MID retains $MID and leaves $NARROW and $WIDE reclaimable" {
  need_liveness_probe
  plain_wt "$NARROW"
  plain_wt "$MID"
  plain_wt "$WIDE"
  live_in "$(tw_path "$MID")"
  classify_all
  [ "$status" -eq 0 ]
  [ "$(cfld "$MID" 6)" = "retained" ]
  [ "$(cfld "$NARROW" 6)" = "reclaimable" ]
  [ "$(cfld "$WIDE" 6)" = "reclaimable" ]
}

@test "j-tidy classify.sh reports a wide task branch with no worktree as a branch entry named in full" {
  git -C "$PROJ" branch "$WIDE" main
  classify_all
  [ "$status" -eq 0 ]
  [ "$(cfld "$WIDE" 1)" = "branch" ]
  [ "$(cfld "$WIDE" 4)" = "board-task" ]
}

@test "gather-perceived-branch-evidence.sh: a commit naming E10_S1_T10 is not evidence for E10_S1_T1, nor E100_S10_T10 for E10_S1_T1" {
  (cd "$PROJ" && bash scripts/perceived-branch.sh set feat-a --session "$SESS") >/dev/null 2>&1
  printf 'x\n' >"$PROJ/x.txt"
  git -C "$PROJ" add x.txt
  git -C "$PROJ" commit -q -m "task(E10_S1_T10): longer task id"
  printf 'y\n' >"$PROJ/y.txt"
  git -C "$PROJ" add y.txt
  git -C "$PROJ" commit -q -m "task(E100_S10_T10): wide task id"
  local gather="$REPO_ROOT/skills/j-reconcile/scripts/gather-perceived-branch-evidence.sh"
  run --separate-stderr bash -c 'cd "$1" && bash "$2" E10_S1_T1 --session "$3"' _ "$PROJ" "$gather" "$SESS"
  [ "$status" -eq 0 ]
  assert_contains "$output" "evidence_on_real=no"
  run --separate-stderr bash -c 'cd "$1" && bash "$2" E100_S10_T10 --session "$3"' _ "$PROJ" "$gather" "$SESS"
  [ "$status" -eq 0 ]
  assert_contains "$output" "evidence_on_real=yes"
  run --separate-stderr bash -c 'cd "$1" && bash "$2" E10_S1_T10 --session "$3"' _ "$PROJ" "$gather" "$SESS"
  [ "$status" -eq 0 ]
  assert_contains "$output" "evidence_on_real=yes"
}
