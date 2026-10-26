#!/usr/bin/env bats
#
# E79_S04_T02: scripts/commit-ref.sh extract finds the first ref in a branch name (the perceived branch), safely.
#
# What this pins (one named case per acceptance criterion, plus the contract around them):
#   - the keys: feature/ASD-001-foo, ASD-001, bugfix/ASD-001 and user/jo/ASD-001_wip each yield ASD-001; main, develop,
#     release/2.4, HEAD, an empty input and a bare line feed are "no key" (exit 1, nothing printed, nothing on stderr);
#   - the token boundary, one case each: fix/xASD-001 and fix/ASD-0011x yield nothing; a key between non-alphanumeric
#     characters, or at either end, is found;
#   - two keys in one branch: the first wins, with no error;
#   - hostile branch names (shell metacharacters, command substitution, backticks, a percent sign, an embedded newline,
#     a carriage return, NUL) never run anything, never print more than one line, and leave a canary file absent;
#   - the cap: 200 characters are read (the cap is commit-template.sh's MAX_SUBJECT), 201 are rejected with exit 3 and
#     nothing printed before the pattern is applied, a huge stream is rejected without being held;
#   - the pattern: --pattern, a project-recorded ref_pattern and the schema default (including a scratch schema) take
#     effect in that order; a pattern that cannot be used is exit 4; a permissive pattern still cannot print an unsafe
#     value because the found text goes through validate;
#   - the name comes from stdin only (a positional argument is a usage error), the script writes no file, is
#     deterministic, passes bash -n and uses no bash 4 feature and no dynamic execution;
#   - validate is untouched (a sanity case; its own suite is tests/commit-ref-validate.bats).
#
# The script is always run as `bash <script>`, so these cases do not depend on the file's executable bit.
# Everything the cases create lives under $BATS_TEST_TMPDIR. These cases were written without being executed by their
# author; the tester runs them.

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

# ex <branch> [args...]: extract from the branch name (exactly these bytes, no trailing newline) given on stdin.
ex() {
  local name="$1"
  shift
  printf '%s' "$name" > "$INPUT"
  run --separate-stderr bash "$SCRIPT" extract "$@" < "$INPUT"
}

# exf <printf-format> [args...]: like ex, but the bytes come from a printf format (for NUL and other control bytes).
exf() {
  local fmt="$1"
  shift
  printf "$fmt" > "$INPUT"
  run --separate-stderr bash "$SCRIPT" extract "$@" < "$INPUT"
}

# expect_key <key>: the last run found exactly that one key and nothing else.
expect_key() {
  [ "$status" -eq 0 ]
  [ "$output" = "$1" ]
  [ -z "$stderr" ]
}

# expect_no_key: the last run found no key: exit 1, nothing on stdout, nothing on stderr (it is not an error).
expect_no_key() {
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  [ -z "$stderr" ]
}

# expect_reject: the last run was a rejection: exit 3, nothing on stdout, exactly one reason line on stderr.
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

# pad <n>: n letter x's.
pad() {
  head -c "$1" /dev/zero | tr '\000' 'x'
}

# --- the keys --------------------------------------------------------------------------------------------------

@test "feature/ASD-001-foo yields ASD-001" {
  ex 'feature/ASD-001-foo'
  expect_key 'ASD-001'
}

@test "a bare key, bugfix/ASD-001 and user/jo/ASD-001_wip each yield ASD-001" {
  ex 'ASD-001'
  expect_key 'ASD-001'
  ex 'bugfix/ASD-001'
  expect_key 'ASD-001'
  ex 'user/jo/ASD-001_wip'
  expect_key 'ASD-001'
}

@test "one trailing line feed is tolerated (the output of git branch --show-current)" {
  exf 'feature/ASD-001-foo\n'
  expect_key 'ASD-001'
}

@test "main, develop, release/2.4, HEAD, an empty input and a bare line feed hold no key: exit 1, no output" {
  ex 'main'
  expect_no_key
  ex 'develop'
  expect_no_key
  ex 'release/2.4'
  expect_no_key
  ex 'HEAD'
  expect_no_key
  ex ''
  expect_no_key
  exf ''
  expect_no_key
  exf '\n'
  expect_no_key
}

@test "a name with no key is not an error: the exit status is 1, not a usage or rejection code" {
  ex 'feature/some-work'
  [ "$status" -eq 1 ]
  [ -z "$stderr" ]
}

# --- the token boundary ----------------------------------------------------------------------------------------

@test "fix/xASD-001 yields nothing: the key is preceded by an alphanumeric character" {
  ex 'fix/xASD-001'
  expect_no_key
}

@test "fix/ASD-0011x yields nothing: the key is followed by an alphanumeric character, and no shorter key is cut out of it" {
  ex 'fix/ASD-0011x'
  expect_no_key
}

@test "a key is found at the start, in the middle and at the end, between non-alphanumeric characters" {
  ex 'ASD-001/foo'
  expect_key 'ASD-001'
  ex 'foo/ASD-001/bar'
  expect_key 'ASD-001'
  ex 'foo-ASD-001'
  expect_key 'ASD-001'
  ex 'foo.ASD-001.bar'
  expect_key 'ASD-001'
  ex 'foo_ASD-001_bar'
  expect_key 'ASD-001'
}

@test "a lower-case key is not a key under the default pattern" {
  ex 'feature/asd-001-foo'
  expect_no_key
}

@test "a non-ASCII branch name works: the bytes around the key count as boundaries" {
  exf 'caf\303\251/ASD-001'
  expect_key 'ASD-001'
}

# --- more than one key -----------------------------------------------------------------------------------------

@test "two keys in one branch yield the first, with no error" {
  ex 'ASD-001-and-ASD-002'
  expect_key 'ASD-001'
  ex 'feature/ASD-002/ASD-001'
  expect_key 'ASD-002'
}

# --- hostile branch names --------------------------------------------------------------------------------------

@test "shell metacharacters after the key are data: the key is found, one line is printed, nothing runs" {
  ex "feature/ASD-001;touch $CANARY"
  expect_key 'ASD-001'
  [ ! -e "$CANARY" ]
  ex "feature/ASD-001 && touch $CANARY"
  expect_key 'ASD-001'
  [ ! -e "$CANARY" ]
  ex "feature/ASD-001|touch $CANARY"
  expect_key 'ASD-001'
  [ ! -e "$CANARY" ]
}

@test "command substitution, backticks and a percent sign in the name are data" {
  ex "feature/ASD-001\$(touch $CANARY)"
  expect_key 'ASD-001'
  [ ! -e "$CANARY" ]
  ex "feature/ASD-001\`touch $CANARY\`"
  expect_key 'ASD-001'
  [ ! -e "$CANARY" ]
  ex 'feature/100%s%n-ASD-001'
  expect_key 'ASD-001'
  [ ! -e "$CANARY" ]
}

@test "a metacharacter inside the would-be key stops it from being a key" {
  ex 'feature/ASD;touch-001'
  expect_no_key
  ex 'feature/AS$(touch)D-001'
  expect_no_key
}

@test "an embedded newline is rejected: never a second line, never a second key, nothing runs" {
  exf 'feature/ASD-001\nASD-002'
  expect_reject
  exf "feature/ASD-001\\ntouch $CANARY"
  expect_reject
  [ ! -e "$CANARY" ]
  exf '\nASD-001'
  expect_reject
  exf 'ASD-001\n\n'
  expect_reject
}

@test "a carriage return, a NUL and other control bytes are rejected with nothing printed" {
  exf 'feature/ASD-001\r'
  expect_reject
  exf 'feature/ASD-001\000'
  expect_reject
  exf 'feature/\000ASD-001'
  expect_reject
  exf 'feature/\033ASD-001'
  expect_reject
  exf 'feature/\177ASD-001'
  expect_reject
}

@test "no reason line repeats the branch name" {
  exf 'secret-branch-name\nASD-001'
  [ "$status" -eq 3 ]
  assert_not_contains "$stderr" "secret-branch-name"
}

# --- the cap ---------------------------------------------------------------------------------------------------

@test "200 characters are read; 201 are rejected, although the key at the start would otherwise match" {
  # 'ASD-001/' is 8 characters.
  ex "ASD-001/$(pad 192)"
  expect_key 'ASD-001'
  ex "ASD-001/$(pad 193)"
  expect_reject
}

@test "the cap is the subject cap of commit-template.sh: the two scripts agree on 200 versus 201" {
  run grep -c -E '^readonly MAX_SUBJECT=200$' "$TEMPLATE_SCRIPT"
  [ "$output" = "1" ]
  run bash "$TEMPLATE_SCRIPT" match '{summary}' "$(pad 200)" --max-length 200
  [ "$status" -eq 0 ]
  run bash "$TEMPLATE_SCRIPT" match '{summary}' "$(pad 201)" --max-length 200
  [ "$status" -eq 1 ]
  [ "$output" = "too-long" ]
}

@test "the cap is read from commit-template.sh, not written in commit-ref.sh as a second literal" {
  grep -v '^[[:space:]]*#' "$SCRIPT" > "$BATS_TEST_TMPDIR/code.sh"
  run grep -c -E '(^|[^0-9])200([^0-9]|$)' "$BATS_TEST_TMPDIR/code.sh"
  [ "$output" = "0" ]
}

@test "an oversized input is rejected before the pattern is applied to it (a pattern that would match 201 characters)" {
  ex "ASD-001/$(pad 193)" --pattern 'ASD-[0-9]+'
  expect_reject
  ex "ASD-001/$(pad 192)" --pattern 'ASD-[0-9]+'
  expect_key 'ASD-001'
}

@test "a huge stream is rejected without being held" {
  run --separate-stderr bash -c "head -c 5000000 /dev/zero | tr '\\000' 'a' | bash '$SCRIPT' extract"
  [ "$status" -eq 3 ]
  [ -z "$output" ]
}

# --- the pattern -----------------------------------------------------------------------------------------------

@test "a custom --pattern takes effect" {
  ex 'feature/abc-12-foo' --pattern '[a-z]+-[0-9]+'
  expect_key 'abc-12'
  ex 'feature/ASD-001-foo' --pattern '[a-z]+-[0-9]+'
  expect_no_key
}

@test "an alternation in --pattern is one group: it cannot slip past the token boundary" {
  ex 'feat/ASD-1' --pattern 'ASD-[0-9]+|XYZ-[0-9]+'
  expect_key 'ASD-1'
  ex 'feat/xXYZ-1' --pattern 'ASD-[0-9]+|XYZ-[0-9]+'
  expect_no_key
  ex 'feat/XYZ-12y' --pattern 'ASD-[0-9]+|XYZ-[0-9]+'
  expect_no_key
}

@test "a pattern with its own groups still yields the whole key" {
  ex 'feat/ASD-12-x' --pattern '(ASD|XYZ)-([0-9]+)'
  expect_key 'ASD-12'
}

@test "a project-recorded ref_pattern takes effect" {
  write_conv '.categories["commit-format"].values.ref_pattern = "PRJ-[0-9]+"'
  ex 'feature/PRJ-12-foo'
  expect_key 'PRJ-12'
  ex 'feature/ASD-001-foo'
  expect_no_key
}

@test "--pattern wins over the recorded ref_pattern" {
  write_conv '.categories["commit-format"].values.ref_pattern = "PRJ-[0-9]+"'
  ex 'feature/ASD-001-foo' --pattern 'ASD-[0-9]+'
  expect_key 'ASD-001'
}

@test "with neither, the schema default is used, including a scratch schema's other default" {
  ex 'feature/ASD-001-foo'
  expect_key 'ASD-001'
  write_conv '.'
  ex 'feature/ASD-001-foo'
  expect_key 'ASD-001'
  jq '.categories["commit-format"].values.ref_pattern.default = "[a-z]+-[0-9]+"' "$SCHEMA" > "$BATS_TEST_TMPDIR/schema.json"
  JENGA_CONVENTIONS_SCHEMA="$BATS_TEST_TMPDIR/schema.json" ex 'feature/abc-12-foo'
  expect_key 'abc-12'
  JENGA_CONVENTIONS_SCHEMA="$BATS_TEST_TMPDIR/schema.json" ex 'feature/ASD-001-foo'
  expect_no_key
}

@test "a project that is not opted in uses the schema default even when a pattern is recorded" {
  write_conv '.categories["commit-format"].values.ref_pattern = "prj-[0-9]+" | .categories["commit-format"].values.apply_to_board_commits = false'
  ex 'feature/ASD-001-foo'
  expect_key 'ASD-001'
  ex 'feature/prj-12-foo'
  expect_no_key
}

@test "--conventions names the file instead of the project's own" {
  write_conv '.'
  base_json | jq '.categories["commit-format"].values.ref_pattern = "zzz-[0-9]+"' > "$BATS_TEST_TMPDIR/other.json"
  ex 'feature/zzz-9-foo' --conventions "$BATS_TEST_TMPDIR/other.json"
  expect_key 'zzz-9'
  ex 'feature/zzz-9-foo'
  expect_no_key
}

@test "an unusable pattern is exit 4 and never a key" {
  ex 'feature/ASD-001' --pattern '('
  [ "$status" -eq 4 ]
  [ -z "$output" ]
  ex 'feature/ASD-001' --pattern ''
  [ "$status" -eq 4 ]
  ex 'feature/ASD-001' --pattern '[0-9]*'
  [ "$status" -eq 4 ]
  ex 'feature/ASD-001' --pattern '(A)\1'
  [ "$status" -eq 4 ]
  printf '{ not json' > "$CONV"
  ex 'feature/ASD-001'
  [ "$status" -eq 4 ]
  [ -z "$output" ]
}

@test "a pattern with shell metacharacters is data: matched, never run" {
  ex 'feature/ASD-001' --pattern "a\$(touch $CANARY)"
  [ "$status" -ne 0 ]
  [ ! -e "$CANARY" ]
  ex 'feature/ASD-001' --pattern "a\`touch $CANARY\`"
  [ "$status" -ne 0 ]
  [ ! -e "$CANARY" ]
}

# --- the found text goes through validate ----------------------------------------------------------------------

@test "a permissive pattern that matches outside the allowlist yields exit 3 and prints nothing" {
  ex "feature/ASD-001;touch $CANARY" --pattern '.+'
  expect_reject
  [ ! -e "$CANARY" ]
  ex 'feature/ASD-001 foo' --pattern '.+'
  expect_reject
}

@test "a permissive pattern that happens to match only allowlisted characters still prints the found text" {
  ex 'feature/ASD-001' --pattern '.+'
  expect_key 'feature/ASD-001'
}

@test "a found text over the ref cap fails validate: exit 3" {
  ex "$(pad 70)" --pattern 'x+'
  expect_reject
}

@test "extract prints exactly what validate would print for the same text" {
  ex 'feature/ASD-001-foo'
  local got="$output"
  printf 'ASD-001' > "$INPUT"
  run --separate-stderr bash "$SCRIPT" validate < "$INPUT"
  [ "$status" -eq 0 ]
  [ "$output" = "$got" ]
}

# --- the name comes from stdin only ----------------------------------------------------------------------------

@test "a positional branch name is a usage error, with or without --" {
  run --separate-stderr bash "$SCRIPT" extract feature/ASD-001
  [ "$status" -eq 2 ]
  [ -z "$output" ]
  run --separate-stderr bash "$SCRIPT" extract -- feature/ASD-001
  [ "$status" -eq 2 ]
  run --separate-stderr bash "$SCRIPT" extract --pattern 'A+' feature/ASD-001
  [ "$status" -eq 2 ]
}

@test "-- alone ends the options and the name is still read from stdin" {
  printf 'feature/ASD-001' > "$INPUT"
  run --separate-stderr bash "$SCRIPT" extract -- < "$INPUT"
  [ "$status" -eq 0 ]
  [ "$output" = "ASD-001" ]
}

@test "usage errors exit 2: an unknown option, a missing value, a repeated option" {
  run --separate-stderr bash "$SCRIPT" extract --bogus
  [ "$status" -eq 2 ]
  run --separate-stderr bash "$SCRIPT" extract --pattern
  [ "$status" -eq 2 ]
  run --separate-stderr bash "$SCRIPT" extract --conventions
  [ "$status" -eq 2 ]
  run --separate-stderr bash "$SCRIPT" extract --pattern 'A' --pattern 'B'
  [ "$status" -eq 2 ]
  [ -z "$output" ]
}

@test "--help names both subcommands, and the usage error for an unknown subcommand does too" {
  run --separate-stderr bash "$SCRIPT" --help
  [ "$status" -eq 0 ]
  assert_output_contains "extract"
  assert_output_contains "validate"
  run --separate-stderr bash "$SCRIPT" frobnicate
  [ "$status" -eq 2 ]
  assert_contains "$stderr" "extract"
}

# --- the script itself ----------------------------------------------------------------------------------------

@test "the script has no dynamic execution: no eval, no sh -c, no bash -c, no sourcing (whole file, comments included)" {
  run grep -c -E '(^|[^A-Za-z_])eval([[:space:]]|$)|sh -c|bash -c|(^|[^A-Za-z_])source([[:space:]]|$)|^[[:space:]]*\.[[:space:]]+[^ ]' "$SCRIPT"
  [ "$output" = "0" ]
}

@test "the default pattern is still not a literal in the script" {
  run grep -c -F '[A-Z][A-Z0-9]' "$SCRIPT"
  [ "$output" = "0" ]
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
  ex 'feature/ASD-001-foo'
  ex 'main'
  exf 'feature/ASD-001\000'
  after="$(find "$BATS_TEST_TMPDIR" -type f -not -name input.bin -not -name 'separate-stderr-*' | sort | xargs cksum | cksum)"
  [ "$before" = "$after" ]
  [ -z "$(ls -A "$WORK")" ]
}

@test "the verdict is deterministic: the same input gives the same status and output twice" {
  ex 'feature/ASD-001-foo'
  local s1="$status" o1="$output"
  ex 'feature/ASD-001-foo'
  [ "$s1" = "$status" ]
  [ "$o1" = "$output" ]
}

@test "validate is unchanged by the new subcommand: the same candidates still pass and fail with the same codes" {
  printf 'ASD-001' > "$INPUT"
  run --separate-stderr bash "$SCRIPT" validate < "$INPUT"
  [ "$status" -eq 0 ]
  [ "$output" = "ASD-001" ]
  printf 'feature/ASD-001' > "$INPUT"
  run --separate-stderr bash "$SCRIPT" validate < "$INPUT"
  [ "$status" -eq 3 ]
  [ -z "$output" ]
  run --separate-stderr bash "$SCRIPT" validate --pattern '(' < "$INPUT"
  [ "$status" -eq 4 ]
  run --separate-stderr bash "$SCRIPT" validate ASD-001 < "$INPUT"
  [ "$status" -eq 2 ]
}
