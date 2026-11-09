#!/usr/bin/env bats
#
# E86_S06_T01: self-test of the mixed-width synthetic board generator, tests/helpers/mixed-width-board.sh.
#
# Subject: the generator writes a complete throwaway project (board in the real layout, todo, plans, summaries, queue and
# handoff samples, a rapport, an event log and a git history) for E01, E10, E11, E99, E100, E101 and E1001 (with S10,
# S100 and T100 items), or only the two-digit families with --two-digit.
#
# Isolation and cost. One generation makes about 80 git calls, so setup_file runs three generations concurrently, once,
# and the tests inspect them:
#   WIDE  the wide variant, generated from an empty working directory
#   ALT   the wide variant again, into an existing EMPTY directory with a deeper path, run under /bin/bash when that is
#         bash 3.x, with hostile GIT_* variables in the environment (a different clock, author and committer)
#   TWO   the --two-digit variant, given a RELATIVE target
# TMPDIR and HOME point at empty directories that the writes-only-under-dir test then checks stayed empty. All of it
# lives under $BATS_FILE_TMPDIR. scripts/validate-board.sh runs on the generated files only, never on this repository's
# own board. No network is used.
#
# Fixed expectations: every board file validates; the history carries epic(E1001), story(E100_S100) and
# task(E100_S100_T100); two independent generations give identical files and identical commit SHAs; the two-digit
# variant has no ID with a segment wider than two digits.

load helpers/assertions

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
GEN="$REPO_ROOT/tests/helpers/mixed-width-board.sh"
VALIDATE="$REPO_ROOT/scripts/validate-board.sh"

# fixture_paths  - the locations setup_file generates into, shared by setup_file and every test.
fixture_paths() {
  F="$BATS_FILE_TMPDIR"
  WIDE="$F/parent/wide"
  ALT="$F/parent/alt/deeper/path"
  TWO="$F/cwd-two/rel-two"
}

setup_file() {
  fixture_paths
  export TMPDIR="$F/tmp" HOME="$F/home"
  mkdir -p "$TMPDIR" "$HOME" "$F/parent" "$F/cwd-wide" "$F/cwd-alt" "$F/cwd-two" "$ALT"
  local alt_shell=bash
  if [ -x /bin/bash ]; then
    case "$(/bin/bash -c 'printf %s "$BASH_VERSION"')" in 3.*) alt_shell=/bin/bash ;; esac
  fi
  printf '%s\n' "$alt_shell" > "$F/alt-shell"
  (cd "$F/cwd-wide" && bash "$GEN" "$WIDE" > "$F/wide.out" 2>&1; echo $? > "$F/wide.rc") &
  (cd "$F/cwd-alt" && env GIT_AUTHOR_DATE="2030-05-05T05:05:05+0000" GIT_COMMITTER_DATE="2031-01-01T00:00:00+0000" \
    GIT_COMMITTER_NAME="Someone Else" GIT_AUTHOR_EMAIL="other@example.com" "$alt_shell" "$GEN" "$ALT" \
    > "$F/alt.out" 2>&1; echo $? > "$F/alt.rc") &
  (cd "$F/cwd-two" && bash "$GEN" rel-two --two-digit > "$F/two.out" 2>&1; echo $? > "$F/two.rc") &
  wait
}

setup() {
  fixture_paths
  export TMPDIR="$F/tmp" HOME="$F/home"
}

# board_files <fixture-dir>  - every board file, sorted, one per line.
board_files() {
  find "$1/project/board" -type f -name '*.md' | sort
}

# fingerprint <fixture-dir>  - path, mode flag and checksum of every non-git file, plus the git index and the full log.
fingerprint() {
  (
    cd "$1"
    find . -path ./.git -prune -o -type f -print | sort | while IFS= read -r f; do
      printf '%s %s %s\n' "$f" "$(cksum < "$f")" "$(find "$f" -maxdepth 0 -perm 644 -print | wc -l | tr -d ' ')"
    done
    git ls-files -s
    git log --format='%H %an <%ae> %ad %cn <%ce> %cd %s' --date=raw
  )
}

# every_id <fixture-dir>  - every board ID mentioned in a file name, a file body or a commit message, one per line.
every_id() {
  {
    (cd "$1" && find . -path ./.git -prune -o -type f -print)
    grep -rhoE 'E[0-9]+(_S[0-9]+(_T[0-9]+)?)?' --exclude-dir=.git "$1"
    git -C "$1" log --format=%B
  } | grep -oE 'E[0-9]+(_S[0-9]+(_T[0-9]+)?)?' | sort -u
}

@test "all three generations succeeded" {
  for name in wide alt two; do
    [ "$(cat "$F/$name.rc")" = "0" ]
  done
  assert_contains "$(cat "$F/wide.out")" "wide mixed-width board fixture"
  assert_contains "$(cat "$F/two.out")" "two-digit mixed-width board fixture"
}

@test "wide variant generates the board in the real layout with every required family" {
  for id in E01 E10 E11 E99 E100 E101 E1001; do
    [ -f "$WIDE/project/board/epics/${id}_fixture-epic.md" ]
  done
  for id in E01_S01 E10_S1 E10_S10 E100_S10 E100_S100 E1001_S100; do
    [ -f "$WIDE/project/board/stories/${id}_fixture-story.md" ]
  done
  for id in E01_S01_T01 E10_S1_T1 E10_S10_T10 E100_S10_T10 E100_S100_T99 E100_S100_T100 E1001_S01_T01 E1001_S100_T100; do
    [ -f "$WIDE/project/board/tasks/${id}_fixture-task.md" ]
  done
}

@test "wide variant also writes todo, plans, summaries, queue and handoff samples, a rapport and an event log" {
  d="$WIDE"
  grep -q ': E100_S100_T100$' "$d/project/todo.md"
  grep -q ': E1001_S100_T100$' "$d/project/todo.md"
  [ -f "$d/project/documentation/plans/E100_S100_T100-plan.md" ]
  [ -f "$d/project/documentation/summaries/E100_S100_T100-summary.md" ]
  [ -f "$d/project/documentation/summaries/E100_S100-summary.md" ]
  [ -f "$d/project/documentation/plans/E1001_S100_T100-plan.md" ]
  [ -f "$d/project/queue/handoffs/developer-fixture-session-E100_S100_T100.json" ]
  [ -f "$d/project/queue/bundle-E100_S100.json" ]
  [ -f "$d/project/queue/scrum_triggers.jsonl" ]
  [ -f "$d/project/rapports/problems/E1001_S100_T100-fixture-sample-problem.md" ]
  [ -f "$d/project/logs/events.json" ]
  if command -v jq >/dev/null 2>&1; then
    jq -e . "$d/project/queue/handoffs/developer-fixture-session-E100_S100_T100.json" >/dev/null
    jq -e . "$d/project/queue/bundle-E100_S100.json" >/dev/null
    jq -e . "$d/project/configs/workflow.json" >/dev/null
    jq -c . "$d/project/queue/scrum_triggers.jsonl" >/dev/null
    jq -c . "$d/project/logs/events.json" >/dev/null
  fi
}

@test "every generated board file passes validate-board.sh (wide and two-digit)" {
  for d in "$WIDE" "$TWO"; do
    files=()
    while IFS= read -r f; do files+=("$f"); done < <(board_files "$d")
    [ "${#files[@]}" -ge 10 ]
    run bash "$VALIDATE" "${files[@]}"
    [ "$status" -eq 0 ]
    valid="$(printf '%s\n' "$output" | grep -c 'board frontmatter valid')"
    [ "$valid" -eq "${#files[@]}" ]
  done
}

@test "the validator is not vacuous: a malformed ID in a generated file is still rejected" {
  bad="$BATS_TEST_TMPDIR/bad-task.md"
  sed 's/^id: E100_S100_T100$/id: E100x_S100_T100/' \
    "$WIDE/project/board/tasks/E100_S100_T100_fixture-task.md" > "$bad"
  run bash "$VALIDATE" "$bad"
  [ "$status" -ne 0 ]
}

@test "git history contains epic(E1001), story(E100_S100) and task(E100_S100_T100) commits" {
  subjects="$(git -C "$WIDE" log --format=%s)"
  printf '%s\n' "$subjects" | grep -q '^epic(E1001): '
  printf '%s\n' "$subjects" | grep -q '^story(E100_S100): '
  printf '%s\n' "$subjects" | grep -q '^task(E100_S100_T100): '
  printf '%s\n' "$subjects" | grep -q '^task(E10_S1_T1): '
  printf '%s\n' "$subjects" | grep -q '^task(E10_S10_T10): '
  [ "$(git -C "$WIDE" rev-parse --abbrev-ref HEAD)" = "main" ]
  [ -z "$(git -C "$WIDE" status --porcelain)" ]
}

@test "two independent generations give identical files, modes and commit SHAs" {
  fingerprint "$WIDE" > "$BATS_TEST_TMPDIR/wide.fp"
  fingerprint "$ALT" > "$BATS_TEST_TMPDIR/alt.fp"
  [ -s "$BATS_TEST_TMPDIR/wide.fp" ]
  diff "$BATS_TEST_TMPDIR/wide.fp" "$BATS_TEST_TMPDIR/alt.fp"
  [ "$(git -C "$WIDE" rev-parse HEAD)" = "$(git -C "$ALT" rev-parse HEAD)" ]
  # the two runs differ in directory path, working directory, environment clock and identity, and possibly in shell
  [ "$WIDE" != "$ALT" ]
}

@test "the two variants have different histories" {
  [ "$(git -C "$WIDE" rev-parse HEAD)" != "$(git -C "$TWO" rev-parse HEAD)" ]
}

@test "files are mode 644 on disk and 100644 in git" {
  for d in "$WIDE" "$TWO"; do
    [ -z "$(find "$d" -path "$d/.git" -prune -o -type f ! -perm 644 -print)" ]
    [ -z "$(git -C "$d" ls-files -s | awk '$1 != "100644"')" ]
  done
}

@test "the wide variant has IDs wider than two digits, and the prefix-collision neighbours" {
  ids="$(every_id "$WIDE")"
  for id in E01 E10 E11 E99 E100 E101 E1001 E10_S1 E10_S10 E100_S10 E100_S100 E100_S100_T100 E1001_S100_T100; do
    printf '%s\n' "$ids" | grep -qx "$id"
  done
}

@test "--two-digit emits only IDs of at most two digits per segment" {
  ids="$(every_id "$TWO")"
  for id in E01 E10 E11 E99 E01_S01_T01 E10_S10_T10 E99_S99_T99; do
    printf '%s\n' "$ids" | grep -qx "$id"
  done
  # no segment of any ID found anywhere (file names, bodies, commit messages) has three or more digits
  [ -z "$(printf '%s\n' "$ids" | grep -E '[0-9]{3,}')" ]
  # and no wide family exists
  [ ! -e "$TWO/project/board/epics/E100_fixture-epic.md" ]
  [ ! -e "$TWO/project/board/epics/E1001_fixture-epic.md" ]
  [ -z "$(find "$TWO/project/board" -type f -name '*_S1_*' -o -type f -name '*_T1_*')" ]
}

@test "the generator writes only under the directory it is given" {
  [ "$(ls -A "$F/parent")" = "alt
wide" ]
  [ -z "$(ls -A "$F/cwd-wide")" ]
  [ -z "$(ls -A "$F/cwd-alt")" ]
  [ "$(ls -A "$F/cwd-two")" = "rel-two" ]
  [ -z "$(ls -A "$TMPDIR")" ]
  [ -z "$(ls -A "$HOME")" ]
}

@test "it refuses a non-empty directory and leaves it untouched" {
  mkdir -p "$BATS_TEST_TMPDIR/busy"
  printf 'keep\n' > "$BATS_TEST_TMPDIR/busy/existing.txt"
  run bash "$GEN" "$BATS_TEST_TMPDIR/busy"
  [ "$status" -eq 3 ]
  [ "$(cat "$BATS_TEST_TMPDIR/busy/existing.txt")" = "keep" ]
  [ "$(ls -A "$BATS_TEST_TMPDIR/busy")" = "existing.txt" ]
  # a regenerate attempt on a finished fixture is refused too
  run bash "$GEN" "$WIDE"
  [ "$status" -eq 3 ]
}

@test "usage errors exit 2 and write nothing" {
  cd "$BATS_TEST_TMPDIR"
  run bash "$GEN"
  [ "$status" -eq 2 ]
  run bash "$GEN" "$BATS_TEST_TMPDIR/x" --nonsense
  [ "$status" -eq 2 ]
  run bash "$GEN" "$BATS_TEST_TMPDIR/x" "$BATS_TEST_TMPDIR/y"
  [ "$status" -eq 2 ]
  [ ! -e "$BATS_TEST_TMPDIR/x" ]
  [ ! -e "$BATS_TEST_TMPDIR/y" ]
  run bash "$GEN" --help
  [ "$status" -eq 0 ]
  assert_output_contains "--two-digit"
}

@test "the second generation ran under macOS bash 3.2 when that shell is present" {
  [ "$(cat "$F/alt-shell")" = "/bin/bash" ] || skip "/bin/bash is not bash 3.x here"
  [ "$(git -C "$WIDE" rev-parse HEAD)" = "$(git -C "$ALT" rev-parse HEAD)" ]
}

@test "the generator makes no network calls and uses no bash 4 features" {
  # comment lines are skipped: the header legitimately names what the script avoids
  code="$(grep -vE '^[[:space:]]*#' "$GEN")"
  [ -n "$code" ]
  for pattern in \
    '(^|[^A-Za-z_-])(curl|wget|nc|ssh|scp|ftp|telnet)([^A-Za-z_-]|$)' \
    'git +(-[^ ]+ +)*(clone|fetch|pull|push|remote)' \
    'https?://' \
    '(^|[^A-Za-z_])(mapfile|readarray)([^A-Za-z_]|$)|declare +-A|local +-A|\$\{[A-Za-z_]+(,,|\^\^)'; do
    run grep -nE "$pattern" <<< "$code"
    [ "$status" -eq 1 ]
  done
}
