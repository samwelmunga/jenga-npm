#!/usr/bin/env bats
#
# E79_S04_T01: scripts/commit-ref.sh validate is the one safety gate every candidate commit ref must pass.
#
# What this pins (one named case per acceptance criterion, plus the contract around them):
#   - the default pattern: ASD-001 passes and is printed unchanged; asd-001, " ASD-001", "ASD-001 ", ASD-1x and an
#     empty input fail with exit 3 and nothing on stdout;
#   - hostile candidates (shell metacharacters, an embedded newline, a carriage return, NUL and other control bytes)
#     are all rejected with exit 3, and none of them creates a file or runs a command (a canary stays absent);
#   - the length cap: 64 characters pass, 65 fail, a huge stream is rejected without being held;
#   - a full match, not a search: a partial match fails, and an alternation pattern stays anchored as a whole;
#   - the candidate is read from stdin only (a positional argument is a usage error) and the script has no dynamic
#     execution (grep checks);
#   - the default pattern is read from the schema, never a literal in the script, and JENGA_CONVENTIONS_SCHEMA
#     redirects it; a recorded ref_pattern and --pattern override it, in that order;
#   - a pattern that cannot be used is exit 4, never a pass, and the allowlist still holds under the most permissive
#     pattern;
#   - usage errors, --help, bash -n and no bash 4 feature, no file written.
#
# The script is always run as `bash <script>`, so these cases do not depend on the file's executable bit.
# Everything the cases create lives under $BATS_TEST_TMPDIR.

bats_require_minimum_version 1.5.0
load helpers/assertions

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
SCRIPT="$REPO_ROOT/scripts/commit-ref.sh"
TEMPLATE_SCRIPT="$REPO_ROOT/scripts/commit-template.sh"
SCHEMA="$REPO_ROOT/templates/conventions-schema.json"
REAL_CONFIGS="$REPO_ROOT/project/configs"

setup() {
  REAL_SUM="$(find "$REAL_CONFIGS" -type f -exec cksum {} + | sort | cksum)"
  unset JENGA_CONVENTIONS_SCHEMA
  PROJ="$BATS_TEST_TMPDIR/proj"
  CFG="$PROJ/project/configs"
  CONV="$CFG/conventions.json"
  CANARY="$BATS_TEST_TMPDIR/canary"
  INPUT="$BATS_TEST_TMPDIR/input.bin"
  WORK="$BATS_TEST_TMPDIR/work"
  mkdir -p "$CFG" "$WORK"
  printf '{}\n' > "$CFG/workflow.json"
  export JENGA_PROJECT_ROOT="$PROJ"
  cd "$WORK" || return 1
}

teardown() {
  [ "$(find "$REAL_CONFIGS" -type f -exec cksum {} + | sort | cksum)" = "$REAL_SUM" ]
}

# --- helpers ---------------------------------------------------------------------------------------------------

# vr <candidate> [args...]: validate the candidate (exactly these bytes, no trailing newline) given on stdin.
vr() {
  local cand="$1"
  shift
  printf '%s' "$cand" > "$INPUT"
  run --separate-stderr bash "$SCRIPT" validate "$@" < "$INPUT"
}

# vrf <printf-format> [args...]: like vr, but the bytes come from a printf format (for NUL and other control bytes).
vrf() {
  local fmt="$1"
  shift
  printf "$fmt" > "$INPUT"
  run --separate-stderr bash "$SCRIPT" validate "$@" < "$INPUT"
}

# expect_reject: the last run was a rejection with nothing on stdout and exactly one reason line on stderr.
expect_reject() {
  [ "$status" -eq 3 ]
  [ -z "$output" ]
  [ -n "$stderr" ]
  [ "$(printf '%s\n' "$stderr" | wc -l | tr -d ' ')" = "1" ]
}

# base_json: an opted-in conventions.json with only the minimum recorded.
base_json() {
  cat <<'JSON'
{
  "conventions_version": 1,
  "categories": {
    "commit-format": {
      "source": "custom",
      "summary": "ref first",
      "values": { "style": "ref-first", "template": "{ref} {summary}", "apply_to_board_commits": true }
    }
  }
}
JSON
}

write_conv() {
  base_json | jq "$1" > "$CONV"
}

# --- the default pattern ---------------------------------------------------------------------------------------

@test "ASD-001 passes with the default pattern and is printed unchanged" {
  vr 'ASD-001'
  [ "$status" -eq 0 ]
  [ "$output" = "ASD-001" ]
  [ -z "$stderr" ]
}

@test "asd-001, a leading space, a trailing space, ASD-1x and an empty input fail with exit 3" {
  vr 'asd-001'
  expect_reject
  vr ' ASD-001'
  expect_reject
  vr 'ASD-001 '
  expect_reject
  vr 'ASD-1x'
  expect_reject
  vr ''
  expect_reject
  vrf ''
  expect_reject
}

@test "a single trailing line feed is tolerated; a carriage return, a doubled line feed and a bare line feed are not" {
  vrf 'ASD-001\n'
  [ "$status" -eq 0 ]
  [ "$output" = "ASD-001" ]
  vrf 'ASD-001\r\n'
  expect_reject
  vrf 'ASD-001\n\n'
  expect_reject
  vrf '\n'
  expect_reject
}

@test "no reason line repeats the candidate" {
  vr 'asd-001'
  [ "$status" -eq 3 ]
  assert_not_contains "$stderr" "asd-001"
}

# --- hostile candidates ----------------------------------------------------------------------------------------

@test "shell metacharacters, quotes and a space are rejected, and nothing is created or run" {
  local bad
  for bad in \
    "ASD-001;touch $CANARY" \
    "ASD-001\$(touch $CANARY)" \
    "ASD-001\`touch $CANARY\`" \
    "ASD-001|touch $CANARY" \
    "ASD-001&touch $CANARY" \
    "ASD-001>$CANARY" \
    "ASD-001'" \
    'ASD-001"' \
    'ASD-001 x' \
    'ASD-001*' \
    'ASD-001?' \
    'ASD-001\x' \
    'ASD-001#' \
    'ASD-001%s' \
    '$(id)' \
    '`id`' \
    ';id' \
    '-ASD-001' ; do
    vr "$bad"
    expect_reject
    [ ! -e "$CANARY" ]
  done
}

@test "an embedded newline is rejected, and the text after it does not run" {
  vrf "ASD-001\ntouch $CANARY\n"
  expect_reject
  vrf "ASD-001\nrm -rf x"
  expect_reject
  [ ! -e "$CANARY" ]
}

@test "a carriage return, NUL, and other control bytes are rejected" {
  vrf 'ASD-001\r'
  expect_reject
  vrf 'ASD\r-001'
  expect_reject
  vrf 'ASD-001\000'
  expect_reject
  vrf 'ASD-001\000x'
  expect_reject
  vrf '\000ASD-001'
  expect_reject
  vrf 'ASD-001\001'
  expect_reject
  vrf 'ASD-001\033'
  expect_reject
  vrf 'ASD-001\177'
  expect_reject
  vrf 'ASD-001\t'
  expect_reject
  vrf 'ASD-001\377'
  expect_reject
}

@test "the allowlist holds under the most permissive pattern" {
  local bad
  for bad in 'a;b' 'a b' 'a$(id)' 'a`id`' 'a|b'; do
    vr "$bad" --pattern '.+'
    expect_reject
  done
  vrf 'ab\000cd' --pattern '.+'
  expect_reject
  vrf 'ab\ncd' --pattern '.+'
  expect_reject
  vr 'abc' --pattern '.+'
  [ "$status" -eq 0 ]
  [ "$output" = "abc" ]
}

@test "a very large stream (one million NUL bytes, and one million letters) is rejected without being held" {
  run --separate-stderr bash -c 'head -c 1000000 /dev/zero | bash "$1" validate' _ "$SCRIPT"
  expect_reject
  run --separate-stderr bash -c 'head -c 1000000 /dev/zero | tr "\000" "A" | bash "$1" validate --pattern "A+"' _ "$SCRIPT"
  expect_reject
  assert_contains "$stderr" "longer"
}

# --- the length cap --------------------------------------------------------------------------------------------

# n_digits <n>: n digit characters.
n_digits() { head -c "$1" /dev/zero | tr '\000' '7'; }

@test "a 64-character otherwise-valid ref passes and a 65-character one is rejected" {
  local r64 r65
  r64="AB-$(n_digits 61)"
  r65="AB-$(n_digits 62)"
  [ "${#r64}" -eq 64 ]
  [ "${#r65}" -eq 65 ]
  vr "$r64"
  [ "$status" -eq 0 ]
  [ "$output" = "$r64" ]
  vr "$r65"
  expect_reject
  assert_contains "$stderr" "longer"
}

@test "the cap holds with a trailing line feed, and a 66-character ref is rejected" {
  local r64 r66
  r64="AB-$(n_digits 61)"
  r66="AB-$(n_digits 63)"
  vrf "$r64\\n"
  [ "$status" -eq 0 ]
  [ "$output" = "$r64" ]
  vrf "$r66\\n"
  expect_reject
  vr "$r66"
  expect_reject
}

@test "the cap is the one commit-template.sh enforces: it is read from there, not written in the script" {
  local cap
  cap="$(bash "$TEMPLATE_SCRIPT" derive '{ref}{summary}' | sed -n 's/^prefix_length=//p')"
  [ "$cap" = "64" ]
  grep -v '^[[:space:]]*#' "$SCRIPT" > "$BATS_TEST_TMPDIR/code.sh"
  run grep -c -E '(^|[^0-9])64([^0-9]|$)' "$BATS_TEST_TMPDIR/code.sh"
  [ "$output" = "0" ]
}

# --- a full match, not a search --------------------------------------------------------------------------------

@test "a partial match is rejected: ASD-001-extra, ASD-001x and ASD-001/2 against the default pattern" {
  vr 'ASD-001-extra'
  expect_reject
  vr 'ASD-001x'
  expect_reject
  vr 'ASD-001/2'
  expect_reject
}

@test "an alternation pattern stays anchored as a whole" {
  vr 'AB' --pattern 'A|B'
  expect_reject
  vr 'A' --pattern 'A|B'
  [ "$status" -eq 0 ]
  vr 'B' --pattern 'A|B'
  [ "$status" -eq 0 ]
  vr 'xA' --pattern 'A|B'
  expect_reject
}

@test "a pattern that matches only part of the candidate does not pass" {
  vr 'ASD-001' --pattern 'ASD'
  expect_reject
  vr 'ASD' --pattern 'ASD'
  [ "$status" -eq 0 ]
}

@test "a slash, dot, underscore and hyphen are allowed when the pattern accepts them" {
  vr 'feature/abc' --pattern '[a-z]+/[a-z]+'
  [ "$status" -eq 0 ]
  [ "$output" = "feature/abc" ]
  vr 'a.b_c-d' --pattern '[a-z._-]+'
  [ "$status" -eq 0 ]
}

# --- the candidate comes from stdin only -----------------------------------------------------------------------

@test "a positional candidate is a usage error, with or without --" {
  run --separate-stderr bash "$SCRIPT" validate ASD-001
  [ "$status" -eq 2 ]
  [ -z "$output" ]
  run --separate-stderr bash "$SCRIPT" validate -- ASD-001
  [ "$status" -eq 2 ]
  run --separate-stderr bash "$SCRIPT" validate --pattern 'A+' ASD-001
  [ "$status" -eq 2 ]
}

@test "-- alone ends the options and the candidate is still read from stdin" {
  printf 'ASD-001' > "$INPUT"
  run --separate-stderr bash "$SCRIPT" validate -- < "$INPUT"
  [ "$status" -eq 0 ]
  [ "$output" = "ASD-001" ]
}

@test "the script has no dynamic execution: no eval, no sh -c, no bash -c, no sourcing (whole file, comments included)" {
  run grep -c -E '(^|[^A-Za-z_])eval([[:space:]]|$)|sh -c|bash -c|(^|[^A-Za-z_])source([[:space:]]|$)|^[[:space:]]*\.[[:space:]]+[^ ]' "$SCRIPT"
  [ "$output" = "0" ]
}

# --- the default pattern is not a literal ----------------------------------------------------------------------

@test "the default pattern is not a literal in the script" {
  run grep -c -F '[A-Z][A-Z0-9]' "$SCRIPT"
  [ "$output" = "0" ]
  run grep -c -E '\[A-Z\]' "$SCRIPT"
  [ "$output" = "0" ]
}

@test "JENGA_CONVENTIONS_SCHEMA points at a scratch schema with another default and that default is used" {
  jq '.categories["commit-format"].values.ref_pattern.default = "[a-z]+-[0-9]+"' "$SCHEMA" > "$BATS_TEST_TMPDIR/schema.json"
  JENGA_CONVENTIONS_SCHEMA="$BATS_TEST_TMPDIR/schema.json" vr 'abc-12'
  [ "$status" -eq 0 ]
  [ "$output" = "abc-12" ]
  JENGA_CONVENTIONS_SCHEMA="$BATS_TEST_TMPDIR/schema.json" vr 'ASD-001'
  expect_reject
  # the real schema still gives the real default
  vr 'ASD-001'
  [ "$status" -eq 0 ]
  vr 'abc-12'
  expect_reject
}

@test "an opted-in project with no recorded ref_pattern gets the schema default, including a scratch one" {
  write_conv '.'
  vr 'ASD-001'
  [ "$status" -eq 0 ]
  jq '.categories["commit-format"].values.ref_pattern.default = "[a-z]+-[0-9]+"' "$SCHEMA" > "$BATS_TEST_TMPDIR/schema.json"
  JENGA_CONVENTIONS_SCHEMA="$BATS_TEST_TMPDIR/schema.json" vr 'abc-12'
  [ "$status" -eq 0 ]
}

@test "a schema with no ref_pattern default and a project that is not opted in is exit 4, never a pass" {
  jq 'del(.categories["commit-format"].values.ref_pattern.default)' "$SCHEMA" > "$BATS_TEST_TMPDIR/schema.json"
  JENGA_CONVENTIONS_SCHEMA="$BATS_TEST_TMPDIR/schema.json" vr 'ASD-001'
  [ "$status" -eq 4 ]
  [ -z "$output" ]
  [ -n "$stderr" ]
}

# --- the recorded pattern and --pattern -----------------------------------------------------------------------

@test "a recorded ref_pattern in an opted-in project replaces the default" {
  write_conv '.categories["commit-format"].values.ref_pattern = "PRJ-[0-9]+"'
  vr 'PRJ-12'
  [ "$status" -eq 0 ]
  [ "$output" = "PRJ-12" ]
  vr 'ASD-001'
  expect_reject
}

@test "--pattern wins over the recorded pattern" {
  write_conv '.categories["commit-format"].values.ref_pattern = "PRJ-[0-9]+"'
  vr 'ASD-001' --pattern 'ASD-[0-9]+'
  [ "$status" -eq 0 ]
  vr 'PRJ-12' --pattern 'ASD-[0-9]+'
  expect_reject
}

@test "--conventions names the file instead of the project's own" {
  write_conv '.'
  base_json | jq '.categories["commit-format"].values.ref_pattern = "zzz-[0-9]+"' > "$BATS_TEST_TMPDIR/other.json"
  vr 'zzz-9' --conventions "$BATS_TEST_TMPDIR/other.json"
  [ "$status" -eq 0 ]
  vr 'zzz-9'
  expect_reject
}

@test "a project that records a pattern but is not opted in uses the schema default" {
  write_conv '.categories["commit-format"].values.ref_pattern = "prj-[0-9]+" | .categories["commit-format"].values.apply_to_board_commits = false'
  vr 'ASD-001'
  [ "$status" -eq 0 ]
  vr 'prj-12'
  expect_reject
}

@test "an invalid conventions file is exit 4 and nothing is printed" {
  printf '{ not json' > "$CONV"
  vr 'ASD-001'
  [ "$status" -eq 4 ]
  [ -z "$output" ]
  [ -n "$stderr" ]
}

@test "--pattern given on its own does not read the conventions file at all" {
  printf '{ not json' > "$CONV"
  vr 'ASD-001' --pattern 'ASD-[0-9]+'
  [ "$status" -eq 0 ]
}

# --- a pattern that cannot be used ----------------------------------------------------------------------------

@test "an unusable --pattern is exit 4 and never a pass" {
  local long
  long="$(head -c 101 /dev/zero | tr '\000' 'A')"
  vr 'ASD-001' --pattern '('
  [ "$status" -eq 4 ]
  [ -z "$output" ]
  vr 'ASD-001' --pattern ''
  [ "$status" -eq 4 ]
  vr 'ASD-001' --pattern '(A)\1'
  [ "$status" -eq 4 ]
  vr 'ASD-001' --pattern '[0-9]*'
  [ "$status" -eq 4 ]
  vr 'ASD-001' --pattern "$long"
  [ "$status" -eq 4 ]
  vr 'ASD-001' --pattern 'A
B'
  [ "$status" -eq 4 ]
}

@test "a pattern containing shell metacharacters is data: it is matched, never run" {
  vr 'abc' --pattern "a\$(touch $CANARY)"
  [ "$status" -ne 0 ]
  [ ! -e "$CANARY" ]
  vr 'abc' --pattern "a\`touch $CANARY\`"
  [ "$status" -ne 0 ]
  [ ! -e "$CANARY" ]
}

# --- usage, help, text -----------------------------------------------------------------------------------------

@test "usage errors exit 2: no subcommand, an unknown subcommand, an unknown option, a missing value, a repeated option" {
  run --separate-stderr bash "$SCRIPT"
  [ "$status" -eq 2 ]
  run --separate-stderr bash "$SCRIPT" frobnicate
  [ "$status" -eq 2 ]
  run --separate-stderr bash "$SCRIPT" validate --bogus
  [ "$status" -eq 2 ]
  run --separate-stderr bash "$SCRIPT" validate --pattern
  [ "$status" -eq 2 ]
  run --separate-stderr bash "$SCRIPT" validate --conventions
  [ "$status" -eq 2 ]
  run --separate-stderr bash "$SCRIPT" validate --pattern 'A' --pattern 'B'
  [ "$status" -eq 2 ]
  [ -z "$output" ]
}

@test "--help and -h print the usage on stdout and exit 0" {
  run --separate-stderr bash "$SCRIPT" --help
  [ "$status" -eq 0 ]
  assert_output_contains "validate"
  [ -z "$stderr" ]
  run --separate-stderr bash "$SCRIPT" -h
  [ "$status" -eq 0 ]
}

@test "the script passes bash -n and uses no bash 4 feature (comments excluded)" {
  run bash -n "$SCRIPT"
  [ "$status" -eq 0 ]
  grep -v '^[[:space:]]*#' "$SCRIPT" > "$BATS_TEST_TMPDIR/code.sh"
  run grep -c -E 'declare -A|typeset -A|mapfile|readarray|,,\}|\^\^\}|\|&|&>>|\$\{[A-Za-z_]+@[UuLlQ]\}' "$BATS_TEST_TMPDIR/code.sh"
  [ "$output" = "0" ]
}

@test "the script writes no file: the working directory and the project's configs are unchanged" {
  write_conv '.'
  local before after
  before="$(find "$BATS_TEST_TMPDIR" -type f -not -name input.bin -not -name 'separate-stderr-*' | sort | xargs cksum | cksum)"
  vr 'ASD-001'
  vr 'asd-001'
  vrf 'ASD-001\000'
  after="$(find "$BATS_TEST_TMPDIR" -type f -not -name input.bin -not -name 'separate-stderr-*' | sort | xargs cksum | cksum)"
  [ "$before" = "$after" ]
  [ -z "$(ls -A "$WORK")" ]
}

@test "the verdict is deterministic: the same input gives the same status and output twice" {
  vr 'ASD-001'
  local s1="$status" o1="$output"
  vr 'ASD-001'
  [ "$s1" = "$status" ]
  [ "$o1" = "$output" ]
}
