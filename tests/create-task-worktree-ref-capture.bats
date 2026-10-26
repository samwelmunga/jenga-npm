#!/usr/bin/env bats
#
# Coverage for the commit ref capture in scripts/create-task-worktree.sh (E79_S04_T09).
#
# Contract under test (the header section "COMMIT REF CAPTURE" of scripts/create-task-worktree.sh):
#   - for an OPTED-IN project (scripts/commit-settings.sh opted-in exits 0), after the worktree is created, a <name> that
#     starts with a task id records the ref found in the user's working branch (perceived branch when set, otherwise the
#     real checked-out branch) through scripts/task-commit-ref.sh capture-branch;
#   - stdout stays exactly one line (<dir>) and the exit status stays 0 whatever the capture does; a capture failure is a
#     stderr notice;
#   - a project that is not opted in takes the unchanged path: the same stdout, stderr, exit status and git state as when
#     commit-settings.sh is absent (the original code path), and nothing under the queue directory is created.
#
# Companion to tests/create-task-worktree.bats (E78_S02_T06), which stays unmodified and keeps covering the three worktree
# cases. That suite's fixture does not copy commit-settings.sh, so it exercises the "commit-settings.sh missing" path.
#
# Isolation. Every test builds throwaway git repositories under $BATS_TEST_TMPDIR (branch "main", one commit, no remote);
# the scripts under test are COPIED into each fixture's scripts/ directory, templates/conventions-schema.json into its
# templates/. The repository this suite lives in is only READ. Session identity is injected through --session; the
# session variables are unset in setup. JENGA_PROJECT_ROOT is set per run to the fixture being exercised.
#
# bats `run` merges stderr into $output unless `run --separate-stderr` is used, so stdout and stderr are always taken
# apart here. Assertions use `[ ... ]`, never a bare `[[ ... ]]`, and no assertion negates a command with `!`: "absent"
# checks go through the no_path function, an ordinary command whose failure aborts the test.

bats_require_minimum_version 1.5.0
load helpers/assertions

REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"

SESS_A="sess-A"
SESS_B="sess-B"
TID="E79_S04_T09"

setup() {
  unset CLAUDE_CODE_SESSION_ID JENGA_SESSION_ID CLAUDE_SESSION_ID JENGA_CHECKLIST_SESSION_ID
  unset CLAUDE_PROJECT_DIR JENGA_PROJECT_DIR JENGA_CONVENTIONS_SCHEMA JENGA_COMMIT_REF_EXTRACT_SCRIPT
  command -v jq >/dev/null 2>&1 || skip "jq is not installed (task-commit-ref.sh requires it)"
  local f
  for f in create-task-worktree perceived-branch resolve-root commit-settings validate-conventions commit-template commit-ref task-commit-ref with-lock; do
    [ -f "$REPO_ROOT/scripts/$f.sh" ] || skip "scripts/$f.sh is not in this tree (the suite exercises it)"
  done
  [ -f "$REPO_ROOT/templates/conventions-schema.json" ] || skip "templates/conventions-schema.json is not in this tree"

  PROJ="$BATS_TEST_TMPDIR/proj"
  make_proj "$PROJ" opted
}

# --- helpers ------------------------------------------------------------------------------------------------------

# make_proj <dir> <mode>: a fixture repository on branch main with one commit.
#   missing    commit-settings.sh is not copied (the original code path); a conventions.json that WOULD opt in is present
#   noconv     commit-settings.sh present, no conventions.json
#   notopted   commit-settings.sh present, a commit-format template with apply_to_board_commits false
#   invalid    commit-settings.sh present, a conventions.json that is not JSON (opted-in exits 3)
#   opted      commit-settings.sh present, an opted-in conventions.json
make_proj() {
  local dir="$1" mode="$2" f
  mkdir -p "$dir/scripts" "$dir/templates" "$dir/project/configs"
  for f in create-task-worktree perceived-branch resolve-root validate-conventions commit-template commit-ref task-commit-ref with-lock; do
    cp "$REPO_ROOT/scripts/$f.sh" "$dir/scripts/$f.sh"
  done
  if [ "$mode" != "missing" ]; then
    cp "$REPO_ROOT/scripts/commit-settings.sh" "$dir/scripts/commit-settings.sh"
  fi
  cp "$REPO_ROOT/templates/conventions-schema.json" "$dir/templates/conventions-schema.json"
  printf '{"paths":{"queue":"project/queue"}}\n' >"$dir/project/configs/workflow.json"
  printf 'project/queue/\n.claude/worktrees/\n' >"$dir/.gitignore"
  printf 'base\n' >"$dir/shared.txt"
  case "$mode" in
    missing | opted) conv_json true >"$dir/project/configs/conventions.json" ;;
    notopted) conv_json false >"$dir/project/configs/conventions.json" ;;
    invalid) printf 'this is not json\n' >"$dir/project/configs/conventions.json" ;;
    noconv) ;;
  esac

  git -C "$dir" init -q
  git -C "$dir" symbolic-ref HEAD refs/heads/main
  git -C "$dir" config user.name "bats"
  git -C "$dir" config user.email "bats@example.invalid"
  git -C "$dir" config commit.gpgsign false
  git -C "$dir" add -A
  git -C "$dir" commit -q -m "initial commit"
  [ "$(git -C "$dir" rev-parse --show-toplevel)" = "$(cd "$dir" && pwd -P)" ]
}

# conv_json <true|false>: a conventions.json with a commit-format template and the given apply_to_board_commits.
conv_json() {
  cat <<JSON
{
  "conventions_version": 1,
  "categories": {
    "commit-format": {
      "source": "custom",
      "summary": "ref first",
      "values": { "style": "ref-first", "template": "{ref} {summary}", "apply_to_board_commits": $1 }
    }
  }
}
JSON
}

# pb <proj> <args...>: the perceived-branch script, run from the fixture's main tree (setup of a state; output discarded).
pb() {
  local p="$1"
  shift
  (cd "$p" && JENGA_PROJECT_ROOT="$p" bash "$p/scripts/perceived-branch.sh" "$@") >/dev/null 2>&1
}

# run_ctw <proj> <dir> <name> [args...]: runs the fixture's create-task-worktree.sh from its main tree; stdout in
# $output, stderr in $stderr, never merged.
run_ctw() {
  local p="$1"
  shift
  run --separate-stderr env JENGA_PROJECT_ROOT="$p" bash -c 'cd "$0" && bash "$0/scripts/create-task-worktree.sh" "$@"' "$p" "$@"
}

# store_file <proj> <task-id>: where the per-task store lives in a fixture.
store_file() {
  printf '%s/project/queue/commit-refs/%s.json' "$1" "$2"
}

# store_get <proj> <jq-filter>: a field of this suite's task store (raw output).
store_get() {
  jq -r "$2" "$(store_file "$1" "$TID")"
}

wt_path() {
  printf '%s/.claude/worktrees/%s' "$1" "$2"
}

no_path() {
  if [ -e "$1" ]; then
    printf 'path %s exists\n' "$1"
    return 1
  fi
  return 0
}

# norm <proj>: stdin normalised so two fixtures can be compared (the fixture path and abbreviated commit ids replaced).
norm() {
  sed -e "s#$1#<P>#g" -e 's/[0-9a-f]\{7,40\}/<H>/g'
}

# observe <proj>: everything a caller can see after a run_ctw in that fixture, normalised: exit status, stdout, stderr,
# `git status`, the branch names and worktree count, and the listing of the queue directory.
observe() {
  local p="$1"
  printf 'status=%s\n--stdout--\n%s\n--stderr--\n%s\n' "$status" "$output" "$stderr" | norm "$p"
  printf -- '--git status--\n'
  git -C "$p" status --porcelain | norm "$p"
  printf -- '--branches--\n'
  git -C "$p" for-each-ref --format='%(refname)' | sort
  printf -- '--worktrees--\n'
  git -C "$p" worktree list --porcelain | grep -c '^worktree '
  printf -- '--queue--\n'
  (cd "$p/project" 2>/dev/null && find queue 2>/dev/null | sort) || true
}

# --- AC: the key on the perceived branch is captured, the task branch never carries it ------------------------------

@test "perceived branch feature/ASD-001-foo: the store records candidate ASD-001 and the branch; the task branch has no key" {
  pb "$PROJ" set feature/ASD-001-foo --session "$SESS_A"
  local d
  d="$(wt_path "$PROJ" "$TID-x")"
  run_ctw "$PROJ" "$d" "$TID-x" --session "$SESS_A"
  [ "$status" -eq 0 ]
  [ "$output" = "$d" ]
  [ "$(git -C "$d" branch --show-current)" = "$TID-x" ]
  [ "$(store_get "$PROJ" '.branch_candidate')" = "ASD-001" ]
  [ "$(store_get "$PROJ" '.branch')" = "feature/ASD-001-foo" ]
  [ "$(store_get "$PROJ" '.task_id')" = "$TID" ]
  # the task branch name itself carries no key
  run grep -c 'ASD-' <<<"$TID-x"
  [ "$output" = "0" ]
}

@test "the worktree is cut from the perceived branch exactly as before the capture existed" {
  pb "$PROJ" set feature/ASD-001-foo --session "$SESS_A"
  local d
  d="$(wt_path "$PROJ" "$TID-x")"
  run_ctw "$PROJ" "$d" "$TID-x" --session "$SESS_A"
  [ "$status" -eq 0 ]
  [ "$(git -C "$d" rev-parse HEAD)" = "$(git -C "$PROJ" rev-parse feature/ASD-001-foo)" ]
}

@test "no perceived branch, main tree on feature/ASD-002-bar: the candidate is ASD-002" {
  git -C "$PROJ" checkout -q -b feature/ASD-002-bar
  local d
  d="$(wt_path "$PROJ" "$TID-x")"
  run_ctw "$PROJ" "$d" "$TID-x" --session "$SESS_A"
  [ "$status" -eq 0 ]
  [ "$output" = "$d" ]
  [ "$(store_get "$PROJ" '.branch_candidate')" = "ASD-002" ]
  [ "$(store_get "$PROJ" '.branch')" = "feature/ASD-002-bar" ]
}

@test "a branch with no key records candidate null, the worktree is created, exit 0 and exactly one stdout line" {
  local d
  d="$(wt_path "$PROJ" "$TID-x")"
  run_ctw "$PROJ" "$d" "$TID-x" --session "$SESS_A"
  [ "$status" -eq 0 ]
  [ "$output" = "$d" ]
  [ "$(printf '%s\n' "$output" | wc -l | tr -d ' ')" = "1" ]
  [ -d "$d" ]
  [ "$(store_get "$PROJ" '.branch_candidate')" = "null" ]
  [ "$(store_get "$PROJ" '.branch')" = "main" ]
}

@test "stdout is one line and the status is 0 for every opted-in variant that records a candidate" {
  pb "$PROJ" set feature/ASD-001-foo --session "$SESS_A"
  local d
  d="$(wt_path "$PROJ" "$TID-x")"
  run_ctw "$PROJ" "$d" "$TID-x" --session "$SESS_A"
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | wc -l | tr -d ' ')" = "1" ]
}

@test "the key is read for the session that was passed through: another session sees the real branch" {
  pb "$PROJ" set feature/ASD-001-foo --session "$SESS_A"
  local d
  d="$(wt_path "$PROJ" "$TID-x")"
  run_ctw "$PROJ" "$d" "$TID-x" --session "$SESS_B"
  [ "$status" -eq 0 ]
  [ "$(store_get "$PROJ" '.branch_candidate')" = "null" ]
  [ "$(store_get "$PROJ" '.branch')" = "main" ]
}

@test "after the user checks out another branch following creation, the stored candidate is unchanged" {
  pb "$PROJ" set feature/ASD-001-foo --session "$SESS_A"
  local d
  d="$(wt_path "$PROJ" "$TID-x")"
  run_ctw "$PROJ" "$d" "$TID-x" --session "$SESS_A"
  [ "$status" -eq 0 ]
  pb "$PROJ" clear --session "$SESS_A"
  git -C "$PROJ" checkout -q -b feature/ASD-777-other
  run --separate-stderr env JENGA_PROJECT_ROOT="$PROJ" bash "$PROJ/scripts/task-commit-ref.sh" get "$TID" --field candidate
  [ "$status" -eq 0 ]
  [ "$output" = "ASD-001" ]
  [ "$(store_get "$PROJ" '.branch')" = "feature/ASD-001-foo" ]
}

# --- AC: default-off projects are unchanged ----------------------------------------------------------------------------

@test "not opted in, no conventions.json and an invalid conventions.json look exactly like the original path (no perceived branch)" {
  local m p
  for m in missing noconv notopted invalid; do
    p="$BATS_TEST_TMPDIR/p-$m"
    make_proj "$p" "$m"
    run_ctw "$p" "$(wt_path "$p" "$TID-x")" "$TID-x" --session "$SESS_A"
    [ "$status" -eq 0 ]
    observe "$p" >"$BATS_TEST_TMPDIR/obs-$m"
    no_path "$p/project/queue"
  done
  cmp "$BATS_TEST_TMPDIR/obs-missing" "$BATS_TEST_TMPDIR/obs-noconv"
  cmp "$BATS_TEST_TMPDIR/obs-missing" "$BATS_TEST_TMPDIR/obs-notopted"
  cmp "$BATS_TEST_TMPDIR/obs-missing" "$BATS_TEST_TMPDIR/obs-invalid"
  # the control really was a worktree creation with the one stdout line
  grep -q '^status=0$' "$BATS_TEST_TMPDIR/obs-missing"
}

@test "default-off with a perceived branch set: identical to the original path and no commit-refs directory" {
  local m p
  for m in missing noconv notopted invalid; do
    p="$BATS_TEST_TMPDIR/p-$m"
    make_proj "$p" "$m"
    pb "$p" set feature/ASD-001-foo --session "$SESS_A"
    run_ctw "$p" "$(wt_path "$p" "$TID-x")" "$TID-x" --session "$SESS_A"
    [ "$status" -eq 0 ]
    observe "$p" >"$BATS_TEST_TMPDIR/obs-$m"
    no_path "$p/project/queue/commit-refs"
  done
  cmp "$BATS_TEST_TMPDIR/obs-missing" "$BATS_TEST_TMPDIR/obs-noconv"
  cmp "$BATS_TEST_TMPDIR/obs-missing" "$BATS_TEST_TMPDIR/obs-notopted"
  cmp "$BATS_TEST_TMPDIR/obs-missing" "$BATS_TEST_TMPDIR/obs-invalid"
}

@test "an invalid conventions.json prints nothing extra on stderr (the validator's lines are not passed through)" {
  local p="$BATS_TEST_TMPDIR/p-invalid"
  make_proj "$p" invalid
  run_ctw "$p" "$(wt_path "$p" "$TID-x")" "$TID-x" --session "$SESS_A"
  [ "$status" -eq 0 ]
  run grep -ci 'conventions\|invalid\|not json' <<<"$stderr"
  [ "$output" = "0" ]
}

# --- AC: a name without a task id, and the exit 4 / 5 cases, capture nothing ----------------------------------------

@test "a <name> that does not start with a task id creates the worktree and records nothing" {
  pb "$PROJ" set feature/ASD-001-foo --session "$SESS_A"
  local d
  d="$(wt_path "$PROJ" plain-name)"
  run_ctw "$PROJ" "$d" plain-name --session "$SESS_A"
  [ "$status" -eq 0 ]
  [ "$output" = "$d" ]
  [ -d "$d" ]
  no_path "$PROJ/project/queue/commit-refs"
  # the task id must be at the start: a name that merely contains one is not a task worktree
  d="$(wt_path "$PROJ" "x-$TID")"
  run_ctw "$PROJ" "$d" "x-$TID" --session "$SESS_A"
  [ "$status" -eq 0 ]
  no_path "$PROJ/project/queue/commit-refs"
}

@test "exit 4 (perceived branch deleted) creates nothing and captures nothing" {
  pb "$PROJ" set feature/ASD-001-foo --session "$SESS_A"
  git -C "$PROJ" branch -q -D feature/ASD-001-foo
  local d
  d="$(wt_path "$PROJ" "$TID-x")"
  run_ctw "$PROJ" "$d" "$TID-x" --session "$SESS_A"
  [ "$status" -eq 4 ]
  [ -z "$output" ]
  no_path "$d"
  no_path "$PROJ/project/queue/commit-refs"
}

@test "exit 5 (perceived-branch.sh missing) creates nothing and captures nothing" {
  rm -f "$PROJ/scripts/perceived-branch.sh"
  local d
  d="$(wt_path "$PROJ" "$TID-x")"
  run_ctw "$PROJ" "$d" "$TID-x" --session "$SESS_A"
  [ "$status" -eq 5 ]
  [ -z "$output" ]
  no_path "$d"
  no_path "$PROJ/project/queue/commit-refs"
}

@test "a git failure (existing branch) keeps git's status, prints nothing on stdout and captures nothing" {
  git -C "$PROJ" branch "$TID-x"
  local d
  d="$(wt_path "$PROJ" "$TID-x")"
  run_ctw "$PROJ" "$d" "$TID-x" --session "$SESS_A"
  [ "$status" -ne 0 ]
  [ -z "$output" ]
  no_path "$PROJ/project/queue/commit-refs"
}

# --- AC: capture failures never change the contract ------------------------------------------------------------------

@test "task-commit-ref.sh missing: a stderr notice, worktree created, exit 0, one stdout line" {
  rm -f "$PROJ/scripts/task-commit-ref.sh"
  local d
  d="$(wt_path "$PROJ" "$TID-x")"
  run_ctw "$PROJ" "$d" "$TID-x" --session "$SESS_A"
  [ "$status" -eq 0 ]
  [ "$output" = "$d" ]
  [ -d "$d" ]
  run grep -c 'commit ref not captured' <<<"$stderr"
  [ "$output" = "1" ]
}

@test "an unwritable store: a stderr notice, worktree created, exit 0, one stdout line" {
  mkdir -p "$PROJ/project/queue"
  : >"$PROJ/project/queue/commit-refs"
  local d
  d="$(wt_path "$PROJ" "$TID-x")"
  run_ctw "$PROJ" "$d" "$TID-x" --session "$SESS_A"
  [ "$status" -eq 0 ]
  [ "$output" = "$d" ]
  [ -d "$d" ]
  run grep -c 'commit ref not captured' <<<"$stderr"
  [ "$output" = "1" ]
}

@test "a detached HEAD with no perceived branch: a stderr notice, worktree created, exit 0, nothing recorded" {
  git -C "$PROJ" checkout -q --detach
  local d
  d="$(wt_path "$PROJ" "$TID-x")"
  run_ctw "$PROJ" "$d" "$TID-x" --session "$SESS_A"
  [ "$status" -eq 0 ]
  [ "$output" = "$d" ]
  [ -d "$d" ]
  no_path "$PROJ/project/queue/commit-refs"
  run grep -c 'commit ref not captured' <<<"$stderr"
  [ "$output" = "1" ]
}

# --- AC: a hostile branch name is data ------------------------------------------------------------------------------

@test "a hostile branch name never executes anything" {
  # shellcheck disable=SC2016  # the dollar signs are the point: they must stay literal
  local hostile='feature/ASD-001;touch${IFS}canary-$(touch${IFS}canary2)'
  pb "$PROJ" set "$hostile" --session "$SESS_A" || true
  git -C "$PROJ" show-ref --verify --quiet "refs/heads/$hostile" || skip "git does not accept this branch name here"
  local d
  d="$(wt_path "$PROJ" "$TID-x")"
  run_ctw "$PROJ" "$d" "$TID-x" --session "$SESS_A"
  [ "$status" -eq 0 ]
  [ "$output" = "$d" ]
  local c
  for c in canary canary2; do
    no_path "$PROJ/$c"
    no_path "$d/$c"
    no_path "$BATS_TEST_TMPDIR/$c"
    no_path "$BATS_TEST_TMPDIR/$c-"
  done
  no_path "$PROJ/scripts/canary"
}

# --- header and source hygiene --------------------------------------------------------------------------------------

@test "-h still prints only the USAGE block (the new header section is outside it)" {
  run bash "$REPO_ROOT/scripts/create-task-worktree.sh" -h
  [ "$status" -eq 0 ]
  run grep -c 'COMMIT REF CAPTURE\|capture-branch' <<<"$output"
  [ "$output" = "0" ]
}

@test "the script documents the capture and holds no dynamic evaluation" {
  grep -q 'COMMIT REF CAPTURE' "$REPO_ROOT/scripts/create-task-worktree.sh"
  run grep -nE '(^|[^A-Za-z_])(eval|source)[[:space:]]|^[[:space:]]*\.[[:space:]]' "$REPO_ROOT/scripts/create-task-worktree.sh"
  [ "$status" -eq 1 ]
}
