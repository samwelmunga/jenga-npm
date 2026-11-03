#!/usr/bin/env bash
#
# Shared assertion helpers for the bats suite (E50_S07_T08).
#
# Why this file exists
# --------------------
# bats installs an ERR trap and runs each test body under errexit, so a failing
# *simple command* aborts the test. `[[ ... ]]` is not a simple command -- it is
# a shell KEYWORD, and a failing keyword does not fire the ERR trap. So this:
#
#     @test "looks like it asserts something" {
#       [[ 1 -eq 2 ]]
#       true
#     }
#
# reports `ok`. The assertion is false, the test passes, and nothing in the TAP
# output hints that anything was skipped. Verified against bats 1.13.0, the
# version this repo pins.
#
# The failure is silent and fail-open: a suite full of these reports more
# confidence than it holds, and a regression in any covered condition never
# turns it red. E50_S07_T07's tester measured 37 such assertions across four
# files -- including two suites written specifically to PROVE this story's own
# fixes were correct. See:
#   project/rapports/problems/E50_S07_T07-inert-bats-assertions-suite-wide.md
#
# A bare `[[ ]]` in FINAL position happens to work, because bats uses the test
# body's exit status. That is worse, not better: it is a landmine that disarms
# itself the moment someone appends a line below it. The convention this repo
# enforces therefore admits no positional exception --
# tests/bats-assertion-convention.bats bans any line under tests/ that BEGINS
# with `[[`, in any position, in any file. Use `[ ... ]` (a builtin, which does
# fire the trap) or one of the helpers below. `[[` inside an `if`/`while`
# CONDITION is fine and is not what the ban targets -- those lines start with
# `if`, not `[[`.
#
# Usage: source this file from a .bats file's top level.
#
#   load helpers/assertions        # bats `load` appends .bash automatically
#
# Every helper is an ordinary shell function, so a `return 1` from one is a
# failing simple command and does abort the test.

# -----------------------------------------------------------------------------
# Liveness mutation hook
# -----------------------------------------------------------------------------
# Proving an assertion is WIRED is a different question from proving its
# expectation is TRUE. A repaired assertion that passes tells us nothing on its
# own -- the inert ones all "passed" too. So every helper routes its verdict
# through _jenga_assert_verdict, which will invert that verdict for one
# specifically targeted call site when JENGA_ASSERT_MUTATE is set:
#
#   JENGA_ASSERT_MUTATE="router-prefix-guard.bats:122"
#
# The containing test MUST go red under that mutation. If it stays green, the
# assertion's verdict does not reach the test result -- i.e. it is still inert.
# tests/helpers/prove-assertions-live.sh drives this across every call site in
# the suite; that script is the red-then-green evidence for this task.
#
# Unset (the normal case), this hook costs one string comparison and changes
# nothing.
_jenga_assert_verdict() {
  local src="$1" line="$2" ok="$3" msg="$4"

  if [ -n "${JENGA_ASSERT_MUTATE:-}" ]; then
    # bats preprocesses each .bats file into <tmp>/<n>-<name>.bats.src, so match
    # on the trailing filename rather than the full path. Line numbers survive
    # preprocessing intact.
    local base="${src##*/}"
    base="${base%.src}"
    base="${base#*-}"
    if [ "$base:$line" = "$JENGA_ASSERT_MUTATE" ]; then
      if [ "$ok" -eq 0 ]; then
        printf 'MUTATED %s:%s -- assertion passed, inverted to a failure.\n' "$base" "$line"
        return 1
      fi
      printf 'MUTATED %s:%s -- assertion failed, inverted to a pass.\n' "$base" "$line"
      return 0
    fi
  fi

  if [ "$ok" -ne 0 ]; then
    printf '%s\n' "$msg"
    return 1
  fi
  return 0
}

# Renders a value for a failure message, keeping long output readable.
_jenga_show() {
  printf -- '--- actual ---\n%s\n--------------\n' "$1"
}

# -----------------------------------------------------------------------------
# Assertions over bats' $output (set by `run`)
# -----------------------------------------------------------------------------

# assert_output_contains <substring>
assert_output_contains() {
  local src="${BASH_SOURCE[1]}" line="${BASH_LINENO[0]}" ok=1
  case "$output" in *"$1"*) ok=0 ;; esac
  _jenga_assert_verdict "$src" "$line" "$ok" \
    "expected output to CONTAIN: $1
$(_jenga_show "$output")"
}

# assert_output_not_contains <substring>
assert_output_not_contains() {
  local src="${BASH_SOURCE[1]}" line="${BASH_LINENO[0]}" ok=0
  case "$output" in *"$1"*) ok=1 ;; esac
  _jenga_assert_verdict "$src" "$line" "$ok" \
    "expected output NOT to contain: $1
$(_jenga_show "$output")"
}

# assert_output_contains_any <substring> [<substring>...]
# For genuine either/or conditions -- e.g. a skill that may legitimately be
# installed under its bare or its j- twin directory name.
assert_output_contains_any() {
  local src="${BASH_SOURCE[1]}" line="${BASH_LINENO[0]}" ok=1 needle
  for needle in "$@"; do
    case "$output" in *"$needle"*) ok=0 ;; esac
  done
  _jenga_assert_verdict "$src" "$line" "$ok" \
    "expected output to CONTAIN AT LEAST ONE OF: $*
$(_jenga_show "$output")"
}

# -----------------------------------------------------------------------------
# Assertions over an arbitrary string
# -----------------------------------------------------------------------------

# assert_contains <haystack> <needle>
assert_contains() {
  local src="${BASH_SOURCE[1]}" line="${BASH_LINENO[0]}" ok=1
  case "$1" in *"$2"*) ok=0 ;; esac
  _jenga_assert_verdict "$src" "$line" "$ok" \
    "expected value to CONTAIN: $2
$(_jenga_show "$1")"
}

# assert_not_contains <haystack> <needle>
assert_not_contains() {
  local src="${BASH_SOURCE[1]}" line="${BASH_LINENO[0]}" ok=0
  case "$1" in *"$2"*) ok=1 ;; esac
  _jenga_assert_verdict "$src" "$line" "$ok" \
    "expected value NOT to contain: $2
$(_jenga_show "$1")"
}

# assert_starts_with <string> <prefix>
assert_starts_with() {
  local src="${BASH_SOURCE[1]}" line="${BASH_LINENO[0]}" ok=1
  case "$1" in "$2"*) ok=0 ;; esac
  _jenga_assert_verdict "$src" "$line" "$ok" \
    "expected value to START WITH: $2
$(_jenga_show "$1")"
}

# assert_one_of <value> <candidate> [<candidate>...]
assert_one_of() {
  local src="${BASH_SOURCE[1]}" line="${BASH_LINENO[0]}" ok=1 value="$1" candidate
  shift
  for candidate in "$@"; do
    if [ "$value" = "$candidate" ]; then
      ok=0
    fi
  done
  _jenga_assert_verdict "$src" "$line" "$ok" \
    "expected value to EQUAL ONE OF: $*
$(_jenga_show "$value")"
}

# -----------------------------------------------------------------------------
# require_baseline_permissions (E72_S07_T02)
#
# Skip the current test when the working tree's settings files do NOT sit at the
# level-2 (Guarded) baseline. Use it in a case that drives a REAL mirror.sh push
# and therefore needs mirror.sh's check_permission_level_invariant to let the push
# through: while the session is elevated that invariant correctly refuses, so the
# case fails for a reason that has nothing to do with the change under test. That
# is what made every story's closing gate unpassable on 2026-10-22 (E72_S07).
#
# Do NOT use it in a case that builds its own elevated fixture (one that calls
# elevate_to_level_5 or writes the settings files itself). Those are immune to
# ambient state and are the coverage that proves the guard refuses a bad push —
# skipping them would hide the very regression class the suite exists for.
#
# The verdict comes from skills/j-test/scripts/baseline-permissions.sh, the sole
# decider, so this helper holds no copy of the signal. A skip here is visible as
# a bats skip, but note the scope test gate never relies on it: bats exits 0 on a
# skip, so the gate EXCLUDES marked files itself and reports them (see that
# script's "A SKIP IS NEVER A PASS").
# -----------------------------------------------------------------------------
require_baseline_permissions() {
  local root="${1:-$REPO_ROOT}"
  local decider="$root/skills/j-test/scripts/baseline-permissions.sh"
  if [ ! -f "$decider" ]; then
    return 0   # no decider on this checkout: behave exactly as before it existed
  fi
  if ! bash "$decider" check --root "$root" >/dev/null 2>&1; then
    skip "$(bash "$decider" reason --root "$root" 2>/dev/null \
            || printf 'the session is not at the level-2 baseline')"
  fi
}
