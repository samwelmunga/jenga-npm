#!/usr/bin/env bash
#
# Shared setup for the skills/j-uncharted/scripts coverage (E43_S01_T02). Source it from a .bats file:
#
#   load helpers/assertions
#   load helpers/uncharted
#
# Why a sandbox
# -------------
# Most uncharted scripts anchor their side effects on THEIR OWN location, not on the directory they analyse:
# apply-subsystem-cap.sh and write-scan-record.sh default their output to <repo-of-the-script>/project/rapports/analysis,
# elicitation-state.sh writes <repo-of-the-script>/project/queue/elicitation-state/, write-backfilled-epics.sh writes
# <repo-of-the-script>/project/board/epics/. Run from the live checkout, a careless test would write into the real
# project. So every test invokes a byte-identical COPY of the skill that lives inside a throwaway git repository under
# $BATS_TEST_TMPDIR (uncharted_sandbox), and "the repo" every script resolves is that throwaway one. Nothing a test runs
# can reach the live project/logs/events.json, project/queue/ or project/board/.
#
# The sandbox is built from $UNCHARTED_SKILL_SRC (default: the live skills/j-uncharted). Pointing that variable at a
# mutated copy of the skill is how the mutation proofs for these suites are run (see the E43_S01_T02 summary): the suite
# itself never edits a script.
#
# Fixtures are read-only inputs. uncharted_tree copies one into $BATS_TEST_TMPDIR (so the path is canonical, outside the
# live repository, and free of the live .gitignore), optionally as its own git repo so that .gitignore and `git ls-files`
# behave as they do for a real target.

UNCHARTED_REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
UNCHARTED_FIXTURES="$UNCHARTED_REPO_ROOT/tests/fixtures"
UNCHARTED_SKILL_SRC="${UNCHARTED_SKILL_SRC:-$UNCHARTED_REPO_ROOT/skills/j-uncharted}"

# uncharted_sandbox: builds $SB, a git repo holding a copy of the skill and of the root scripts/ it depends on, plus empty
# project/board/epics, project/rapports/analysis and project/queue. Sets SB and SCRIPTS (the copied scripts dir).
uncharted_sandbox() {
  mkdir -p "$BATS_TEST_TMPDIR/sandbox"
  SB="$(cd "$BATS_TEST_TMPDIR/sandbox" && pwd -P)"
  mkdir -p "$SB/skills" "$SB/project/board/epics" "$SB/project/board/stories" "$SB/project/board/tasks" \
    "$SB/project/rapports/analysis" "$SB/project/queue"
  cp -R "$UNCHARTED_SKILL_SRC" "$SB/skills/j-uncharted"
  cp -R "$UNCHARTED_REPO_ROOT/scripts" "$SB/scripts"
  : >"$SB/project/board/epics/.keep"
  : >"$SB/project/rapports/analysis/.keep"
  ( cd "$SB" \
    && git init -q . \
    && git config user.email "fixture@example.invalid" \
    && git config user.name "fixture" \
    && git add -A \
    && git commit -q -m "sandbox" ) >/dev/null 2>&1
  SCRIPTS="$SB/skills/j-uncharted/scripts"
}

# uncharted_tree <fixture-dir> <name> [git]: copies <fixture-dir> into $BATS_TEST_TMPDIR/<name>, sets TREE to its
# canonical path, and with "git" turns it into a git repo with everything added (so the tree's own .gitignore applies).
uncharted_tree() {
  local src="$1" name="$2" mode="${3:-}"
  mkdir -p "$BATS_TEST_TMPDIR/$name"
  cp -R "$src/." "$BATS_TEST_TMPDIR/$name/"
  TREE="$(cd "$BATS_TEST_TMPDIR/$name" && pwd -P)"
  if [ "$mode" = "git" ]; then
    ( cd "$TREE" && git init -q . && git add -A ) >/dev/null 2>&1
  fi
}

# canon <file>: canonical JSON of a file, for comparing against an expected.json.
canon() { jq -S . "$1"; }

# assert_json_equals <actual-json-string> <expected-file>: canonical comparison with a diff on mismatch.
assert_json_equals() {
  local actual_file="$BATS_TEST_TMPDIR/.actual.json"
  printf '%s' "$1" | jq -S . >"$actual_file" 2>/dev/null || {
    printf 'actual output is not valid JSON:\n%s\n' "$1"
    return 1
  }
  if ! diff -u <(canon "$2") "$actual_file" >"$BATS_TEST_TMPDIR/.json.diff"; then
    printf 'JSON differs from %s (expected -, actual +):\n' "$2"
    cat "$BATS_TEST_TMPDIR/.json.diff"
    return 1
  fi
}
