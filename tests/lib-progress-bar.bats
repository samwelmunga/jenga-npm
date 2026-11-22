#!/usr/bin/env bats
# bats file_tags=tier:integration
#
# Wrapper that puts the Node tests of the run bar and the after-task and after-story lines (lib/progress/bar.js and lines.js, E92_S08_T04) under `j.test` discovery.
#
# `j.test` and `npm test` discover suites through discover-tests.sh, which finds directories holding *.bats files and
# `package.json` test scripts; a bare *.test.mjs is not discovered. So the Node test file runs from here: one bats case
# runs tests/lib-progress-bar.test.mjs and fails when it exits non-zero, printing every `not ok` line TAP-style.
# The same case counts the Node tests, so a test file that silently runs nothing cannot pass. The file runs ONCE
# (E92_S08_T08: it used to run twice, once per case, which doubled the wall time for no extra assertion).
#
# Contract under test: lib/progress/{bar,lines,cli}.js and the E92_S08_T04 acceptance criteria; the details are in
# tests/lib-progress-bar.test.mjs. Fixtures live under a temp directory it creates.

bats_require_minimum_version 1.5.0

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd -P)"
NODE_TEST="$REPO_ROOT/tests/lib-progress-bar.test.mjs"

@test "the Node tests of the run bar and the after-task and after-story lines (parity, UTF-8, colour, widths, warnings, EPIPE) all pass; the TAP plan matches the ok lines and there are at least thirty" {
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
  [ "$plan" -ge 30 ]
}
