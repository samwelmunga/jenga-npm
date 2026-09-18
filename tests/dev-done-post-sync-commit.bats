#!/usr/bin/env bats
#
# Regression coverage for skills/j-dev-done/scripts/commit-post-sync.sh.
#
# Targets skills/j-dev-done/ deliberately, NOT skills/dev-done/: per CLAUDE.md's
# "The Canonical Naming Contract", skills/j-<name>/ is the hand-edited source of
# truth, and skills/dev-done/ is the bare copy awaiting deletion by E50_S15. The
# bare copy does not carry the post-sync commit step at all.
#
# Why this file exists
# ---------------------
# /dev-done chains /commit -> /self-sync, in that order, so /commit can only
# ever capture the repo as it stood BEFORE the mirrors were refreshed. Every
# change /self-sync then makes -- the .claude/.agents/.github/agents mirrors,
# the regenerated lib/skill-allow-list.json, and the real board status
# transitions written by its Merged-status (E51_S02) and Deploy-reconcile
# (E51_S05) passes -- was left uncommitted, with /dev-done reporting success
# over a dirty tree. This script is the third step that closes that gap.
#
# The property pinned hardest here is the scoping one. This commit is labelled
# `chore(self-sync)`, so sweeping in an unrelated edit the user happens to have
# in the tree would mislabel their work, not merely over-collect it. Several
# tests below exist solely to prove that dirty and pre-staged files outside
# /self-sync's write surface survive untouched.
#
# Every test runs against a throwaway git repo under $BATS_TEST_TMPDIR.
# Nothing here invokes /self-sync itself -- its output is simulated by editing
# the paths it is documented to write.

load helpers/assertions

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
SCRIPT="$REPO_ROOT/skills/j-dev-done/scripts/commit-post-sync.sh"

setup() {
  PROJ="$BATS_TEST_TMPDIR/repo"
  git init -q "$PROJ"
  cd "$PROJ" || return 1
  git config user.email test@example.com
  git config user.name "Test"

  mkdir -p .claude/skills .agents/skills .github/agents lib \
           project/board/tasks project/board/stories skills
  echo "a"              > .claude/skills/x.md
  echo "a"              > .agents/skills/x.md
  echo "a"              > .github/agents/dev.md
  echo "{}"             > lib/skill-allow-list.json
  echo "status: Passed" > project/board/tasks/E01_S01_T01_a.md
  echo "source"         > skills/real.md
  echo "mine"           > unrelated.txt

  git add -A
  git commit -q -m "base"
}

# Simulate what a real /self-sync run leaves behind.
simulate_self_sync() {
  echo "b"              > .claude/skills/x.md
  echo "b"              > .agents/skills/x.md
  echo '{"n":1}'        > lib/skill-allow-list.json
  echo "status: Merged" > project/board/tasks/E01_S01_T01_a.md
}

@test "commits the changes self-sync produced" {
  simulate_self_sync
  run bash "$SCRIPT" "$PROJ"
  [ "$status" -eq 0 ]
  assert_output_contains "POST_SYNC_RESULT=committed"

  cd "$PROJ" || return 1
  run git show --stat --format="" HEAD
  assert_output_contains ".claude/skills/x.md"
  assert_output_contains ".agents/skills/x.md"
  assert_output_contains "lib/skill-allow-list.json"
  assert_output_contains "project/board/tasks/E01_S01_T01_a.md"
}

@test "never sweeps an unrelated dirty file into the chore(self-sync) commit" {
  simulate_self_sync
  echo "MY WORK" > unrelated.txt
  bash "$SCRIPT" "$PROJ" >/dev/null

  cd "$PROJ" || return 1
  run git show --stat --format="" HEAD
  assert_output_not_contains "unrelated.txt"
  # Still dirty, i.e. left for the user to deal with.
  run git status --porcelain -- unrelated.txt
  assert_output_contains "unrelated.txt"
}

@test "never sweeps a pre-staged unrelated file into the commit" {
  simulate_self_sync
  echo "STAGED" > staged.txt
  cd "$PROJ" || return 1
  git add staged.txt
  bash "$SCRIPT" "$PROJ" >/dev/null

  run git show --stat --format="" HEAD
  assert_output_not_contains "staged.txt"
  # Still staged, exactly as the user left it.
  run git diff --cached --name-only
  assert_output_contains "staged.txt"
}

@test "reports clean and creates no commit when self-sync changed nothing" {
  cd "$PROJ" || return 1
  head_before="$(git rev-parse HEAD)"
  run bash "$SCRIPT" "$PROJ"
  [ "$status" -eq 0 ]
  assert_output_contains "POST_SYNC_RESULT=clean"
  [ "$(git rev-parse HEAD)" = "$head_before" ]
}

@test "is idempotent — a second run finds nothing left to commit" {
  simulate_self_sync
  bash "$SCRIPT" "$PROJ" >/dev/null
  run bash "$SCRIPT" "$PROJ"
  [ "$status" -eq 0 ]
  assert_output_contains "POST_SYNC_RESULT=clean"
}

@test "an empty target directory does not abort the commit on a bad pathspec" {
  # project/board/stories/ exists on disk but holds no tracked file. git knows
  # nothing about empty directories, so passing it as a pathspec aborts the
  # whole commit with "did not match any file(s) known to git".
  cd "$PROJ" || return 1
  rm -rf project/board/stories
  mkdir -p project/board/stories
  simulate_self_sync
  run bash "$SCRIPT" "$PROJ"
  [ "$status" -eq 0 ]
  assert_output_contains "POST_SYNC_RESULT=committed"
}

@test "board-only changes are counted in the commit subject" {
  cd "$PROJ" || return 1
  echo "status: Merged" > project/board/tasks/E01_S01_T01_a.md
  bash "$SCRIPT" "$PROJ" >/dev/null
  run git log -1 --pretty=%s
  assert_output_contains "board ticket(s)"
}

@test "mirror-only changes omit the board clause from the subject" {
  cd "$PROJ" || return 1
  echo "b" > .claude/skills/x.md
  bash "$SCRIPT" "$PROJ" >/dev/null
  run git log -1 --pretty=%s
  assert_output_contains "chore(self-sync): mirror root"
  assert_output_not_contains "board ticket(s)"
}

@test "the commit body records that no reconciliation ran" {
  simulate_self_sync
  bash "$SCRIPT" "$PROJ" >/dev/null
  cd "$PROJ" || return 1
  run git log -1 --pretty=%b
  assert_output_contains "No reconcile, doc-sync, or prerequisite check runs here"
}

@test "--dry-run reports the plan, commits nothing, and leaves the index clean" {
  simulate_self_sync
  cd "$PROJ" || return 1
  head_before="$(git rev-parse HEAD)"
  run bash "$SCRIPT" "$PROJ" --dry-run
  [ "$status" -eq 0 ]
  assert_output_contains "would commit with subject"
  [ "$(git rev-parse HEAD)" = "$head_before" ]
  # The staging done to compute the plan must not be left behind.
  run git diff --cached --name-only
  [ -z "$output" ]
}

@test "refuses a directory that is not a git repository" {
  mkdir -p "$BATS_TEST_TMPDIR/plain"
  run bash "$SCRIPT" "$BATS_TEST_TMPDIR/plain"
  [ "$status" -eq 1 ]
  assert_output_contains "Not a git repository"
}

@test "a repo with none of the self-sync target paths reports clean" {
  git init -q "$BATS_TEST_TMPDIR/bare-repo"
  run bash "$SCRIPT" "$BATS_TEST_TMPDIR/bare-repo"
  [ "$status" -eq 0 ]
  assert_output_contains "POST_SYNC_RESULT=clean"
}

@test "rejects an unknown option" {
  run bash "$SCRIPT" "$PROJ" --bogus
  [ "$status" -eq 1 ]
  assert_output_contains "Unknown option"
}

@test "the script's path list matches self-sync's documented write surface" {
  # If self-sync gains a destination and this list is not updated, that
  # destination's output silently stays uncommitted — the exact bug this
  # script exists to fix. Pin the coupling so it fails loudly instead.
  run grep -c -E '^\s+"(\.claude|\.agents|\.github/agents|lib/skill-allow-list\.json|project/board/tasks|project/board/stories)"$' "$SCRIPT"
  [ "$output" = "6" ]
}
