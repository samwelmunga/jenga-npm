#!/usr/bin/env bats
#
# Differential tests for scripts/commits-for-item.sh (E79_S02_T02): the resolver against the legacy `git log --grep`.
#
# What this file is for: before any consumer is migrated onto the resolver, prove it is a drop-in replacement on
# EST-only history. Two legacy calls exist today (project/documentation/commit-consumer-audit.md):
#
#   anchored    git log --all --no-merges --extended-regexp --grep="<id>([^0-9_]|$)"   (mark-merged.sh and the three
#               scripts that copied its commits_for_ticket: audit rows M4 to M7)
#   unanchored  git log --all --no-merges --grep="<id>"                                (extract-task-diff-stats.sh,
#               extract-diff-stats.sh, the reconcile step: audit rows M1, M2, M8)
#
# The contract this file pins, per id:
#   OK          the resolver equals the anchored call, SHA for SHA and in the same order, and equals the unanchored
#               call too (nothing over-matched).
#   INTENDED n  the resolver equals the anchored call, and the unanchored call returns n MORE commits, every one of
#               which names the id only as the prefix of a longer id (E1 inside E10, a story id inside its task ids).
#               That over-match is the bug the anchor fixes, so it is a difference by design. Each such id is
#               printed, and the counts are asserted.
#   FAIL        anything else: an unexplained difference. Fails the test.
#
# The per-id comparison is tests/helpers/E79_S02_T02-differential-worker.sh; the id discovery, skip reasons,
# snapshotting, parallel runner and summary are tests/helpers/E79_S02_T02-differential.bash.
#
# Cases:
#   1. a synthetic EST-only fixture with prefix collisions at all three levels, exact verdicts and counts pinned;
#   2. mutation cases: a resolver that drops, adds, reorders, over-matches or crashes must be reported as FAIL, which
#      proves the comparison is live and not a tautology;
#   3. skip reasons: a shallow clone, an empty repository, no board and an empty board each skip with a message;
#   4. this repository's own history, every id under project/board/ (skips visibly on a shallow clone, on the
#      public mirror where project/board/ is absent, and inside a nested suite run).
#
# Scope boundary: shapes of rewritten history (rebase, amend, cherry-pick, squash, merges) and the trailer and
# template forms are tests/commits-for-item-mixed-history.bats (E79_S02_T03). Per-form and anchoring unit coverage is
# tests/commits-for-item.bats (E79_S02_T01). This file is EST-only on purpose.
#
# The working repository is never written: the this-repository case reads a throwaway mirror clone, so a commit another
# agent makes during the run cannot skew the comparison, and the case asserts the index file is byte-identical
# afterwards. Fixtures live under $BATS_TEST_TMPDIR with a local identity and signing off, and setup() hides the
# global and system git config, so the file passes on a machine with no global git identity.
#
# Run time: the this-repository case does about six git history walks per id over about 1900 ids, so it takes minutes.
# It runs the ids in parallel (at most 8 at once; E79_S02_T02_JOBS overrides). To pin the intended-difference count of
# this repository at a moment in time, set E79_S02_T02_EXPECTED_INTENDED=<n>; it is not hard-coded because every new
# commit that names a story or epic can change it.

bats_require_minimum_version 1.5.0
load helpers/assertions
load helpers/nested-suite
load helpers/E79_S02_T02-differential

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
SCRIPT="$REPO_ROOT/scripts/commits-for-item.sh"

setup() {
  # No global identity, no signing, no hooks: the fixture alone decides how git behaves.
  export GIT_CONFIG_GLOBAL=/dev/null
  export GIT_CONFIG_NOSYSTEM=1
  FIX="$BATS_TEST_TMPDIR/fixture"
  BOARD="$BATS_TEST_TMPDIR/board"
  OUT="$BATS_TEST_TMPDIR/out"
  IDS="$BATS_TEST_TMPDIR/ids"
  CLOCK=1700000000
}

# --------------------------------------------------------------------------------------------------------------
# Fixture helpers
# --------------------------------------------------------------------------------------------------------------

# init_repo <dir> : an empty repository with local identity, no signing, no hooks.
init_repo() {
  git init -q -b main "$1"
  git -C "$1" config user.email test@example.com
  git -C "$1" config user.name "Test"
  git -C "$1" config commit.gpgsign false
  git -C "$1" config core.hooksPath /dev/null
}

# commit <subject> [<body>] : an empty commit in $FIX with a strictly increasing commit date, so "newest first" is
# deterministic.
commit() {
  CLOCK=$((CLOCK + 60))
  local when="$CLOCK +0000"
  if [ $# -ge 2 ]; then
    GIT_AUTHOR_DATE="$when" GIT_COMMITTER_DATE="$when" git -C "$FIX" commit -q --allow-empty -m "$1" -m "$2"
  else
    GIT_AUTHOR_DATE="$when" GIT_COMMITTER_DATE="$when" git -C "$FIX" commit -q --allow-empty -m "$1"
  fi
}

# build_fixture : the EST-only history every fixture case reads. Each commit's mentions are what make the verdicts below
# computable by hand. "anchored" = the id followed by a non-digit, non-underscore or the end of a line. "prefix" = the id
# followed by a digit or an underscore (a longer id).
#
#    1  chore: base                                  names nothing
#    2  epic(E1): scaffold                           E1 anchored
#    3  epic(E10): bigger epic                       E10 anchored; E1 prefix
#    4  story(E10_S01): first story                  E10_S01 anchored; E10, E1 prefix
#    5  story(E10_S010): another story               E10_S010 anchored; E10_S01, E10, E1 prefix
#    6  task(E10_S01_T01): add retry                 E10_S01_T01 anchored; E10_S01, E10, E1 prefix
#    7  task(E10_S01_T010): add backoff              E10_S01_T010 anchored; E10_S01_T01, E10_S01, E10, E1 prefix
#    8  chore(E10_S01_T01): add rapport - retry      like 6
#    9  wip: tidy  + body "Refs E10_S01_T01 and E1."   E10_S01_T01 and E1 anchored (body only); E10_S01, E10 prefix
#   10  task(E10_S01_T010): wip on branch            like 7, on the unmerged branch feat
#   11  task(E10_S01_T01): topic work                like 6, on branch topic (merged below)
#   12  rapport: E1                                  E1 anchored, at the very end of the message
#   13  epic(E100): far epic                         E100 anchored; E10, E1 prefix
#   14  merge: E10_S01_T01-topic into main           a merge commit: excluded by --no-merges on every side
#
# Nine ids are queried (see build_board). Hand-computed verdicts:
#   E1            anchored {2,9,12}; unanchored adds 3..8,10,11,13 = 9 extra   -> INTENDED 9
#   E10           anchored {3};      unanchored adds 4..11,13       = 9 extra   -> INTENDED 9
#   E100          anchored {13};     unanchored {13}                            -> OK
#   E10_S01       anchored {4};      unanchored adds 5..11          = 7 extra   -> INTENDED 7
#   E10_S010      anchored {5};      unanchored {5}                             -> OK
#   E10_S01_T01   anchored {6,8,9,11}; unanchored adds 7,10         = 2 extra   -> INTENDED 2
#   E10_S01_T010  anchored {7,10};   unanchored {7,10}                          -> OK
#   E10_S01_T02, E10_S02  no commit names them                                  -> OK
# So: 9 ids, 5 OK, 4 INTENDED, 27 extra commits, 0 FAIL.
build_fixture() {
  init_repo "$FIX"
  commit "chore: base"
  commit "epic(E1): scaffold"
  commit "epic(E10): bigger epic"
  commit "story(E10_S01): first story"
  commit "story(E10_S010): another story"
  commit "task(E10_S01_T01): add retry"
  commit "task(E10_S01_T010): add backoff"
  commit "chore(E10_S01_T01): add rapport - retry"
  commit "wip: tidy" "Refs E10_S01_T01 and E1."
  git -C "$FIX" checkout -q -b feat
  commit "task(E10_S01_T010): wip on branch"
  git -C "$FIX" checkout -q main
  git -C "$FIX" checkout -q -b topic
  commit "task(E10_S01_T01): topic work"
  git -C "$FIX" checkout -q main
  commit "rapport: E1"
  commit "epic(E100): far epic"
  git -C "$FIX" merge --no-ff --no-edit -q -m "merge: E10_S01_T01-topic into main" topic
}

# build_board : a board directory for the fixture. Besides the nine item files it holds the things discovery must ignore:
# a README, a subdirectory (tasks/_superseded), and a lock directory.
build_board() {
  mkdir -p "$BOARD/epics" "$BOARD/stories" "$BOARD/tasks/_superseded" "$BOARD/tasks/E10_S01_T01_add-retry.md.lock.d"
  : >"$BOARD/epics/E1_one.md"
  : >"$BOARD/epics/E10_ten.md"
  : >"$BOARD/epics/E100_hundred.md"
  : >"$BOARD/epics/README.md"
  : >"$BOARD/stories/E10_S01_first.md"
  : >"$BOARD/stories/E10_S010_second.md"
  : >"$BOARD/stories/E10_S02_third.md"
  : >"$BOARD/tasks/E10_S01_T01_add-retry.md"
  : >"$BOARD/tasks/E10_S01_T010_add-backoff.md"
  : >"$BOARD/tasks/E10_S01_T02_nothing-yet.md"
  : >"$BOARD/tasks/_superseded/E10_S01_T09_old.md"
}

# repo_fingerprint <repo> : refs, HEAD and a checksum of the index file. Equal before and after means the repository was not
# written to. (A missing index is its own, stable, value.)
repo_fingerprint() {
  git -C "$1" for-each-ref
  git -C "$1" rev-parse HEAD
  cksum 2>/dev/null <"$(git -C "$1" rev-parse --absolute-git-dir)/index" || echo "no-index"
}

# index_fingerprint <repo> : the checksum of the index file alone. Used on the real working repository, whose refs other
# agents may legitimately move while the test runs, but whose index nothing here may touch.
index_fingerprint() {
  cksum 2>/dev/null <"$(git -C "$1" rev-parse --absolute-git-dir)/index" || echo "no-index"
}

# verdict_of <id> : the worker's one-line verdict for <id>, from $OUT.
verdict_of() { cat "$OUT/$1.res"; }

# subjects_of <sha>... : the subject of each commit, one per line, in the order given.
subjects_of() {
  local s
  for s in "$@"; do
    git -C "$FIX" log -1 --format=%s "$s"
  done
}

# make_stub <name> <body...> : write a stub resolver script into the test's tmp dir and print its path. Used as the
# <resolver> argument of the worker, where the real script normally goes.
make_stub() {
  local path="$BATS_TEST_TMPDIR/stub-$1.sh"
  shift
  printf '#!/usr/bin/env bash\n%s\n' "$*" >"$path"
  printf '%s' "$path"
}

# --------------------------------------------------------------------------------------------------------------
# 1. Synthetic EST-only fixture
# --------------------------------------------------------------------------------------------------------------

@test "fixture: the history has exactly the commits the verdict table assumes (merge commit and unmerged branch included)" {
  build_fixture
  run git -C "$FIX" log --all --no-merges --pretty=format:%s
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | wc -l | tr -d ' ')" -eq 13 ]
  assert_contains "$output" "task(E10_S01_T010): wip on branch"
  assert_contains "$output" "task(E10_S01_T01): topic work"
  assert_not_contains "$output" "merge: E10_S01_T01-topic into main"
  [ "$(git -C "$FIX" rev-list --all --merges --count)" -eq 1 ]
}

@test "id discovery: every epic, story and task file yields its own id; README, subdirectories and lock directories do not" {
  build_board
  run diff_board_ids "$BOARD"
  [ "$status" -eq 0 ]
  [ "$output" = "E1
E10
E100
E10_S01
E10_S010
E10_S01_T01
E10_S01_T010
E10_S01_T02
E10_S02" ]
}

@test "id discovery: a missing board directory yields no ids and no error" {
  run diff_board_ids "$BATS_TEST_TMPDIR/no-such-board"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "resolver output on the fixture is the expected commits in the expected order (independent of the worker)" {
  build_fixture
  # E10_S01_T01: topic work (11), wip: tidy (9), add rapport (8), add retry (6), newest first. The merge commit is out.
  run bash "$SCRIPT" E10_S01_T01 --repo "$FIX"
  [ "$status" -eq 0 ]
  shas=($output)
  [ "${#shas[@]}" -eq 4 ]
  [ "$(subjects_of "${shas[@]}")" = "task(E10_S01_T01): topic work
wip: tidy
chore(E10_S01_T01): add rapport - retry
task(E10_S01_T01): add retry" ]
  # E1: rapport: E1 (12), wip: tidy (9, body only), epic(E1): scaffold (2). Nothing that only names E10, E100 or E10_...
  run bash "$SCRIPT" E1 --repo "$FIX"
  [ "$status" -eq 0 ]
  shas=($output)
  [ "$(subjects_of "${shas[@]}")" = "rapport: E1
wip: tidy
epic(E1): scaffold" ]
  # A story id does not collect its task commits, and an unqueried-for-by-name id yields nothing.
  run bash "$SCRIPT" E10_S01 --repo "$FIX"
  [ "$status" -eq 0 ]
  [ "$(subjects_of $output)" = "story(E10_S01): first story" ]
  run bash "$SCRIPT" E10_S02 --repo "$FIX"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "fixture, all three id levels: the resolver equals the anchored legacy call and differs from the unanchored one only by prefix over-match; every verdict and the counts are pinned" {
  build_fixture
  build_board
  diff_board_ids "$BOARD" >"$IDS"
  [ "$(wc -l <"$IDS" | tr -d ' ')" -eq 9 ]
  E79_S02_T02_JOBS=4 diff_run_all "$FIX" "$OUT" "$SCRIPT" "$IDS"
  diff_summarise "$OUT" "$IDS"

  # One verdict per id, exactly as computed by hand in build_fixture.
  [ "$(verdict_of E1)" = "E1 INTENDED 9" ]
  [ "$(verdict_of E10)" = "E10 INTENDED 9" ]
  [ "$(verdict_of E100)" = "E100 OK" ]
  [ "$(verdict_of E10_S01)" = "E10_S01 INTENDED 7" ]
  [ "$(verdict_of E10_S010)" = "E10_S010 OK" ]
  [ "$(verdict_of E10_S01_T01)" = "E10_S01_T01 INTENDED 2" ]
  [ "$(verdict_of E10_S01_T010)" = "E10_S01_T010 OK" ]
  [ "$(verdict_of E10_S01_T02)" = "E10_S01_T02 OK" ]
  [ "$(verdict_of E10_S02)" = "E10_S02 OK" ]

  # The counts: the intended differences are asserted, and nothing is unexplained.
  [ "$DIFF_TOTAL" -eq 9 ]
  [ "$DIFF_OK" -eq 5 ]
  [ "$DIFF_INTENDED" -eq 4 ]
  [ "$DIFF_EXTRA" -eq 27 ]
  [ "$DIFF_FAIL" -eq 0 ]
  [ "$DIFF_MISSING" -eq 0 ]
  [ $((DIFF_OK + DIFF_INTENDED + DIFF_FAIL)) -eq "$DIFF_TOTAL" ]

  # Every intended difference is printed by id.
  [ "$(printf '%s' "$DIFF_REPORT" | grep -c '^INTENDED ')" -eq 4 ]
  assert_contains "$DIFF_REPORT" "INTENDED E1: the unanchored legacy grep returns 9 extra commit(s)"
  assert_contains "$DIFF_REPORT" "INTENDED E10: the unanchored legacy grep returns 9 extra commit(s)"
  assert_contains "$DIFF_REPORT" "INTENDED E10_S01: the unanchored legacy grep returns 7 extra commit(s)"
  assert_contains "$DIFF_REPORT" "INTENDED E10_S01_T01: the unanchored legacy grep returns 2 extra commit(s)"
  assert_not_contains "$DIFF_REPORT" "FAIL"
}

@test "fixture pipeline (snapshot, parallel run, summary) does not modify the repository it reads" {
  build_fixture
  build_board
  diff_board_ids "$BOARD" >"$IDS"
  before="$(repo_fingerprint "$FIX")"
  diff_snapshot "$FIX" "$BATS_TEST_TMPDIR/snapshot.git"
  E79_S02_T02_JOBS=4 diff_run_all "$BATS_TEST_TMPDIR/snapshot.git" "$OUT" "$SCRIPT" "$IDS"
  diff_summarise "$OUT" "$IDS"
  after="$(repo_fingerprint "$FIX")"
  [ "$before" = "$after" ]
  [ "$DIFF_FAIL" -eq 0 ]
  [ "$DIFF_INTENDED" -eq 4 ]
  # The snapshot is a separate repository carrying the same refs.
  [ "$(git -C "$BATS_TEST_TMPDIR/snapshot.git" rev-parse --is-bare-repository)" = "true" ]
  [ "$(git -C "$FIX" for-each-ref --format='%(refname) %(objectname)' refs/heads)" = "$(git -C "$BATS_TEST_TMPDIR/snapshot.git" for-each-ref --format='%(refname) %(objectname)' refs/heads)" ]
}

@test "the snapshot is frozen: a commit made after it is taken changes neither side of the comparison" {
  build_fixture
  build_board
  diff_board_ids "$BOARD" >"$IDS"
  diff_snapshot "$FIX" "$BATS_TEST_TMPDIR/snapshot.git"
  # A new commit naming E1 and E10_S01_T01 lands in the live repository, as another agent's commit would mid-run.
  commit "task(E10_S01_T01): late arrival" "Also refs E1."
  E79_S02_T02_JOBS=4 diff_run_all "$BATS_TEST_TMPDIR/snapshot.git" "$OUT" "$SCRIPT" "$IDS"
  diff_summarise "$OUT" "$IDS"
  [ "$(verdict_of E1)" = "E1 INTENDED 9" ]
  [ "$(verdict_of E10_S01_T01)" = "E10_S01_T01 INTENDED 2" ]
  [ "$DIFF_FAIL" -eq 0 ]
  # The live repository did move, so the identical verdicts are the snapshot's doing and not an accident.
  run bash "$SCRIPT" E10_S01_T01 --repo "$FIX"
  [ "$(printf '%s\n' "$output" | wc -l | tr -d ' ')" -eq 5 ]
}

# --------------------------------------------------------------------------------------------------------------
# 2. Mutation cases: the comparison must be able to fail
# --------------------------------------------------------------------------------------------------------------

@test "mutation baseline: the real resolver gets OK for a clean id and INTENDED for a colliding one" {
  build_fixture
  mkdir -p "$OUT"
  run bash "$DIFF_WORKER" "$FIX" "$OUT" "$SCRIPT" E10_S01_T010
  [ "$status" -eq 0 ]
  [ "$(verdict_of E10_S01_T010)" = "E10_S01_T010 OK" ]
  run bash "$DIFF_WORKER" "$FIX" "$OUT" "$SCRIPT" E10_S01_T01
  [ "$status" -eq 0 ]
  [ "$(verdict_of E10_S01_T01)" = "E10_S01_T01 INTENDED 2" ]
}

@test "mutation: a resolver that DROPS a commit is reported as FAIL" {
  build_fixture
  mkdir -p "$OUT"
  stub="$(make_stub drop "bash '$SCRIPT' \"\$@\" | tail -n +2")"
  run bash "$DIFF_WORKER" "$FIX" "$OUT" "$stub" E10_S01_T010
  [ "$status" -eq 0 ]
  assert_contains "$(verdict_of E10_S01_T010)" "E10_S01_T010 FAIL resolver differs from the anchored legacy call: 0 only in the resolver, 1 only in the legacy call"
}

@test "mutation: a resolver that ADDS a commit is reported as FAIL" {
  build_fixture
  mkdir -p "$OUT"
  stub="$(make_stub add "bash '$SCRIPT' \"\$@\"; printf '%040d\\n' 7")"
  run bash "$DIFF_WORKER" "$FIX" "$OUT" "$stub" E10_S01_T010
  [ "$status" -eq 0 ]
  assert_contains "$(verdict_of E10_S01_T010)" "E10_S01_T010 FAIL resolver differs from the anchored legacy call: 1 only in the resolver, 0 only in the legacy call"
}

@test "mutation: a resolver that REORDERS the commits is reported as FAIL (order is part of the contract)" {
  build_fixture
  mkdir -p "$OUT"
  stub="$(make_stub reorder "bash '$SCRIPT' \"\$@\" | awk '{ a[NR] = \$0 } END { for (i = NR; i > 0; i--) print a[i] }'")"
  run bash "$DIFF_WORKER" "$FIX" "$OUT" "$stub" E10_S01_T010
  [ "$status" -eq 0 ]
  assert_contains "$(verdict_of E10_S01_T010)" "E10_S01_T010 FAIL resolver and anchored legacy return the same commits in a different order"
}

@test "mutation: a resolver that over-matches like the unanchored legacy call is reported as FAIL (the anchor is checked)" {
  build_fixture
  mkdir -p "$OUT"
  stub="$(make_stub overmatch "git -C \"\$3\" log --all --no-merges --grep=\"\$1\" --pretty=format:%H; echo")"
  run bash "$DIFF_WORKER" "$FIX" "$OUT" "$stub" E10_S01_T01
  [ "$status" -eq 0 ]
  assert_contains "$(verdict_of E10_S01_T01)" "E10_S01_T01 FAIL resolver differs from the anchored legacy call: 2 only in the resolver, 0 only in the legacy call"
}

@test "mutation: a resolver that exits non-zero is reported as FAIL with its status and message" {
  build_fixture
  mkdir -p "$OUT"
  stub="$(make_stub crash "echo boom >&2; exit 4")"
  run bash "$DIFF_WORKER" "$FIX" "$OUT" "$stub" E10_S01_T010
  [ "$status" -eq 0 ]
  assert_contains "$(verdict_of E10_S01_T010)" "E10_S01_T010 FAIL resolver exited 4: boom"
}

@test "mutation through the pipeline: one bad resolver turns the summary red and the failing ids are named" {
  build_fixture
  build_board
  diff_board_ids "$BOARD" >"$IDS"
  stub="$(make_stub dropall "bash '$SCRIPT' \"\$@\" | tail -n +2")"
  E79_S02_T02_JOBS=4 diff_run_all "$FIX" "$OUT" "$stub" "$IDS"
  diff_summarise "$OUT" "$IDS"
  # Every id with at least one anchored commit loses it; ids with no commits cannot differ.
  [ "$DIFF_FAIL" -gt 0 ]
  [ "$((DIFF_OK + DIFF_INTENDED + DIFF_FAIL))" -eq "$DIFF_TOTAL" ]
  assert_contains "$DIFF_REPORT" "FAIL E10_S01_T010: resolver differs from the anchored legacy call"
}

@test "summary: an id whose worker never wrote a verdict is counted as a failure, not skipped over" {
  mkdir -p "$OUT"
  printf 'E1\nE2\n' >"$IDS"
  printf 'E1 OK\n' >"$OUT/E1.res"
  diff_summarise "$OUT" "$IDS"
  [ "$DIFF_TOTAL" -eq 2 ]
  [ "$DIFF_OK" -eq 1 ]
  [ "$DIFF_MISSING" -eq 1 ]
  [ "$DIFF_FAIL" -eq 1 ]
  assert_contains "$DIFF_REPORT" "MISSING E2"
}

@test "summary: an unreadable verdict is counted as a failure" {
  mkdir -p "$OUT"
  printf 'E1\nE2\n' >"$IDS"
  printf 'E1 INTENDED lots\n' >"$OUT/E1.res"
  printf 'E2 MAYBE\n' >"$OUT/E2.res"
  diff_summarise "$OUT" "$IDS"
  [ "$DIFF_OK" -eq 0 ]
  [ "$DIFF_INTENDED" -eq 0 ]
  [ "$DIFF_FAIL" -eq 2 ]
}

@test "worker: a wrong argument count is a usage error" {
  run bash "$DIFF_WORKER" only-one-argument
  [ "$status" -eq 2 ]
  assert_output_contains "usage:"
}

# --------------------------------------------------------------------------------------------------------------
# 3. Skip reasons: history unavailable is explicit, never a silent pass
# --------------------------------------------------------------------------------------------------------------

@test "skip reason: usable history and a populated board give no reason (the comparison proceeds)" {
  build_fixture
  build_board
  run diff_history_skip_reason "$FIX" "$BOARD"
  [ "$status" -eq 1 ]
  [ -z "$output" ]
}

@test "skip reason: a shallow clone names itself" {
  build_fixture
  build_board
  git clone -q --depth 1 "file://$FIX" "$BATS_TEST_TMPDIR/shallow"
  run diff_history_skip_reason "$BATS_TEST_TMPDIR/shallow" "$BOARD"
  [ "$status" -eq 0 ]
  assert_output_contains "shallow clone"
}

@test "skip reason: a repository with no commits names itself" {
  build_board
  init_repo "$BATS_TEST_TMPDIR/empty"
  run diff_history_skip_reason "$BATS_TEST_TMPDIR/empty" "$BOARD"
  [ "$status" -eq 0 ]
  assert_output_contains "no commits"
}

@test "skip reason: a directory that is not a repository names itself" {
  build_board
  mkdir -p "$BATS_TEST_TMPDIR/plain"
  export GIT_CEILING_DIRECTORIES="$BATS_TEST_TMPDIR"
  run diff_history_skip_reason "$BATS_TEST_TMPDIR/plain" "$BOARD"
  [ "$status" -eq 0 ]
  assert_output_contains "not a git repository"
}

@test "skip reason: no board directory names the path (the public mirror ships without project/board/)" {
  build_fixture
  run diff_history_skip_reason "$FIX" "$BATS_TEST_TMPDIR/no-board-here"
  [ "$status" -eq 0 ]
  assert_output_contains "no board at $BATS_TEST_TMPDIR/no-board-here"
}

@test "skip reason: a board with no item files names itself" {
  build_fixture
  mkdir -p "$BOARD/epics" "$BOARD/stories" "$BOARD/tasks"
  : >"$BOARD/epics/README.md"
  run diff_history_skip_reason "$FIX" "$BOARD"
  [ "$status" -eq 0 ]
  assert_output_contains "no epic, story or task files"
}

# --------------------------------------------------------------------------------------------------------------
# 4. This repository's own history
# --------------------------------------------------------------------------------------------------------------

@test "this repository's history: for every id under project/board/ the resolver equals the anchored legacy call and differs from the unanchored one only by prefix over-match" {
  skip_if_nested_suite_run "would walk this repository's full history about six times per board id (roughly 1900 ids)"
  local board="$REPO_ROOT/project/board"
  if reason="$(diff_history_skip_reason "$REPO_ROOT" "$board")"; then
    skip "$reason"
  fi

  index_before="$(index_fingerprint "$REPO_ROOT")"
  diff_board_ids "$board" >"$IDS"
  [ -s "$IDS" ]

  # Compare against a frozen copy of the history, not the live repository.
  diff_snapshot "$REPO_ROOT" "$BATS_TEST_TMPDIR/snapshot.git"
  diff_run_all "$BATS_TEST_TMPDIR/snapshot.git" "$OUT" "$SCRIPT" "$IDS"
  diff_summarise "$OUT" "$IDS"

  # Print every intended difference by id (fd 3 is bats' unbuffered channel, shown even when the test passes), then the
  # totals. Unexplained differences are printed too, so a red run says which ids and why.
  {
    printf '# %s\n' "E79_S02_T02: $DIFF_TOTAL ids compared against the legacy git log --grep (anchored and unanchored)"
    printf '%s' "$DIFF_REPORT" | sed 's/^/# /'
    printf '# %s\n' "ok=$DIFF_OK intended=$DIFF_INTENDED (extra unanchored commits: $DIFF_EXTRA) unexplained=$DIFF_FAIL missing=$DIFF_MISSING"
  } >&3

  # Every id got exactly one verdict, and none is unexplained.
  [ "$DIFF_MISSING" -eq 0 ]
  [ "$DIFF_FAIL" -eq 0 ]
  [ "$((DIFF_OK + DIFF_INTENDED))" -eq "$DIFF_TOTAL" ]
  [ "$DIFF_TOTAL" -eq "$(wc -l <"$IDS" | tr -d ' ')" ]

  # The intended-difference count printed above is the number of verdict files that say INTENDED (guards the summariser).
  [ "$(cat "$OUT"/*.res | grep -c '^[A-Z0-9_]* INTENDED [0-9][0-9]*$')" -eq "$DIFF_INTENDED" ]

  # The count is asserted when the caller pins it. It is a property of this repository's history, so it is not hard-coded.
  if [ -n "${E79_S02_T02_EXPECTED_INTENDED:-}" ]; then
    [ "$DIFF_INTENDED" -eq "$E79_S02_T02_EXPECTED_INTENDED" ]
  fi

  # The working repository's index was not touched.
  [ "$index_before" = "$(index_fingerprint "$REPO_ROOT")" ]
}
