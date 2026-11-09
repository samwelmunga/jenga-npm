#!/usr/bin/env bats
#
# E86_S05_T03 (audit group 6a, commit names): pin the two commit-name scripts against item numbers of three or
# more digits, on a MIXED-WIDTH history. Both scripts are width-agnostic by regex today
#   skills/j-commit/scripts/commit-subject-check.sh   BOARD_ID='E[0-9]+(_S[0-9]+(_T[0-9]+)?)?'
#   scripts/commits-for-item.sh                       ^E[0-9]+(_S[0-9]+(_T[0-9]+)?)?$  and  <id>([^0-9_]|$)
# so this file changes no script; it exists so a later edit cannot silently narrow either to two digits.
#
# Venue: everything lives under $BATS_TEST_TMPDIR. The resolver runs against a throwaway git repository
# (--repo), the subject check against a throwaway conventions file (--conventions) and JENGA_PROJECT_ROOT
# pointed at a scratch project. No network, and this repository's history and project/ tree are never touched.

bats_require_minimum_version 1.5.0
load helpers/assertions

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
CHECK="$REPO_ROOT/skills/j-commit/scripts/commit-subject-check.sh"
RESOLVER="$REPO_ROOT/scripts/commits-for-item.sh"

setup() {
  # A scratch project root so the subject check can never resolve this repository's own configs.
  PROJ="$BATS_TEST_TMPDIR/proj"
  mkdir -p "$PROJ/project/configs"
  printf '{}\n' > "$PROJ/project/configs/workflow.json"
  export JENGA_PROJECT_ROOT="$PROJ"

  # A strict, valid commit-format convention that only accepts feat/fix/docs subjects: any subject the script
  # classifies NON-BOARD and that is not one of those fails it (exit 1), any BOARD subject bypasses it (exit 0).
  CONV="$BATS_TEST_TMPDIR/conventions.json"
  printf '%s\n' '{"conventions_version":1,"categories":{"commit-format":{"source":"custom","summary":"s","values":{"style":"x","message_regex":"^(feat|fix|docs)\\(.+\\): .+"}}}}' > "$CONV"

  FIX="$BATS_TEST_TMPDIR/fixture"
  git init -q -b main "$FIX"
  git -C "$FIX" config user.email test@example.com
  git -C "$FIX" config user.name "Test"
  git -C "$FIX" config commit.gpgsign false
  git -C "$FIX" config core.hooksPath /dev/null
  CLOCK=1700000000
}

# commit <subject> : an empty commit with a strictly increasing commit date.
commit() {
  CLOCK=$((CLOCK + 60))
  GIT_AUTHOR_DATE="$CLOCK +0000" GIT_COMMITTER_DATE="$CLOCK +0000" \
    git -C "$FIX" commit -q --allow-empty -m "$1"
}

head_sha() { git -C "$FIX" rev-parse HEAD; }

# Mixed-width history. One SHA variable per commit so a test can assert on exact sets.
build_history() {
  commit "epic(E10): ten";                    SHA_E10=$(head_sha)
  commit "epic(E100): hundred";               SHA_E100=$(head_sha)
  commit "epic(E1001): thousand and one";     SHA_E1001=$(head_sha)
  commit "story(E1001_S100): wide story";     SHA_S1001_100=$(head_sha)
  commit "task(E1001_S100_T100): wide task";  SHA_T1001_100_100=$(head_sha)
  commit "task(E100_S10_T10): mid task";      SHA_T100_10_10=$(head_sha)
  commit "task(E10_S1_T1): narrow task";      SHA_T10_1_1=$(head_sha)
  commit "task(E10_S1_T10): narrow task ten"; SHA_T10_1_10=$(head_sha)
}

check() { run --separate-stderr bash "$CHECK" --conventions "$CONV" "$@"; }
resolve() { run --separate-stderr bash "$RESOLVER" "$@" --repo "$FIX"; }

# --------------------------------------------------------------------------------------------------------------
# commit-subject-check.sh
# --------------------------------------------------------------------------------------------------------------

@test "subject check: epic(E1001): x is a board subject" {
  check "epic(E1001): x"
  [ "$status" -eq 0 ]
  assert_output_contains "kind=board"
}

@test "subject check: story(E1001_S100): x is a board subject" {
  check "story(E1001_S100): x"
  [ "$status" -eq 0 ]
  assert_output_contains "kind=board"
}

@test "subject check: task(E1001_S100_T100): x is a board subject" {
  check "task(E1001_S100_T100): x"
  [ "$status" -eq 0 ]
  assert_output_contains "kind=board"
}

@test "subject check: a wide id in a non-EST scope is a board token, so the strict convention is not applied" {
  # The convention in $CONV rejects chore(...); a board id in the scope must bypass it at any width.
  check "chore(E1001_S100_T100): add rapport"
  [ "$status" -eq 0 ]
  assert_output_contains "kind=board"
  check "docs(E1001_S100,E1001_S101): note"
  [ "$status" -eq 0 ]
  assert_output_contains "kind=board"
  check "merge: E1001_S100 into main"
  [ "$status" -eq 0 ]
  assert_output_contains "kind=board"
}

@test "subject check: a malformed wide id (task segment with no digits) is not a board token" {
  # chore(E1001_S100_T) names no complete id: E1001_S100 is followed by '_' and E1001 by '_', so neither is a token.
  # The subject falls through to the NON-BOARD path and the strict convention rejects it.
  check "chore(E1001_S100_T): x"
  [ "$status" -eq 1 ]
  assert_output_contains "kind=non-board"
  assert_output_contains "violates the commit-format convention"
}

@test "subject check: a wide id with a trailing digit run is read whole, not as its prefix" {
  # E1001_S100_T1000x is not a token ('x' is a letter), and E1001_S100_T100 inside it is followed by '0' (a digit).
  check "chore(E1001_S100_T1000x): x"
  [ "$status" -eq 1 ]
  assert_output_contains "kind=non-board"
}

@test "subject check: characterization, the task(/story(/epic( prefix alone makes a subject board, whatever id follows" {
  # The EST prefix branch never inspects the id (E69 Decision 2: EST naming is mandatory for board commits and the
  # convention is never applied to it). So the literal malformed subject task(E1001_S100_T): x is classified board
  # and is NOT rejected by this script; the malformed-id rejection above is observable only on the scope-token path.
  check "task(E1001_S100_T): x"
  [ "$status" -eq 0 ]
  assert_output_contains "kind=board"
}

@test "subject check: two-digit behaviour is unchanged" {
  check "task(E01_S01_T01): x"
  [ "$status" -eq 0 ]
  assert_output_contains "kind=board"
  check "chore(E01_S01_T): x"
  [ "$status" -eq 1 ]
  assert_output_contains "kind=non-board"
}

# --------------------------------------------------------------------------------------------------------------
# commits-for-item.sh
# --------------------------------------------------------------------------------------------------------------

@test "resolver: a wide task id returns its own commit and not E100_S10_T10's" {
  build_history
  resolve E1001_S100_T100
  [ "$status" -eq 0 ]
  [ "$output" = "$SHA_T1001_100_100" ]
  [ "$output" != "$SHA_T100_10_10" ]
}

@test "resolver: a mid-width task id returns only its own commit" {
  build_history
  resolve E100_S10_T10
  [ "$status" -eq 0 ]
  [ "$output" = "$SHA_T100_10_10" ]
}

@test "resolver: E10_S1_T1 does not return E10_S1_T10's commit" {
  build_history
  resolve E10_S1_T1
  [ "$status" -eq 0 ]
  [ "$output" = "$SHA_T10_1_1" ]
  [ "$output" != "$SHA_T10_1_10" ]
}

@test "resolver: E10_S1_T10 returns its own commit and not E10_S1_T1's" {
  build_history
  resolve E10_S1_T10
  [ "$status" -eq 0 ]
  [ "$output" = "$SHA_T10_1_10" ]
}

@test "resolver: E100 does not return E10's or E1001's epic commits" {
  build_history
  resolve E100
  [ "$status" -eq 0 ]
  [ "$output" = "$SHA_E100" ]
  [ "$output" != "$SHA_E10" ]
  [ "$output" != "$SHA_E1001" ]
}

@test "resolver: E10 does not return E100's or E1001's epic commits" {
  build_history
  resolve E10
  [ "$status" -eq 0 ]
  [ "$output" = "$SHA_E10" ]
}

@test "resolver: E1001 returns only its epic commit, and the story id returns only the story commit" {
  build_history
  resolve E1001
  [ "$status" -eq 0 ]
  [ "$output" = "$SHA_E1001" ]
  resolve E1001_S100
  [ "$status" -eq 0 ]
  [ "$output" = "$SHA_S1001_100" ]
}

@test "resolver: wide ids pass validation, and a malformed wide id is a usage error before git runs" {
  build_history
  resolve E1001_S100_T100
  [ "$status" -eq 0 ]
  resolve E1001_S100_T
  [ "$status" -eq 2 ]
  [ -z "$output" ]
  assert_contains "$stderr" "malformed id"
}

@test "resolver: a wide id with no commit exits 0 and prints nothing (and 1 with --require-nonempty)" {
  build_history
  resolve E1001_S100_T101
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  resolve E1001_S100_T101 --require-nonempty
  [ "$status" -eq 1 ]
}
