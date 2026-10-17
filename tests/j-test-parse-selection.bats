#!/usr/bin/env bats
#
# Coverage for skills/j-test/scripts/parse-selection.sh (E72_S02_T03).
#
# The script parses and validates the answer typed at the j.test prompt
# ("Enter selection (comma-separated, or 'all' for all, or blank for 1 through N):"). This suite pins every row of the
# grammar in the script's header with exact assertions: exact stdout, exact stderr and the exit code, never a substring.
#
# How the cases are written
#   - The script runs as `bash <script>` so the behaviour tests do not depend on the file's mode; the mode itself is
#     asserted by its own test below.
#   - stdout and stderr are captured separately (`run --separate-stderr`), because "nothing on stdout when the selection
#     is invalid" and "exact problem lines on stderr" are both part of the contract.
#   - Everything is in-process arguments: the script reads no file and needs no fixture. Scratch space (for the "writes
#     nothing to disk" case) lives under BATS_TEST_TMPDIR.

bats_require_minimum_version 1.5.0

load helpers/assertions

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
SCRIPT="$REPO_ROOT/skills/j-test/scripts/parse-selection.sh"

USAGE_LINE="usage: parse-selection.sh <N> [<input>]"
NL=$'\n'

# psel <args...>: run the script with stdout in $output and stderr in $stderr.
psel() {
  run --separate-stderr bash "$SCRIPT" "$@"
}

# expect_ok <expected stdout>: exit 0, exact stdout, empty stderr.
expect_ok() {
  [ "$status" -eq 0 ]
  [ "$output" = "$1" ]
  [ -z "$stderr" ]
}

# expect_invalid <expected stderr>: exit 1, EMPTY stdout, exact stderr.
expect_invalid() {
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  [ "$stderr" = "$1" ]
}

# expect_usage_error: exit 2, empty stdout, the usage line is the last stderr line.
expect_usage_error() {
  [ "$status" -eq 2 ]
  [ -z "$output" ]
  [ "${stderr##*"$NL"}" = "$USAGE_LINE" ]
}

# ---------------------------------------------------------------------------
# File properties
# ---------------------------------------------------------------------------

@test "parse-selection.sh exists and is executable" {
  [ -f "$SCRIPT" ]
  [ -x "$SCRIPT" ]
}

@test "the script is tracked in git with mode 100755" {
  run git -C "$REPO_ROOT" ls-files -s -- skills/j-test/scripts/parse-selection.sh
  [ "$status" -eq 0 ]
  assert_starts_with "$output" "100755 "
}

@test "parse-selection.sh passes shellcheck" {
  if ! command -v shellcheck >/dev/null 2>&1; then
    skip "shellcheck is not installed"
  fi
  run shellcheck -S warning "$SCRIPT"
  [ "$status" -eq 0 ]
}

@test "the script uses no bash 4+ construct (bash 3.2 compatibility)" {
  # Strip comment-only lines, then look for the constructs bash 3.2 lacks.
  local code
  code="$(grep -v '^[[:space:]]*#' "$SCRIPT")"
  assert_not_contains "$code" "mapfile"
  assert_not_contains "$code" "readarray"
  assert_not_contains "$code" "declare -A"
  assert_not_contains "$code" "local -A"
  assert_not_contains "$code" ",,}"
  assert_not_contains "$code" "^^}"
  assert_not_contains "$code" "&>>"
  assert_not_contains "$code" "|&"
}

@test "the script runs under /bin/bash (the macOS system bash 3.2 where present)" {
  [ -x /bin/bash ]
  run --separate-stderr /bin/bash "$SCRIPT" 4 "3,1"
  expect_ok "3${NL}1"
}

# ---------------------------------------------------------------------------
# Grammar rule 1: blank, whitespace-only and missing input mean "all"
# ---------------------------------------------------------------------------

@test "missing input prints 1 through N" {
  psel 4
  expect_ok "1${NL}2${NL}3${NL}4"
}

@test "empty-string input prints 1 through N" {
  psel 4 ""
  expect_ok "1${NL}2${NL}3${NL}4"
}

@test "whitespace-only input prints 1 through N" {
  psel 4 "   "
  expect_ok "1${NL}2${NL}3${NL}4"
}

@test "tab and newline whitespace-only input prints 1 through N" {
  psel 3 $'\t \n '
  expect_ok "1${NL}2${NL}3"
}

# ---------------------------------------------------------------------------
# Grammar rule 2: the word "all"
# ---------------------------------------------------------------------------

@test "'all' prints 1 through N" {
  psel 3 all
  expect_ok "1${NL}2${NL}3"
}

@test "'ALL' prints 1 through N" {
  psel 3 ALL
  expect_ok "1${NL}2${NL}3"
}

@test "mixed-case 'aLl' prints 1 through N" {
  psel 3 aLl
  expect_ok "1${NL}2${NL}3"
}

@test "' all ' with surrounding whitespace prints 1 through N" {
  psel 3 " all "
  expect_ok "1${NL}2${NL}3"
}

@test "'all,2' is rejected" {
  psel 4 "all,2"
  expect_invalid "invalid selection 'all': 'all' cannot be combined with other entries, choose 1 through 4"
}

@test "'2,all' is rejected" {
  psel 4 "2,all"
  expect_invalid "invalid selection 'all': 'all' cannot be combined with other entries, choose 1 through 4"
}

@test "'2, ALL' (whitespace, other case) is rejected and names the token as typed" {
  psel 4 "2, ALL"
  expect_invalid "invalid selection 'ALL': 'all' cannot be combined with other entries, choose 1 through 4"
}

@test "'allx' is not the word all and is rejected as non-numeric" {
  psel 4 allx
  expect_invalid "invalid selection 'allx': not a positive whole number, choose 1 through 4"
}

# ---------------------------------------------------------------------------
# Grammar rules 3 and 7: comma-separated positive integers, order preserved
# ---------------------------------------------------------------------------

@test "a single number prints just that number" {
  psel 4 2
  expect_ok "2"
}

@test "'1,3' prints 1 then 3" {
  psel 4 "1,3"
  expect_ok "1${NL}3"
}

@test "'3,1' keeps the order given" {
  psel 4 "3,1"
  expect_ok "3${NL}1"
}

@test "'1, 3' tolerates a space after the comma" {
  psel 4 "1, 3"
  expect_ok "1${NL}3"
}

@test "whitespace around every token and the whole input is ignored" {
  psel 4 "  4 ,  2 ,1  "
  expect_ok "4${NL}2${NL}1"
}

@test "a full permutation of 1..N is accepted in the order given" {
  psel 4 "4,3,2,1"
  expect_ok "4${NL}3${NL}2${NL}1"
}

@test "multi-digit numbers are accepted when within range" {
  psel 12 "10,2,12"
  expect_ok "10${NL}2${NL}12"
}

@test "N=1 with blank input prints 1" {
  psel 1
  expect_ok "1"
}

@test "N=1 with 'all' prints 1" {
  psel 1 all
  expect_ok "1"
}

@test "N=1 with '1' prints 1" {
  psel 1 1
  expect_ok "1"
}

@test "N=1 with '2' is out of range, naming 1 through 1" {
  psel 1 2
  expect_invalid "invalid selection '2': out of range, choose 1 through 1"
}

# ---------------------------------------------------------------------------
# Invalid classes, one at a time (grammar rules 3, 4, 5, 6)
# ---------------------------------------------------------------------------

@test "zero is rejected" {
  psel 4 0
  expect_invalid "invalid selection '0': not a positive whole number, choose 1 through 4"
}

@test "a negative number is rejected" {
  psel 4 -1
  expect_invalid "invalid selection '-1': not a positive whole number, choose 1 through 4"
}

@test "a leading zero is rejected" {
  psel 4 01
  expect_invalid "invalid selection '01': not a positive whole number, choose 1 through 4"
}

@test "a decimal is rejected" {
  psel 4 1.5
  expect_invalid "invalid selection '1.5': not a positive whole number, choose 1 through 4"
}

@test "non-numeric text is rejected" {
  psel 4 abc
  expect_invalid "invalid selection 'abc': not a positive whole number, choose 1 through 4"
}

@test "a plus sign is rejected" {
  psel 4 +1
  expect_invalid "invalid selection '+1': not a positive whole number, choose 1 through 4"
}

@test "a token with interior whitespace is rejected" {
  psel 4 "1 3"
  expect_invalid "invalid selection '1 3': not a positive whole number, choose 1 through 4"
}

@test "an empty token between commas is rejected" {
  psel 4 "1,,3"
  expect_invalid "invalid selection '': empty entry (stray comma), choose 1 through 4"
}

@test "a trailing comma is rejected" {
  psel 4 "1,3,"
  expect_invalid "invalid selection '': empty entry (stray comma), choose 1 through 4"
}

@test "a leading comma is rejected" {
  psel 4 ",1,3"
  expect_invalid "invalid selection '': empty entry (stray comma), choose 1 through 4"
}

@test "a lone comma reports two empty entries" {
  psel 4 ","
  expect_invalid "invalid selection '': empty entry (stray comma), choose 1 through 4${NL}invalid selection '': empty entry (stray comma), choose 1 through 4"
}

@test "a whitespace-only token between commas is an empty entry" {
  psel 4 "1, ,3"
  expect_invalid "invalid selection '': empty entry (stray comma), choose 1 through 4"
}

@test "a number above N is out of range" {
  psel 4 7
  expect_invalid "invalid selection '7': out of range, choose 1 through 4"
}

@test "N+1 is out of range and N is accepted (boundary)" {
  psel 4 5
  expect_invalid "invalid selection '5': out of range, choose 1 through 4"
  psel 4 4
  expect_ok "4"
}

@test "a very long number is out of range, not an arithmetic error" {
  psel 4 99999999999999999999999999
  expect_invalid "invalid selection '99999999999999999999999999': out of range, choose 1 through 4"
}

@test "a duplicate is rejected, not silently deduplicated" {
  psel 4 "1,3,1"
  expect_invalid "invalid selection '1': listed more than once, choose 1 through 4"
}

@test "adjacent duplicates are rejected" {
  psel 4 "2,2"
  expect_invalid "invalid selection '2': listed more than once, choose 1 through 4"
}

@test "a number repeated three times is reported once" {
  psel 4 "2,2,2"
  expect_invalid "invalid selection '2': listed more than once, choose 1 through 4"
}

@test "a range is rejected with a message saying ranges are unsupported" {
  psel 4 "1-3"
  expect_invalid "invalid selection '1-3': ranges are not supported, use 'all' or list the numbers (for example 1,2,3), choose 1 through 4"
  assert_contains "$stderr" "ranges are not supported"
}

@test "a range inside a list is rejected" {
  psel 6 "1,3-5"
  expect_invalid "invalid selection '3-5': ranges are not supported, use 'all' or list the numbers (for example 1,2,3), choose 1 through 6"
}

@test "a reversed range is rejected as a range" {
  psel 6 "5-3"
  expect_invalid "invalid selection '5-3': ranges are not supported, use 'all' or list the numbers (for example 1,2,3), choose 1 through 6"
}

@test "a dangling dash is not called a range" {
  psel 4 "1-"
  expect_invalid "invalid selection '1-': not a positive whole number, choose 1 through 4"
}

@test "a double-dash token is not called a range" {
  psel 6 "1-2-3"
  expect_invalid "invalid selection '1-2-3': not a positive whole number, choose 1 through 6"
}

# ---------------------------------------------------------------------------
# Several problems are reported together, in the order given
# ---------------------------------------------------------------------------

@test "every problem is reported in one run, in token order" {
  psel 4 "0,-1,01,1.5,abc,1,,3,,7,2,2,2,1-3,all,2,"
  expect_invalid "invalid selection '0': not a positive whole number, choose 1 through 4
invalid selection '-1': not a positive whole number, choose 1 through 4
invalid selection '01': not a positive whole number, choose 1 through 4
invalid selection '1.5': not a positive whole number, choose 1 through 4
invalid selection 'abc': not a positive whole number, choose 1 through 4
invalid selection '': empty entry (stray comma), choose 1 through 4
invalid selection '': empty entry (stray comma), choose 1 through 4
invalid selection '7': out of range, choose 1 through 4
invalid selection '2': listed more than once, choose 1 through 4
invalid selection '1-3': ranges are not supported, use 'all' or list the numbers (for example 1,2,3), choose 1 through 4
invalid selection 'all': 'all' cannot be combined with other entries, choose 1 through 4
invalid selection '': empty entry (stray comma), choose 1 through 4"
}

@test "an out-of-range number and a duplicate are both reported" {
  psel 4 "9,1,1"
  expect_invalid "invalid selection '9': out of range, choose 1 through 4
invalid selection '1': listed more than once, choose 1 through 4"
}

@test "valid entries beside an invalid one are not printed on stdout" {
  psel 4 "1,2,9"
  expect_invalid "invalid selection '9': out of range, choose 1 through 4"
}

@test "every message names the valid range for the given N" {
  psel 12 "13,x"
  expect_invalid "invalid selection '13': out of range, choose 1 through 12
invalid selection 'x': not a positive whole number, choose 1 through 12"
}

@test "nothing is written to stdout for any invalid class" {
  local input
  for input in 0 -1 01 1.5 abc "1,,3" "1,3," 7 "1,3,1" "all,2" "1-3" "9,1,1"; do
    psel 4 "$input"
    [ "$status" -eq 1 ]
    [ -z "$output" ]
    [ -n "$stderr" ]
  done
}

@test "shell metacharacters in the input are reported as text, never evaluated" {
  local marker="$BATS_TEST_TMPDIR/pwned"
  psel 4 "\$(touch $marker),\`touch $marker\`,;touch $marker"
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  [ ! -e "$marker" ]
}

# ---------------------------------------------------------------------------
# Usage errors and --help
# ---------------------------------------------------------------------------

@test "no arguments is a usage error" {
  psel
  expect_usage_error
}

@test "N=0 is a usage error" {
  psel 0
  expect_usage_error
  assert_contains "$stderr" "<N> must be a positive integer, got '0'"
}

@test "a negative N is a usage error" {
  psel -3
  expect_usage_error
}

@test "a non-numeric N is a usage error" {
  psel abc
  expect_usage_error
  assert_contains "$stderr" "<N> must be a positive integer, got 'abc'"
}

@test "an empty N is a usage error" {
  psel ""
  expect_usage_error
}

@test "a decimal N is a usage error" {
  psel 2.5 1
  expect_usage_error
}

@test "an N with a leading zero is a usage error" {
  psel 04 1
  expect_usage_error
}

@test "an N of more than 9 digits is a usage error" {
  psel 1234567890 1
  expect_usage_error
  assert_contains "$stderr" "<N> must be at most 9 digits"
}

@test "three arguments is a usage error" {
  psel 3 1 2
  expect_usage_error
  [ "$stderr" = "$USAGE_LINE" ]
}

@test "four arguments is a usage error" {
  psel 3 1 2 3
  expect_usage_error
}

@test "a usage error never prints a selection on stdout" {
  psel 0 all
  [ "$status" -eq 2 ]
  [ -z "$output" ]
}

@test "--help prints usage on stdout and exits 0" {
  psel --help
  [ "$status" -eq 0 ]
  [ -z "$stderr" ]
  assert_starts_with "$output" "$USAGE_LINE"
  assert_contains "$output" "Exit 0 valid, 1 invalid selection (problems on stderr), 2 usage error."
}

@test "--help as the second argument is input, not an option" {
  psel 4 --help
  expect_invalid "invalid selection '--help': not a positive whole number, choose 1 through 4"
}

# ---------------------------------------------------------------------------
# Determinism and side effects
# ---------------------------------------------------------------------------

@test "repeat runs are byte-identical (stdout, stderr, status)" {
  local out1 err1 out2 err2
  psel 5 "4,2,5"
  out1="$output"; err1="$stderr"
  psel 5 "4,2,5"
  out2="$output"; err2="$stderr"
  [ "$out1" = "$out2" ]
  [ "$err1" = "$err2" ]

  psel 5 "9,x,1,1"
  out1="$output"; err1="$stderr"
  psel 5 "9,x,1,1"
  out2="$output"; err2="$stderr"
  [ "$out1" = "$out2" ]
  [ "$err1" = "$err2" ]
}

@test "output does not depend on the locale" {
  local loc tested=0
  for loc in en_US.UTF-8 tr_TR.UTF-8; do
    # bash itself warns on stderr for a locale that is not installed (CI runners), so test only the installed ones
    locale -a 2>/dev/null | grep -qiE "^(${loc}|${loc/UTF-8/utf8})\$" || continue
    LC_ALL=$loc run --separate-stderr bash "$SCRIPT" 4 "ALL"
    expect_ok "1${NL}2${NL}3${NL}4"
    tested=$((tested + 1))
  done
  [ "$tested" -gt 0 ] || skip "neither en_US.UTF-8 nor tr_TR.UTF-8 is installed"
}

@test "the script writes nothing to disk, on success or failure" {
  local work="$BATS_TEST_TMPDIR/work" tmp="$BATS_TEST_TMPDIR/tmp"
  mkdir -p "$work" "$tmp"
  cd "$work"
  TMPDIR="$tmp" run --separate-stderr bash "$SCRIPT" 4 "3,1"
  [ "$status" -eq 0 ]
  TMPDIR="$tmp" run --separate-stderr bash "$SCRIPT" 4 "9,9,x"
  [ "$status" -eq 1 ]
  TMPDIR="$tmp" run --separate-stderr bash "$SCRIPT" 0
  [ "$status" -eq 2 ]
  [ -z "$(ls -A "$work")" ]
  [ -z "$(ls -A "$tmp")" ]
}

@test "the script needs no repository root: it runs from an unrelated directory" {
  cd "$BATS_TEST_TMPDIR"
  run --separate-stderr bash "$SCRIPT" 3 "2,3"
  expect_ok "2${NL}3"
}
