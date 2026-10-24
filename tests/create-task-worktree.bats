#!/usr/bin/env bats
#
# Coverage for task worktrees cut from the session's perceived branch (E78_S02_T06).
#
# Contract under test:
#   - scripts/create-task-worktree.sh   header comment: USAGE, BEHAVIOUR (three cases), EXIT CODES (E78_S02_T02)
#   - scripts/perceived-branch.sh       the per-session state the script reads (E78_S01_T02)
#   - settings.json and templates/permission-levels/level-*.json
#                                       the WorktreeCreate hook command that calls the script (E78_S02_T03)
#
# Isolation. Every test builds its own throwaway git repository ($PROJ, under $BATS_TEST_TMPDIR) on branch "main", with
# one commit, no remote and nothing pushed or fetched, plus two branches feat-a and feat-b that each carry a distinct
# commit. The scripts under test are COPIED into the fixture's scripts/ directory (and lib/resolve-project-dir.sh into
# lib/) and committed there, because the WorktreeCreate hook finds them through `git rev-parse --show-toplevel`. The
# repository this suite lives in is only READ (files are copied or parsed out of it); its branches, worktrees,
# project/logs and project/queue are never written. The fixture ignores ".claude/worktrees/" and
# "project/queue/perceived-branch/" exactly as the real .gitignore does, so `git status` in the fixture's main tree stays
# comparable.
#
# Session identity is injected through --session <key> (or one explicit variable for one test), never through the
# developer's real environment: setup unsets CLAUDE_CODE_SESSION_ID, JENGA_SESSION_ID, CLAUDE_SESSION_ID and
# JENGA_CHECKLIST_SESSION_ID, and the project-dir variables the hook probes. The queue directory is redirected into the
# fixture through JENGA_PROJECT_ROOT, which scripts/resolve-root.sh honours.
#
# bats `run` merges stderr into $output unless `run --separate-stderr` is used, so every test that looks at stdout or
# stderr on its own goes through run_ctw / run_hook below, which use it. Assertions use `[ ... ]` and the helpers in
# tests/helpers/assertions.bash, never a bare `[[ ... ]]` (inert under bats), and no assertion negates a command with `!`
# (also exempt from errexit): "absent" checks go through the no_* functions below, which are ordinary commands whose
# failure aborts the test.
#
# Public mirror. Everything this suite reads classifies PUBLIC (scripts/check-publicignore-match.sh): the four scripts,
# lib/resolve-project-dir.sh, settings.json and the five permission-level templates. So the suite ships too and must
# pass in the ship set. It reads no board file, no project/documentation file and nothing untracked. A repo file this
# suite reads that is absent from the tree makes the test that needs it skip, naming the file in the reason; it never
# passes silently.
#
# Fixed expectations worth knowing when one of them fails:
#   - create-task-worktree.sh exits 0 created, 2 usage, 4 perceived branch deleted, 5 perceived branch undeterminable,
#     and git's own status when `git worktree add` fails; stdout is exactly "<dir>" on success and empty otherwise;
#   - the hook command echoes "$JENGA_PROJECT_DIR/.claude/worktrees/<name>" as its only stdout line.

bats_require_minimum_version 1.5.0
load helpers/assertions

REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"

SESS_A="sess-A"
SESS_B="sess-B"

setup() {
  command -v jq >/dev/null 2>&1 || skip "jq is not installed (scripts/perceived-branch.sh and the hook need it)"
  command -v git >/dev/null 2>&1 || skip "git is not installed"

  # The developer's real environment must not leak a session key, a project dir or a git context into the fixture.
  unset CLAUDE_CODE_SESSION_ID JENGA_SESSION_ID CLAUDE_SESSION_ID JENGA_CHECKLIST_SESSION_ID
  unset CLAUDE_PROJECT_DIR COPILOT_WORKSPACE_FOLDER JENGA_PROJECT_DIR JENGA_AGENT_TYPE CLAUDE_AGENT_TYPE
  unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR GIT_PREFIX
  : >"$BATS_TEST_TMPDIR/gitconfig"
  export GIT_CONFIG_GLOBAL="$BATS_TEST_TMPDIR/gitconfig" GIT_CONFIG_NOSYSTEM=1

  PROJ="$(cd "$BATS_TEST_TMPDIR" && pwd -P)/proj"
  mkdir -p "$PROJ/scripts" "$PROJ/lib" "$PROJ/project/configs"
  local f
  for f in create-task-worktree perceived-branch resolve-root install-worktree-commit-guard; do
    [ -f "$REPO_ROOT/scripts/$f.sh" ] || skip "scripts/$f.sh is not in this tree (the suite exercises it)"
    cp "$REPO_ROOT/scripts/$f.sh" "$PROJ/scripts/$f.sh"
  done
  [ -f "$REPO_ROOT/lib/resolve-project-dir.sh" ] || skip "lib/resolve-project-dir.sh is not in this tree (the WorktreeCreate hook sources it)"
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
  # Safety net for every helper below that writes: they all act on $PROJ, and $PROJ must be its own repository.
  [ "$(git -C "$PROJ" rev-parse --show-toplevel)" = "$PROJ" ]

  export PROJ JENGA_PROJECT_ROOT="$PROJ"

  # Two branches, each with a distinct commit, cut from main. main stays checked out and carries neither commit.
  branch_with_commit feat-a "feature a"
  branch_with_commit feat-b "feature b"

  BEFORE="$(snap)"
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

# run_ctw <dir> <name> [args...]: runs create-task-worktree.sh from the fixture's main tree, stdout in $output and
# stderr in $stderr (never merged). The session key is NOT added: pass --session yourself.
run_ctw() {
  run --separate-stderr bash -c 'cd "$0" && bash "$0/scripts/create-task-worktree.sh" "$@"' "$PROJ" "$@"
}

sha() {
  git -C "$PROJ" rev-parse "$1"
}

# tw_path <name>: where a task worktree of this fixture lives.
tw_path() {
  printf '%s/.claude/worktrees/%s' "$PROJ" "$1"
}

# A fingerprint of everything "the main tree was not touched" means: branch, HEAD, `git status --porcelain`, the
# content of any tracked changes and of the untracked dirt file.
snap() {
  printf 'branch=%s\nhead=%s\n' "$(git -C "$PROJ" branch --show-current)" "$(git -C "$PROJ" rev-parse HEAD)"
  git -C "$PROJ" status --porcelain
  git -C "$PROJ" diff | cksum
  if [ -f "$PROJ/dirty.txt" ]; then cksum <"$PROJ/dirty.txt"; fi
}

# assert_main_untouched: the main tree's branch, HEAD, `git status --porcelain` and file content are what setup (or the
# last dirty_main) recorded. Every test ends with it.
assert_main_untouched() {
  local after
  after="$(snap)"
  if [ "$after" != "$BEFORE" ]; then
    printf 'main tree changed\n--- before ---\n%s\n--- after ---\n%s\n' "$BEFORE" "$after"
    return 1
  fi
  [ "$(git -C "$PROJ" branch --show-current)" = "main" ]
}

# dirty_main: leaves a tracked modification and an untracked file in the main tree, so a stray checkout, reset or stash
# would have something visible to destroy. Re-records the fingerprint.
dirty_main() {
  printf 'local edit\n' >>"$PROJ/shared.txt"
  printf 'untracked work\n' >"$PROJ/dirty.txt"
  BEFORE="$(snap)"
}

# all_refs: every ref and the commit it points at (a snapshot of "no ref was created or moved").
all_refs() {
  git -C "$PROJ" for-each-ref --format='%(refname) %(objectname)'
}

# wt_count: the number of registered worktrees (the main tree counts as one).
wt_count() {
  git -C "$PROJ" worktree list --porcelain | grep -c '^worktree '
}

# state_sum: a checksum of every perceived-branch state file (a snapshot of "no session's setting changed").
state_sum() {
  (cd "$PROJ/project/queue/perceived-branch" 2>/dev/null && cat ./*.json | cksum) || printf 'none\n'
}

no_branch() {
  if git -C "$PROJ" show-ref --verify --quiet "refs/heads/$1"; then
    printf 'branch %s exists\n' "$1"
    return 1
  fi
  return 0
}

no_path() {
  if [ -e "$1" ]; then
    printf 'path %s exists\n' "$1"
    return 1
  fi
  return 0
}

# --- AC: no perceived branch --------------------------------------------------------------------------------------

@test "no perceived branch: the worktree starts at the main tree's HEAD, exactly like a plain git worktree add" {
  local d="$(tw_path t1)"
  run_ctw "$d" t1 --session "$SESS_A"
  [ "$status" -eq 0 ]
  [ "$output" = "$d" ]
  [ "$(git -C "$d" rev-parse HEAD)" = "$(sha main)" ]
  [ "$(git -C "$d" branch --show-current)" = "t1" ]
  [ -z "$(git -C "$d" status --porcelain)" ]

  # The control: what the bare call the script replaces produces, in the same repository.
  git -C "$PROJ" worktree add -q "$BATS_TEST_TMPDIR/control" -b control
  [ "$(git -C "$d" rev-parse HEAD)" = "$(git -C "$BATS_TEST_TMPDIR/control" rev-parse HEAD)" ]
  [ "$(git -C "$d" rev-parse 'HEAD^{tree}')" = "$(git -C "$BATS_TEST_TMPDIR/control" rev-parse 'HEAD^{tree}')" ]
  [ "$(git -C "$d" ls-files | cksum)" = "$(git -C "$BATS_TEST_TMPDIR/control" ls-files | cksum)" ]
  git -C "$PROJ" worktree remove "$BATS_TEST_TMPDIR/control"
  assert_main_untouched
}

@test "no session key resolvable at all: treated as no perceived branch, the worktree starts at HEAD" {
  local d="$(tw_path t1)"
  pb set feat-a --session "$SESS_A"
  run_ctw "$d" t1
  [ "$status" -eq 0 ]
  [ "$output" = "$d" ]
  [ "$(git -C "$d" rev-parse HEAD)" = "$(sha main)" ]
  assert_main_untouched
}

@test "a perceived branch set by another session never reaches a session with nothing set" {
  local d="$(tw_path t1)"
  pb set feat-a --session "$SESS_A"
  run_ctw "$d" t1 --session "$SESS_B"
  [ "$status" -eq 0 ]
  [ "$(git -C "$d" rev-parse HEAD)" = "$(sha main)" ]
  [ "$(sha feat-a)" != "$(sha main)" ]
  assert_main_untouched
}

@test "no perceived branch, main tree with local edits: the edits are untouched and the worktree is clean at HEAD" {
  dirty_main
  local d="$(tw_path t1)"
  run_ctw "$d" t1 --session "$SESS_A"
  [ "$status" -eq 0 ]
  [ "$(git -C "$d" rev-parse HEAD)" = "$(sha main)" ]
  [ -z "$(git -C "$d" status --porcelain)" ]
  assert_main_untouched
}

# --- AC: perceived branch set; two sessions in one clone ----------------------------------------------------------------

@test "a perceived branch is the start point; the main tree and the perceived branch itself are untouched" {
  dirty_main
  pb set feat-a --session "$SESS_A"
  local tip_before d="$(tw_path t1)"
  tip_before="$(sha feat-a)"
  run_ctw "$d" t1 --session "$SESS_A"
  [ "$status" -eq 0 ]
  [ "$output" = "$d" ]
  [ "$(git -C "$d" rev-parse HEAD)" = "$tip_before" ]
  [ "$(git -C "$d" branch --show-current)" = "t1" ]
  [ "$(sha t1)" = "$(sha feat-a)" ]
  # feat-a is not checked out by the new worktree (the task branch is), and its tip did not move.
  [ "$(sha feat-a)" = "$tip_before" ]
  [ "$(git -C "$d" show -s --format=%s HEAD)" = "commit on feat-a" ]
  [ -f "$d/feat-a.txt" ]
  assert_main_untouched
}

@test "two sessions in one clone: A's task branch starts at feat-a, B's at feat-b, neither setting affects the other" {
  pb set feat-a --session "$SESS_A"
  pb set feat-b --session "$SESS_B"
  [ "$(sha feat-a)" != "$(sha feat-b)" ]
  local state_before refs_before
  state_before="$(state_sum)"
  refs_before="$(all_refs)"

  run_ctw "$(tw_path from-a)" from-a --session "$SESS_A"
  [ "$status" -eq 0 ]
  run_ctw "$(tw_path from-b)" from-b --session "$SESS_B"
  [ "$status" -eq 0 ]

  [ "$(sha from-a)" = "$(sha feat-a)" ]
  [ "$(sha from-b)" = "$(sha feat-b)" ]
  [ "$(git -C "$(tw_path from-a)" rev-parse HEAD)" = "$(sha feat-a)" ]
  [ "$(git -C "$(tw_path from-b)" rev-parse HEAD)" = "$(sha feat-b)" ]
  [ -f "$(tw_path from-a)/feat-a.txt" ]
  [ -f "$(tw_path from-b)/feat-b.txt" ]
  no_path "$(tw_path from-a)/feat-b.txt"
  no_path "$(tw_path from-b)/feat-a.txt"

  # Creating the worktrees changed no session's setting and moved no pre-existing branch.
  [ "$(state_sum)" = "$state_before" ]
  [ "$(all_refs | grep -v '^refs/heads/from-')" = "$refs_before" ]
  run --separate-stderr bash -c 'cd "$0" && bash scripts/perceived-branch.sh get --perceived --session "$1"' "$PROJ" "$SESS_A"
  [ "$output" = "feat-a" ]
  run --separate-stderr bash -c 'cd "$0" && bash scripts/perceived-branch.sh get --perceived --session "$1"' "$PROJ" "$SESS_B"
  [ "$output" = "feat-b" ]
  assert_main_untouched
}

@test "two sessions in one clone, the other creation order and a third session with nothing set" {
  pb set feat-a --session "$SESS_A"
  pb set feat-b --session "$SESS_B"

  run_ctw "$(tw_path from-b)" from-b --session "$SESS_B"
  [ "$status" -eq 0 ]
  run_ctw "$(tw_path from-a)" from-a --session "$SESS_A"
  [ "$status" -eq 0 ]
  run_ctw "$(tw_path from-c)" from-c --session sess-C
  [ "$status" -eq 0 ]

  [ "$(sha from-a)" = "$(sha feat-a)" ]
  [ "$(sha from-b)" = "$(sha feat-b)" ]
  [ "$(sha from-c)" = "$(sha main)" ]
  assert_main_untouched
}

@test "the session key can come from the environment or from --session=<key>, with the same result" {
  pb set feat-a --session "$SESS_A"
  pb set feat-b --session "$SESS_B"

  run --separate-stderr env CLAUDE_CODE_SESSION_ID="$SESS_A" bash -c 'cd "$0" && bash scripts/create-task-worktree.sh "$1" via-env' "$PROJ" "$(tw_path via-env)"
  [ "$status" -eq 0 ]
  [ "$(sha via-env)" = "$(sha feat-a)" ]

  run --separate-stderr env JENGA_CHECKLIST_SESSION_ID="$SESS_B" bash -c 'cd "$0" && bash scripts/create-task-worktree.sh "$1" via-seam' "$PROJ" "$(tw_path via-seam)"
  [ "$status" -eq 0 ]
  [ "$(sha via-seam)" = "$(sha feat-b)" ]

  run_ctw "$(tw_path via-flag)" via-flag --session="$SESS_B"
  [ "$status" -eq 0 ]
  [ "$(sha via-flag)" = "$(sha feat-b)" ]

  # --session wins over the environment.
  run --separate-stderr env CLAUDE_CODE_SESSION_ID="$SESS_A" bash -c 'cd "$0" && bash scripts/create-task-worktree.sh "$1" override --session "$2"' "$PROJ" "$(tw_path override)" "$SESS_B"
  [ "$status" -eq 0 ]
  [ "$(sha override)" = "$(sha feat-b)" ]
  assert_main_untouched
}

# --- AC: perceived branch deleted after set ---------------------------------------------------------------------------

@test "perceived branch deleted after set: exit 4, branch named on stderr, no worktree, no task branch, no HEAD fallback" {
  dirty_main
  pb set feat-a --session "$SESS_A"
  git -C "$PROJ" branch -q -D feat-a
  no_branch feat-a
  local refs_before wts_before d="$(tw_path t1)"
  refs_before="$(all_refs)"
  wts_before="$(wt_count)"

  run_ctw "$d" t1 --session "$SESS_A"
  [ "$status" -eq 4 ]
  assert_contains "$stderr" "feat-a"
  assert_contains "$stderr" "no longer exists"
  [ -z "$output" ]
  no_path "$d"
  no_branch t1
  [ "$(wt_count)" -eq "$wts_before" ]
  [ "$(all_refs)" = "$refs_before" ]
  # The message says HEAD was not used; and nothing was created at HEAD in any form.
  assert_contains "$stderr" "HEAD was not used"
  assert_main_untouched
}

@test "the other session is unaffected by session A's deleted perceived branch" {
  pb set feat-a --session "$SESS_A"
  pb set feat-b --session "$SESS_B"
  git -C "$PROJ" branch -q -D feat-a

  run_ctw "$(tw_path dead)" dead --session "$SESS_A"
  [ "$status" -eq 4 ]
  no_branch dead
  run_ctw "$(tw_path alive)" alive --session "$SESS_B"
  [ "$status" -eq 0 ]
  [ "$(sha alive)" = "$(sha feat-b)" ]
  assert_main_untouched
}

@test "perceived branch deleted and recreated elsewhere: the new tip is used" {
  pb set feat-a --session "$SESS_A"
  git -C "$PROJ" branch -q -D feat-a
  git -C "$PROJ" branch feat-a feat-b
  run_ctw "$(tw_path t1)" t1 --session "$SESS_A"
  [ "$status" -eq 0 ]
  [ "$(sha t1)" = "$(sha feat-b)" ]
  assert_main_untouched
}

# --- output and exit contract --------------------------------------------------------------------------------------------

@test "on success stdout is exactly the directory; git's own progress goes to stderr" {
  pb set feat-a --session "$SESS_A"
  local d="$(tw_path t1)"
  run_ctw "$d" t1 --session "$SESS_A"
  [ "$status" -eq 0 ]
  [ "$output" = "$d" ]
  assert_contains "$stderr" "HEAD is now at"
  assert_not_contains "$output" "HEAD is now at"
  assert_main_untouched
}

@test "usage errors exit 2, write nothing to stdout and create nothing" {
  local refs_before wts_before
  refs_before="$(all_refs)"
  wts_before="$(wt_count)"

  run_ctw
  [ "$status" -eq 2 ]
  [ -z "$output" ]
  run_ctw "$(tw_path only-dir)"
  [ "$status" -eq 2 ]
  [ -z "$output" ]
  run_ctw "$(tw_path a)" a extra
  [ "$status" -eq 2 ]
  [ -z "$output" ]
  run_ctw "-dir" name
  [ "$status" -eq 2 ]
  run_ctw "$(tw_path a)" -x
  [ "$status" -eq 2 ]
  run_ctw "$(tw_path a)" a --bogus
  [ "$status" -eq 2 ]
  run_ctw "$(tw_path a)" a --session
  [ "$status" -eq 2 ]
  run_ctw "" a
  [ "$status" -eq 2 ]
  run_ctw "$(tw_path a)" ""
  [ "$status" -eq 2 ]

  [ "$(wt_count)" -eq "$wts_before" ]
  [ "$(all_refs)" = "$refs_before" ]
  assert_main_untouched
}

@test "--help prints the usage on stdout and exits 0" {
  run_ctw --help
  [ "$status" -eq 0 ]
  assert_output_contains "create-task-worktree.sh <dir> <name> [--session <key>]"
  assert_main_untouched
}

@test "an existing task branch is git's failure: its exit status, nothing on stdout, no extra worktree" {
  pb set feat-a --session "$SESS_A"
  git -C "$PROJ" branch taken main
  local wts_before refs_before
  wts_before="$(wt_count)"
  refs_before="$(all_refs)"
  run_ctw "$(tw_path taken)" taken --session "$SESS_A"
  [ "$status" -ne 0 ]
  [ "$status" -ne 4 ]
  [ -z "$output" ]
  assert_contains "$stderr" "taken"
  no_path "$(tw_path taken)"
  [ "$(wt_count)" -eq "$wts_before" ]
  [ "$(all_refs)" = "$refs_before" ]
  assert_main_untouched
}

@test "an unusable session key exits 5 and creates nothing instead of guessing HEAD" {
  pb set feat-a --session "$SESS_A"
  run_ctw "$(tw_path t1)" t1 --session "../escape"
  [ "$status" -eq 5 ]
  [ -z "$output" ]
  no_path "$(tw_path t1)"
  no_branch t1
  assert_main_untouched
}

@test "perceived-branch.sh missing exits 5 and creates nothing instead of guessing HEAD" {
  rm "$PROJ/scripts/perceived-branch.sh"
  git -C "$PROJ" add -A
  git -C "$PROJ" commit -q -m "drop perceived-branch.sh"
  BEFORE="$(snap)"
  run_ctw "$(tw_path t1)" t1 --session "$SESS_A"
  [ "$status" -eq 5 ]
  [ -z "$output" ]
  no_path "$(tw_path t1)"
  no_branch t1
  assert_main_untouched
}

# --- AC: the WorktreeCreate hook command in settings.json and the permission-level templates ----------------------------------

# hook_command <file>: prints the WorktreeCreate command(s) of a settings file, one per hook entry.
hook_command() {
  jq -r '.hooks.WorktreeCreate[].hooks[].command' "$1"
}

@test "the WorktreeCreate hook command calls create-task-worktree.sh, still installs the commit guard, and has no bare git worktree add" {
  local f cmd n=0
  for f in "$REPO_ROOT/settings.json" "$REPO_ROOT"/templates/permission-levels/level-*.json; do
    [ -f "$f" ] || skip "$f is not in this tree"
    [ "$(jq -r '.hooks.WorktreeCreate | length' "$f")" -eq 1 ]
    [ "$(jq -r '.hooks.WorktreeCreate[0].hooks | length' "$f")" -eq 1 ]
    cmd="$(hook_command "$f")"
    [ -n "$cmd" ]
    assert_contains "$cmd" "scripts/create-task-worktree.sh"
    assert_contains "$cmd" "install-worktree-commit-guard.sh"
    assert_not_contains "$cmd" "git worktree add"
    n=$((n + 1))
  done
  # settings.json plus all five templates; a missing template would otherwise shrink the loop without a trace.
  [ "$n" -eq 6 ]
}

@test "the WorktreeCreate hook command is byte-identical across settings.json and all five permission-level templates" {
  local f cmd n=0 first_sum="" sum
  for f in "$REPO_ROOT/settings.json" "$REPO_ROOT"/templates/permission-levels/level-*.json; do
    [ -f "$f" ] || skip "$f is not in this tree"
    # The command is compared as raw bytes (jq -j prints no trailing newline).
    sum="$(jq -j '.hooks.WorktreeCreate[0].hooks[0].command' "$f" | cksum)"
    if [ -z "$first_sum" ]; then
      first_sum="$sum"
    fi
    [ "$sum" = "$first_sum" ]
    n=$((n + 1))
  done
  [ "$n" -eq 6 ]
}

# --- the hook command itself, run end to end ---------------------------------------------------------------------------------

# run_hook <payload> [VAR=value ...]: runs the extracted hook command with `bash -c`, the payload on stdin, from the
# fixture's main tree; stdout in $output and stderr in $stderr. Optional VAR=value words are set for that command only.
run_hook() {
  local payload="$1" cmd
  shift
  # The command is read from the repository's settings.json; skip (in the test shell, not a subshell) when it is absent.
  [ -f "$REPO_ROOT/settings.json" ] || skip "settings.json is not in this tree (the hook command is read from it)"
  cmd="$(jq -r '.hooks.WorktreeCreate[0].hooks[0].command' "$REPO_ROOT/settings.json")"
  [ -n "$cmd" ]
  run --separate-stderr bash -c 'cd "$0" && printf "%s" "$1" | env "${@:3}" bash -c "$2"' "$PROJ" "$payload" "$cmd" "$@"
}

@test "hook command: the worktree starts at the perceived tip and the hook echoes the directory (and only that)" {
  pb set feat-a --session "$SESS_A"
  pb set feat-b --session "$SESS_B"
  run_hook '{"name":"t1","session_id":"sess-A"}'
  [ "$status" -eq 0 ]
  [ "$output" = "$PROJ/.claude/worktrees/t1" ]
  [ -d "$PROJ/.claude/worktrees/t1" ]
  [ "$(git -C "$PROJ/.claude/worktrees/t1" rev-parse HEAD)" = "$(sha feat-a)" ]
  [ "$(git -C "$PROJ/.claude/worktrees/t1" branch --show-current)" = "t1" ]
  [ "$(sha t1)" = "$(sha feat-a)" ]
  # The commit guard the hook installs afterwards is in place: a commit on a branch other than t1 would be refused.
  [ -n "$(git -C "$PROJ/.claude/worktrees/t1" config --worktree core.hooksPath)" ]
  assert_main_untouched
}

@test "hook command: a second session in the same clone gets its own perceived tip" {
  pb set feat-a --session "$SESS_A"
  pb set feat-b --session "$SESS_B"
  run_hook '{"name":"t-a","session_id":"sess-A"}'
  [ "$status" -eq 0 ]
  run_hook '{"name":"t-b","session_id":"sess-B"}'
  [ "$status" -eq 0 ]
  [ "$output" = "$PROJ/.claude/worktrees/t-b" ]
  [ "$(sha t-a)" = "$(sha feat-a)" ]
  [ "$(sha t-b)" = "$(sha feat-b)" ]
  assert_main_untouched
}

@test "hook command: perceived branch deleted means a non-zero exit, nothing echoed, nothing created" {
  pb set feat-a --session "$SESS_A"
  git -C "$PROJ" branch -q -D feat-a
  local refs_before wts_before
  refs_before="$(all_refs)"
  wts_before="$(wt_count)"
  run_hook '{"name":"t1","session_id":"sess-A"}'
  [ "$status" -eq 4 ]
  [ -z "$output" ]
  assert_contains "$stderr" "feat-a"
  no_path "$PROJ/.claude/worktrees/t1"
  no_branch t1
  [ "$(wt_count)" -eq "$wts_before" ]
  [ "$(all_refs)" = "$refs_before" ]
  assert_main_untouched
}

@test "hook command: CLAUDE_CODE_SESSION_ID, when present, wins over the session_id in the payload" {
  pb set feat-a --session "$SESS_A"
  pb set feat-b --session "$SESS_B"
  run_hook '{"name":"t1","session_id":"sess-A"}' "CLAUDE_CODE_SESSION_ID=sess-B"
  [ "$status" -eq 0 ]
  [ "$output" = "$PROJ/.claude/worktrees/t1" ]
  [ "$(sha t1)" = "$(sha feat-b)" ]
  assert_main_untouched
}

@test "hook command: no session id anywhere falls back to HEAD, never to another session's branch" {
  pb set feat-a --session "$SESS_A"
  run_hook '{"name":"t1"}'
  [ "$status" -eq 0 ]
  [ "$output" = "$PROJ/.claude/worktrees/t1" ]
  [ "$(sha t1)" = "$(sha main)" ]
  assert_main_untouched
}

@test "hook command: a malformed session id in the payload fails the hook without creating a worktree" {
  pb set feat-a --session "$SESS_A"
  run_hook '{"name":"t1","session_id":"../escape"}'
  [ "$status" -eq 5 ]
  [ -z "$output" ]
  no_path "$PROJ/.claude/worktrees/t1"
  no_branch t1
  assert_main_untouched
}
