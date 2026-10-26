#!/usr/bin/env bats
#
# Unit-level coverage for scripts/commits-for-item.sh (E79_S02_T01), the shared commit resolver.
#
# Scope: each recognised form, id anchoring, empty results with and without --require-nonempty, unknown and
# malformed ids, ordering and --all/--no-merges semantics. NOT in scope here: the differential test against the
# legacy `git log --grep` on this repository's own history (E79_S02_T02) and the history-rewrite fixtures
# (E79_S02_T03).
#
# Every test builds a throwaway repository under $BATS_TEST_TMPDIR and points the script at it with --repo.
# Nothing here touches this repository's history, board or event log.

bats_require_minimum_version 1.5.0
load helpers/assertions

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
SCRIPT="$REPO_ROOT/scripts/commits-for-item.sh"

setup() {
  FIX="$BATS_TEST_TMPDIR/fixture"
  git init -q -b main "$FIX"
  git -C "$FIX" config user.email test@example.com
  git -C "$FIX" config user.name "Test"
  git -C "$FIX" config commit.gpgsign false
  git -C "$FIX" config core.hooksPath /dev/null
  CLOCK=1700000000
}

# commit <subject> [<body>] : an empty commit with a strictly increasing commit date, so "newest first" is
# deterministic. Echoes nothing; use `head_sha` to read the new commit.
commit() {
  CLOCK=$((CLOCK + 60))
  local when="$CLOCK +0000"
  if [ $# -ge 2 ]; then
    GIT_AUTHOR_DATE="$when" GIT_COMMITTER_DATE="$when" \
      git -C "$FIX" commit -q --allow-empty -m "$1" -m "$2"
  else
    GIT_AUTHOR_DATE="$when" GIT_COMMITTER_DATE="$when" \
      git -C "$FIX" commit -q --allow-empty -m "$1"
  fi
}

head_sha() { git -C "$FIX" rev-parse HEAD; }

# resolve <args...> : run the script against the fixture, stdout only in $output, stderr in $stderr.
resolve() { run --separate-stderr bash "$SCRIPT" "$@" --repo "$FIX"; }

# --------------------------------------------------------------------------------------------------------------
# The script itself
# --------------------------------------------------------------------------------------------------------------

@test "script exists, is executable and passes bash -n" {
  [ -f "$SCRIPT" ]
  [ -x "$SCRIPT" ]
  run bash -n "$SCRIPT"
  [ "$status" -eq 0 ]
}

@test "script has no bashisms beyond bash 3.2 (no mapfile, no associative arrays, no case-modifying expansions)" {
  # Comment lines are skipped: the header mentions the forbidden constructs by name.
  run bash -c 'grep -vE "^[[:space:]]*#" "$1" | grep -nE "mapfile|readarray|declare -A|\\$\\{[A-Za-z_]+(,,|\\^\\^)"' _ "$SCRIPT"
  [ "$status" -eq 1 ]
}

@test "--help prints usage on stdout and exits 0" {
  run --separate-stderr bash "$SCRIPT" --help
  [ "$status" -eq 0 ]
  assert_output_contains "Usage: commits-for-item.sh"
  assert_output_contains "--require-nonempty"
  [ -z "$stderr" ]
}

# --------------------------------------------------------------------------------------------------------------
# Form 1: EST subjects and ids anywhere in the message
# --------------------------------------------------------------------------------------------------------------

@test "EST form: a task id in the subject resolves to that commit only" {
  commit "task(E10_S01_T01): first"
  local want; want="$(head_sha)"
  commit "task(E10_S01_T02): second"
  resolve E10_S01_T01
  [ "$status" -eq 0 ]
  [ "$output" = "$want" ]
}

@test "EST form: an id in the body (not the subject) also resolves" {
  commit "chore: bookkeeping" "Relates to E10_S01_T01 and nothing else."
  local want; want="$(head_sha)"
  commit "chore: unrelated"
  resolve E10_S01_T01
  [ "$status" -eq 0 ]
  [ "$output" = "$want" ]
}

@test "EST form: story and epic ids resolve to the commits that name them" {
  commit "story(E10_S01): roll up"
  local story; story="$(head_sha)"
  commit "epic(E10): roll up"
  local epic; epic="$(head_sha)"
  resolve E10_S01
  [ "$status" -eq 0 ]
  [ "$output" = "$story" ]
  resolve E10
  [ "$status" -eq 0 ]
  [ "$output" = "$epic" ]
}

# --------------------------------------------------------------------------------------------------------------
# Form 2: Jenga-Task trailer
# --------------------------------------------------------------------------------------------------------------

@test "trailer form: a template-form subject resolves through its Jenga-Task trailer" {
  commit "ASD-001 add retry" "Jenga-Task: E10_S01_T03"
  local want; want="$(head_sha)"
  commit "ASD-002 add backoff" "Jenga-Task: E10_S01_T04"
  resolve E10_S01_T03
  [ "$status" -eq 0 ]
  [ "$output" = "$want" ]
}

@test "trailer form: several trailers in one block attribute the commit to each id" {
  commit "ASD-003 shared change" "Jenga-Task: E10_S01_T05
Jenga-Task: E10_S01_T06
Signed-off-by: Test <test@example.com>"
  local want; want="$(head_sha)"
  resolve E10_S01_T05
  [ "$status" -eq 0 ]
  [ "$output" = "$want" ]
  resolve E10_S01_T06
  [ "$status" -eq 0 ]
  [ "$output" = "$want" ]
}

@test "trailer form: key in any letter case and a comma or semicolon separated value list are handled" {
  commit "ASD-004 lower case key" "jenga-task: E10_S01_T07, E10_S01_T08; E10_S01_T09"
  local want; want="$(head_sha)"
  local id
  for id in E10_S01_T07 E10_S01_T08 E10_S01_T09; do
    resolve "$id"
    [ "$status" -eq 0 ]
    [ "$output" = "$want" ]
  done
}

@test "trailer form: a trailer-only history (no EST commit at all) resolves" {
  commit "ASD-005 only trailers here" "Jenga-Task: E10_S01_T10"
  local want; want="$(head_sha)"
  resolve E10_S01_T10
  [ "$status" -eq 0 ]
  [ "$output" = "$want" ]
}

# --------------------------------------------------------------------------------------------------------------
# Form 3: template-form subjects are never matched by their ref
# --------------------------------------------------------------------------------------------------------------

@test "template form: a commit with a ref but no trailer is not attributable and is not guessed at" {
  commit "ASD-006 add jitter"
  commit "task(E10_S01_T11): the real one"
  local want; want="$(head_sha)"
  resolve E10_S01_T11
  [ "$status" -eq 0 ]
  [ "$output" = "$want" ]
  # The ref-only commit is returned for no id at all.
  resolve E10_S01_T12
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "template form: the ref is a display label, so two tasks sharing one ref stay separate" {
  commit "ASD-007 part one" "Jenga-Task: E10_S01_T13"
  local one; one="$(head_sha)"
  commit "ASD-007 part two" "Jenga-Task: E10_S01_T14"
  local two; two="$(head_sha)"
  resolve E10_S01_T13
  [ "$output" = "$one" ]
  resolve E10_S01_T14
  [ "$output" = "$two" ]
}

# --------------------------------------------------------------------------------------------------------------
# Mixed history
# --------------------------------------------------------------------------------------------------------------

@test "mixed: EST and trailer commits for one id come back together, newest first, with no duplicates" {
  commit "task(E10_S02_T01): EST era"
  local first; first="$(head_sha)"
  commit "ASD-010 template era" "Jenga-Task: E10_S02_T01"
  local second; second="$(head_sha)"
  commit "task(E10_S02_T01): back to EST, and mentions" "Jenga-Task: E10_S02_T01"
  local third; third="$(head_sha)"
  commit "task(E10_S02_T02): another task"
  resolve E10_S02_T01
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf '%s\n%s\n%s' "$third" "$second" "$first")" ]
  [ "$(printf '%s\n' "$output" | sort | uniq | wc -l | tr -d ' ')" -eq 3 ]
}

@test "output is full 40-character SHAs, one per line, nothing else on stdout" {
  commit "task(E10_S02_T03): a"
  commit "task(E10_S02_T03): b"
  resolve E10_S02_T03
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 2 ]
  local l
  for l in "${lines[@]}"; do
    [ "${#l}" -eq 40 ]
    case "$l" in *[!0-9a-f]*) false ;; esac
  done
  [ -z "$stderr" ]
}

# --------------------------------------------------------------------------------------------------------------
# Anchoring (named cases required by the acceptance criteria)
# --------------------------------------------------------------------------------------------------------------

@test "anchoring: E51_S02 does not match E51_S02_T01" {
  commit "task(E51_S02_T01): a task of the story"
  commit "ASD-020 trailer for the task" "Jenga-Task: E51_S02_T01"
  resolve E51_S02
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "anchoring: E51_S02_T01 does not match E51_S02_T010" {
  commit "task(E51_S02_T010): the longer id"
  local longer; longer="$(head_sha)"
  commit "ASD-021 trailer for the longer id" "Jenga-Task: E51_S02_T010"
  local longer_trailer; longer_trailer="$(head_sha)"
  commit "task(E51_S02_T01): the shorter id"
  local shorter; shorter="$(head_sha)"
  resolve E51_S02_T01
  [ "$status" -eq 0 ]
  [ "$output" = "$shorter" ]
  resolve E51_S02_T010
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf '%s\n%s' "$longer_trailer" "$longer")" ]
}

@test "anchoring: an epic id does not match a story or a longer epic number" {
  commit "story(E51_S02): story only"
  commit "epic(E510): a different epic"
  commit "epic(E51): the epic"
  local want; want="$(head_sha)"
  resolve E51
  [ "$status" -eq 0 ]
  [ "$output" = "$want" ]
}

@test "anchoring: an id followed by punctuation or end of line still matches" {
  commit "task(E51_S03_T01): colon"
  local a; a="$(head_sha)"
  commit "merge E51_S03_T02, then more"
  local b; b="$(head_sha)"
  commit "chore: ends with the id E51_S03_T03"
  local c; c="$(head_sha)"
  resolve E51_S03_T01; [ "$output" = "$a" ]
  resolve E51_S03_T02; [ "$output" = "$b" ]
  resolve E51_S03_T03; [ "$output" = "$c" ]
}

# --------------------------------------------------------------------------------------------------------------
# Revision and merge semantics: --all --no-merges
# --------------------------------------------------------------------------------------------------------------

@test "--all: a commit on a branch that is not checked out is found" {
  commit "base"
  git -C "$FIX" checkout -q -b side
  commit "task(E10_S03_T01): on the side branch"
  local want; want="$(head_sha)"
  git -C "$FIX" checkout -q main
  resolve E10_S03_T01
  [ "$status" -eq 0 ]
  [ "$output" = "$want" ]
}

@test "--no-merges: a merge commit that names the id is not returned, the merged commit is" {
  commit "base"
  git -C "$FIX" checkout -q -b E10_S03_T02-slug
  commit "task(E10_S03_T02): the work"
  local work; work="$(head_sha)"
  git -C "$FIX" checkout -q main
  commit "diverge on main so the merge is a real merge commit"
  git -C "$FIX" merge -q --no-ff -m "merge: E10_S03_T02 into main" E10_S03_T02-slug
  resolve E10_S03_T02
  [ "$status" -eq 0 ]
  [ "$output" = "$work" ]
}

# --------------------------------------------------------------------------------------------------------------
# Empty results and --require-nonempty
# --------------------------------------------------------------------------------------------------------------

@test "empty result without the flag: exit 0, nothing on stdout or stderr" {
  commit "task(E10_S04_T01): something else"
  resolve E10_S04_T99
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ -z "$stderr" ]
}

@test "empty result with --require-nonempty: exit 1 and a message naming the id" {
  commit "task(E10_S04_T01): something else"
  resolve E10_S04_T99 --require-nonempty
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  assert_contains "$stderr" "E10_S04_T99"
}

@test "--require-nonempty with a non-empty result: exit 0 and the SHAs" {
  commit "task(E10_S04_T02): present"
  local want; want="$(head_sha)"
  resolve --require-nonempty E10_S04_T02
  [ "$status" -eq 0 ]
  [ "$output" = "$want" ]
  [ -z "$stderr" ]
}

@test "--require-nonempty in a shallow clone reports unavailable history (exit 3), not 'no commit carries'" {
  commit "task(E10_S04_T03): old work"
  commit "chore: newer 1"
  commit "chore: newer 2"
  local clone="$BATS_TEST_TMPDIR/shallow"
  git clone -q --depth 1 "file://$FIX" "$clone"
  [ "$(git -C "$clone" rev-parse --is-shallow-repository)" = "true" ]
  run --separate-stderr bash "$SCRIPT" E10_S04_T03 --require-nonempty --repo "$clone"
  [ "$status" -eq 3 ]
  [ -z "$output" ]
  assert_contains "$stderr" "E10_S04_T03"
  assert_contains "$stderr" "shallow"
  # Without the flag a shallow clone is still just an empty success, as for any empty result.
  run --separate-stderr bash "$SCRIPT" E10_S04_T03 --repo "$clone"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "an unknown but well-formed id behaves like any empty result" {
  commit "task(E10_S04_T04): exists"
  resolve E99_S99_T99
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  resolve E99_S99_T99 --require-nonempty
  [ "$status" -eq 1 ]
  assert_contains "$stderr" "E99_S99_T99"
}

@test "a repository with no commits resolves to empty, and --require-nonempty names the id" {
  resolve E10_S04_T05
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  resolve E10_S04_T05 --require-nonempty
  [ "$status" -eq 1 ]
  assert_contains "$stderr" "E10_S04_T05"
}

# --------------------------------------------------------------------------------------------------------------
# Malformed ids and usage errors never reach git
# --------------------------------------------------------------------------------------------------------------

# A fake `git` first on PATH records any invocation; a usage error must leave no trace.
install_git_spy() {
  SPY_DIR="$BATS_TEST_TMPDIR/spy"
  mkdir -p "$SPY_DIR"
  cat >"$SPY_DIR/git" <<EOF
#!/bin/sh
echo "\$@" >> "$BATS_TEST_TMPDIR/git-was-called"
exit 99
EOF
  chmod +x "$SPY_DIR/git"
}

@test "malformed ids are rejected with a usage error (exit 2) and never reach git" {
  install_git_spy
  local bad
  for bad in "e51" "E51_" "E51_S" "E51_S02_" "E51_S02_T" "E51_S02_T01_X" "E51_S02_T01-slug" "S02" "T01" "E" \
             "E51 S02" "E5.1" "E51;touch pwned" 'E51$(touch pwned)' "E51|x" "E51_S02_T01\\" "ASD-001" "E51_S2_T1x"; do
    run --separate-stderr env PATH="$SPY_DIR:$PATH" bash "$SCRIPT" "$bad" --repo "$FIX"
    [ "$status" -eq 2 ] || { echo "id '$bad' exited $status"; return 1; }
    [ -z "$output" ]
    assert_contains "$stderr" "malformed id"
  done
  [ ! -e "$BATS_TEST_TMPDIR/git-was-called" ]
  [ ! -e pwned ]
}

@test "usage errors: missing id, extra id, unknown option, option-shaped id, --repo without a value" {
  install_git_spy
  run --separate-stderr env PATH="$SPY_DIR:$PATH" bash "$SCRIPT"
  [ "$status" -eq 2 ]
  run --separate-stderr env PATH="$SPY_DIR:$PATH" bash "$SCRIPT" E51 E52
  [ "$status" -eq 2 ]
  run --separate-stderr env PATH="$SPY_DIR:$PATH" bash "$SCRIPT" E51 --bogus
  [ "$status" -eq 2 ]
  run --separate-stderr env PATH="$SPY_DIR:$PATH" bash "$SCRIPT" --all
  [ "$status" -eq 2 ]
  run --separate-stderr env PATH="$SPY_DIR:$PATH" bash "$SCRIPT" E51 --repo
  [ "$status" -eq 2 ]
  [ ! -e "$BATS_TEST_TMPDIR/git-was-called" ]
}

@test "outside a git repository: exit 4 and a message naming the id" {
  local notrepo="$BATS_TEST_TMPDIR/not-a-repo"
  mkdir -p "$notrepo"
  run --separate-stderr bash "$SCRIPT" E10_S05_T01 --repo "$notrepo"
  [ "$status" -eq 4 ]
  [ -z "$output" ]
  assert_contains "$stderr" "E10_S05_T01"
  assert_contains "$stderr" "not a git repository"
}

# --------------------------------------------------------------------------------------------------------------
# Invocation shapes
# --------------------------------------------------------------------------------------------------------------

@test "flags and the id may come in any order, and --repo=<dir> works" {
  commit "task(E10_S05_T02): present"
  local want; want="$(head_sha)"
  run --separate-stderr bash "$SCRIPT" --require-nonempty --repo "$FIX" E10_S05_T02
  [ "$status" -eq 0 ]
  [ "$output" = "$want" ]
  run --separate-stderr bash "$SCRIPT" --repo="$FIX" E10_S05_T02 --require-nonempty
  [ "$status" -eq 0 ]
  [ "$output" = "$want" ]
}

@test "without --repo it resolves in the current directory's repository" {
  commit "task(E10_S05_T03): present"
  local want; want="$(head_sha)"
  cd "$FIX"
  run --separate-stderr bash "$SCRIPT" E10_S05_T03
  [ "$status" -eq 0 ]
  [ "$output" = "$want" ]
}

@test "the temporary directory is removed on success and on failure" {
  commit "task(E10_S05_T04): present"
  local tmp="$BATS_TEST_TMPDIR/tmp"
  mkdir -p "$tmp"
  run env TMPDIR="$tmp" bash "$SCRIPT" E10_S05_T04 --repo "$FIX"
  [ "$status" -eq 0 ]
  run env TMPDIR="$tmp" bash "$SCRIPT" E10_S05_T99 --require-nonempty --repo "$FIX"
  [ "$status" -eq 1 ]
  [ -z "$(ls -A "$tmp")" ]
}
