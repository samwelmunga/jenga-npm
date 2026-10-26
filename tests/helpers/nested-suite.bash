#!/usr/bin/env bash
#
# Shared reader for the nested-suite-run flag (E77_S01_T02).
#
# What the flag is
# ----------------
# JENGA_NESTED_SUITE_RUN=1 means "this process is already inside a nested suite
# run", i.e. a suite that a gate launched from within another run. It caps
# nesting depth at 1. It is SET in exactly one place, on the environment of the
# `bats` command that mirror.sh's check_test_subject_invariant launches. Nothing
# else sets it. Anything that would start another full suite run reads it, and it
# reads it HERE, through one of the functions below, rather than with its own `if`.
#
# A nested occurrence is therefore an explicit, visible skip (a bats `skip`, or a
# logged line), never a silent pass. Unset, empty and `0` all mean "depth 0": the
# helpers do nothing and the caller proceeds.
#
# This file is sourced, never executed. It has no top-level side effects and does
# not touch shell options, so it is safe to `source` from a plain script as well
# as to `load` from a bats file.
#
# Usage in a bats file (any test that would start a nested suite run):
#
#   load helpers/nested-suite
#
#   @test "..." {
#     skip_if_nested_suite_run "would start a whole-suite run"
#     ...
#   }
#
# Usage in a plain shell script that logs and stops instead of skipping:
#
#   source "$(dirname "${BASH_SOURCE[0]}")/nested-suite.bash"
#   log_skip_if_nested_suite_run "would start a whole-suite run" && exit 0
#
# The flag is only a test affordance. mirror.sh reads it only when
# BATS_TEST_FILENAME is already set, so it cannot disable the production gate.
# See check_test_subject_invariant's nesting-guard comment in
# skills/j-mirror-public/scripts/mirror.sh for the full reasoning.

# nested_suite_run_active
#   Predicate. Returns 0 when JENGA_NESTED_SUITE_RUN is exactly `1`, else 1.
#   Prints nothing. Only the value `1` counts, matching mirror.sh's reader.
nested_suite_run_active() {
  [ "${JENGA_NESTED_SUITE_RUN:-0}" = "1" ]
}

# _nested_suite_reason <reason>
#   Prints the standard message. An empty reason gets a generic one so the skip
#   text is never blank.
_nested_suite_reason() {
  printf 'nested suite run (depth cap 1): %s' "${1:-would start a nested suite run}"
}

# skip_if_nested_suite_run [reason]
#   Bats form. When the flag is `1`, calls bats' `skip` with
#   "nested suite run (depth cap 1): <reason>", which ends the test as skipped.
#   When the flag is unset or `0`, does nothing and returns 0.
#   Must be called from a @test, setup() or a function they call (where bats'
#   `skip` is defined).
skip_if_nested_suite_run() {
  if nested_suite_run_active; then
    skip "$(_nested_suite_reason "${1:-}")"
  fi
  return 0
}

# log_skip_if_nested_suite_run [reason]
#   Shell form, for scripts that cannot use bats' `skip`. When the flag is `1`,
#   writes "SKIP: nested suite run (depth cap 1): <reason>" to stderr and returns 0
#   ("skipped: the caller should stop"). When the flag is unset or `0`, writes
#   nothing and returns 1 ("not nested: the caller should proceed"). Use it as
#       log_skip_if_nested_suite_run "<reason>" && exit 0
#   The return value is deliberately 0-means-skipped so the `&&` reads naturally;
#   it is not an error code.
log_skip_if_nested_suite_run() {
  if nested_suite_run_active; then
    printf 'SKIP: %s\n' "$(_nested_suite_reason "${1:-}")" >&2
    return 0
  fi
  return 1
}
