#!/usr/bin/env bats
#
# Meta-test: the suite's own assertion convention (E50_S07_T08).
#
# RELAXED 2026-09-26 -- the `[[`-ban rule this file used to enforce is retired.
# ------------------------------------------------------------------------------
# History: bats used to run each test body under errexit and install an ERR
# trap, but `[[` is a shell KEYWORD rather than a simple command, so a failing
# `[[ ... ]]` never fired that trap -- a `[[ ... ]]` that was not the body's
# final statement was therefore a no-op, silently false on every run while its
# test still reported ok. That was not a hypothetical: E50_S07_T07's tester
# measured 37 such assertions across four files, including two suites written
# to PROVE other stories' own fixes. Full measurement:
#   project/rapports/problems/E50_S07_T07-inert-bats-assertions-suite-wide.md
# E50_S07_T08 repaired all 37 and added the ban (below, until today) plus this
# file's canary test to catch the class coming back.
#
# The canary test itself said, from the day it was written: "If a future bats
# release makes a failing mid-body `[[` abort the test, that last test goes
# red and tells us this rule can be relaxed -- but verify before relaxing it."
# It went red on 2026-09-26 (discovered via a /mirror-public push blocked by
# skills/j-mirror-public/scripts/mirror.sh's check_test_subject_invariant
# gate). Verified directly before acting on it -- the exact fixture the canary
# used, reproduced by hand against every bats binary available in that
# session:
#   - /opt/homebrew/bin/bats (global)                  -- Bats 1.14.0 -- `not ok`
#   - node_modules/.bin/bats (repo-pinned, package.json) -- Bats 1.13.0 -- `not ok`
# Both versions now correctly abort on a failing non-final `[[ ... ]]` --
# confirmed, not assumed. The bats bug this whole convention existed to work
# around appears to be fixed upstream, in every bats release this repo
# currently uses. Full investigation record: project/todo.md's 2026-09-26
# entry (search "the tests/ [[-ban convention").
#
# What changed as a result: the ban ("no line under tests/ may begin with
# `[[`") and its enforcement (the scanner, its two fixture self-tests, and the
# canary) are removed below. `[[ ... ]]` is ordinary, unrestricted shell
# syntax in tests/ again, same as anywhere else in this codebase -- there is
# no longer a repo-specific reason to prefer `[ ... ]` for it. Existing test
# files that already avoid `[[` for this reason were NOT rewritten; nothing
# requires them to change, and nothing requires new code to use `[[` either --
# this only removes a restriction, it does not impose a new style.
#
# If a future bats release (or a bats version on someone else's machine)
# reintroduces the original silent-no-op behavior, the fix is the same shape
# as before: re-add the scanner + ban + a canary test pinning the regression,
# using this file's git history (before 2026-09-26) as the template.

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"

# -----------------------------------------------------------------------------
# Every suite that uses the shared helpers must actually load them, or the
# helper calls resolve to nothing and the tests error out per-file.
# -----------------------------------------------------------------------------

@test "every .bats file calling a shared helper loads tests/helpers/assertions" {
  local helper_re missing="" f
  helper_re="$(sed -n 's/^\(assert_[a-z_]*\)() {$/\1/p' \
    "$REPO_ROOT/tests/helpers/assertions.bash" | paste -sd'|' -)"

  if [ -z "$helper_re" ]; then
    echo "No assert_* helpers found in tests/helpers/assertions.bash." >&2
    return 1
  fi

  for f in "$REPO_ROOT"/tests/*.bats; do
    if grep -qE "^[[:space:]]*($helper_re)[[:space:]]" "$f"; then
      if ! grep -q '^load helpers/assertions' "$f"; then
        missing="$missing $(basename "$f")"
      fi
    fi
  done

  if [ -n "$missing" ]; then
    echo "These files call a shared assertion helper without loading it:$missing" >&2
    return 1
  fi
}
