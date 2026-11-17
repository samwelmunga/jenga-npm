#!/usr/bin/env bats
#
# Wrapper that puts the cross-renderer parity test of the bash (--legacy) and Node progress renderers (E92_S08_T08) under
# `j.test` discovery.
#
# `j.test` and `npm test` discover suites through discover-tests.sh, which finds directories holding *.bats files and
# `package.json` test scripts; a bare *.test.mjs is not discovered. So the Node test file runs from here: one bats case
# runs tests/lib-progress-parity.test.mjs and fails when it exits non-zero, printing every `not ok` line TAP-style.
# The same case counts the Node tests, so a test file that silently runs nothing cannot pass; the file runs once.
#
# Contract under test: the bash path and the Node default state the same numbers and label words (en, sv), every word the
# Node renderer prints comes from the label table, and the comparison can fail (controls); the scope view's arrows are real
# dependency edges on the rapport's E01 fixture (E92_S10_T03; the minimum plan rose from nine to twelve for its three
# tests). The details are in tests/lib-progress-parity.test.mjs. Fixtures live under a temp directory it creates.

bats_require_minimum_version 1.5.0

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd -P)"
NODE_TEST="$REPO_ROOT/tests/lib-progress-parity.test.mjs"

@test "the parity tests (numbers, ready list, unlocked-by pairs, label words en and sv, sentinel labels, controls, scope-view arrows E92_S10_T03) all pass; the TAP plan matches the ok lines and there are at least twelve" {
  command -v node >/dev/null 2>&1 || skip "node is not installed"
  run --separate-stderr node "$NODE_TEST"
  if [ "$status" -ne 0 ]; then
    printf '%s\n' "$output" | grep -A8 '^not ok' >&2
  fi
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | grep -c '^not ok')" -eq 0 ]
  local plan oks
  plan="$(printf '%s\n' "$output" | sed -n 's/^1\.\.\([0-9][0-9]*\)$/\1/p')"
  oks="$(printf '%s\n' "$output" | grep -c '^ok ')"
  [ -n "$plan" ]
  [ "$plan" -eq "$oks" ]
  [ "$plan" -ge 12 ]
}
