#!/usr/bin/env bats
#
# Coverage for skills/j-commit/scripts/test-gate-decide.sh (E72_S04_T01).
#
# The script is the pure-logic half of the j.commit test gate: it resolves whether the gate prompts, runs or skips,
# renders the prompts, parses the answers and owns the proceed/halt table. This suite pins every row of the contract in
# the script's header with exact assertions: exact stdout (byte-exact for the prompts, via cmp), exact stderr where the
# contract names it, and the exit code.
#
# How the cases are written
#   - The script runs as `bash <script>`, so the behaviour tests never depend on the file's mode (the executable bit is
#     asserted by T07, not here).
#   - Every configuration case uses a scratch project root under BATS_TEST_TMPDIR reached through JENGA_PROJECT_ROOT.
#     Nothing here reads or writes this repository's project/configs/, and no real test command is ever run.
#   - stdout and stderr are captured separately (`run --separate-stderr`): "nothing on stdout when an answer is invalid"
#     and "a message on stderr" are both part of the contract.
#   - Assertions use `[ ]` and tests/helpers/assertions.bash only; a line starting with `[[` is banned repo-wide by
#     tests/bats-assertion-convention.bats.

# shellcheck disable=SC2030,SC2031
# (bats runs each test in a subshell; the helpers read status/output/stderr set by `run`.)

bats_require_minimum_version 1.5.0

load helpers/assertions

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
SCRIPT="$REPO_ROOT/skills/j-commit/scripts/test-gate-decide.sh"
BASH_BIN="$(command -v bash)"

NI_REASON="non-interactive caller: tests are not run on an agent's behalf"
NL=$'\n'

setup() {
  ROOT="$BATS_TEST_TMPDIR/root"
  CFG_DIR="$ROOT/project/configs"
  mkdir -p "$CFG_DIR"
  printf '%s' '{}' > "$CFG_DIR/workflow.json"
  export JENGA_PROJECT_ROOT="$ROOT"
  unset JENGA_COMMIT_INLINE JENGA_COMMIT_NONINTERACTIVE
}

# tgd <args...>: run the script, stdout in $output, stderr in $stderr.
tgd() {
  run --separate-stderr "$BASH_BIN" "$SCRIPT" "$@"
}

# set_cfg <raw file content>: write the scratch test-config.json.
set_cfg() {
  printf '%s' "$1" > "$CFG_DIR/test-config.json"
}

# exp <action> <choice-json> <recorded> <source> <noninteractive> <reason> [<warnings-json-items>]
# The exact line `resolve` must print.
exp() {
  printf '{"action":"%s","choice":%s,"recorded_default":"%s","default_source":"%s","noninteractive":%s,"reason":"%s","warnings":[%s]}' \
    "$1" "$2" "$3" "$4" "$5" "$6" "${7-}"
}

# expect_ok <expected stdout>: exit 0, exact stdout, empty stderr.
expect_ok() {
  [ "$status" -eq 0 ]
  [ "$output" = "$1" ]
  [ -z "$stderr" ]
}

# expect_invalid_answer <needle>: exit 1, EMPTY stdout, a stderr message that names the input.
expect_invalid_answer() {
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  [ -n "$stderr" ]
  assert_contains "$stderr" "$1"
}

# expect_usage_error: exit 2, empty stdout, the usage header on stderr.
expect_usage_error() {
  [ "$status" -eq 2 ]
  [ -z "$output" ]
  assert_contains "$stderr" "usage: test-gate-decide.sh"
}

# ---------------------------------------------------------------------------
# File properties and the header contract
# ---------------------------------------------------------------------------

@test "script exists, is bash, and passes bash -n" {
  [ -f "$SCRIPT" ]
  [ "$(head -n 1 "$SCRIPT")" = "#!/usr/bin/env bash" ]
  "$BASH_BIN" -n "$SCRIPT"
}

@test "script passes shellcheck" {
  if ! command -v shellcheck >/dev/null 2>&1; then
    skip "shellcheck is not installed"
  fi
  run shellcheck -S warning "$SCRIPT"
  [ "$status" -eq 0 ]
}

@test "header documents every subcommand and the exit codes" {
  local sub header
  header="$(sed -n '1,/^set -euo pipefail/p' "$SCRIPT")"
  for sub in resolve prompt answer fallback-prompt fallback-answer failure-prompt failure-answer directive; do
    assert_contains "$header" "# $sub"
  done
  assert_contains "$header" "Exit codes"
  assert_contains "$header" "NON-INTERACTIVE WINS"
  assert_contains "$header" "BLANK IS INVALID"
  assert_contains "$header" "macOS bash 3.2"
}

@test "no side effect: no git, network or file-writing command appears outside comments" {
  local code
  code="$(grep -v '^[[:space:]]*#' "$SCRIPT")"
  run grep -E '(^|[^[:alnum:]_.-])(git|curl|wget|ssh|nc|rm|mv|cp|tee|mkdir|touch|mktemp|chmod|ln|dd|sed -i)[[:space:]]' <<<"$code"
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  # No output redirection to a file either (no append, no redirect to a quoted, variable or relative path); the
  # only redirections the script uses are >&2 and 2>/dev/null.
  run grep -E -e '>>' -e '>[[:space:]]+["$~.]' <<<"$code"
  [ "$status" -eq 1 ]
}

@test "bash 3.2 compatibility: no mapfile, associative arrays, case-modifying expansions or [[ -v" {
  local code
  code="$(grep -v '^[[:space:]]*#' "$SCRIPT")"
  run grep -E 'mapfile|readarray|declare -A|\$\{[A-Za-z_]+(,,|\^\^)|\[\[ -v' <<<"$code"
  [ "$status" -eq 1 ]
}

@test "running every subcommand writes nothing and never calls git" {
  local bin="$BATS_TEST_TMPDIR/shim-bin" before after
  mkdir -p "$bin"
  printf '#!/bin/sh\necho called >> "%s/git.log"\nexit 99\n' "$BATS_TEST_TMPDIR" > "$bin/git"
  "$BASH_BIN" -c "chmod +x '$bin/git'" 2>/dev/null || skip "chmod unavailable in this environment"
  set_cfg '{"commit_prompt_default":"full"}'
  before="$(cd "$ROOT" && find . -type f -exec cksum {} + | sort)"
  PATH="$bin:$PATH" "$BASH_BIN" "$SCRIPT" resolve >/dev/null
  PATH="$bin:$PATH" "$BASH_BIN" "$SCRIPT" prompt >/dev/null
  PATH="$bin:$PATH" "$BASH_BIN" "$SCRIPT" answer 1 >/dev/null
  PATH="$bin:$PATH" "$BASH_BIN" "$SCRIPT" fallback-prompt --reason x >/dev/null
  PATH="$bin:$PATH" "$BASH_BIN" "$SCRIPT" fallback-answer 1 >/dev/null
  PATH="$bin:$PATH" "$BASH_BIN" "$SCRIPT" failure-prompt --failed x >/dev/null
  PATH="$bin:$PATH" "$BASH_BIN" "$SCRIPT" failure-answer 1 >/dev/null
  PATH="$bin:$PATH" "$BASH_BIN" "$SCRIPT" directive passed >/dev/null
  after="$(cd "$ROOT" && find . -type f -exec cksum {} + | sort)"
  [ "$before" = "$after" ]
  [ ! -e "$BATS_TEST_TMPDIR/git.log" ]
}

# ---------------------------------------------------------------------------
# Dispatch and usage errors
# ---------------------------------------------------------------------------

@test "no arguments, an unknown subcommand and unknown flags are usage errors (exit 2)" {
  tgd
  expect_usage_error
  tgd frobnicate
  expect_usage_error
  tgd resolve --bogus
  expect_usage_error
  tgd prompt --bogus
  expect_usage_error
  tgd directive passed --bogus
  expect_usage_error
  tgd failure-prompt --failed x --bogus
  expect_usage_error
  tgd answer 1 extra
  expect_usage_error
}

@test "flags missing their value are usage errors" {
  tgd resolve --tests
  expect_usage_error
  tgd resolve --root
  expect_usage_error
  tgd prompt --default
  expect_usage_error
  tgd answer 1 --default
  expect_usage_error
  tgd directive failed --choice
  expect_usage_error
}

@test "--help prints the usage and exits 0" {
  tgd --help
  [ "$status" -eq 0 ]
  assert_starts_with "$output" "usage: test-gate-decide.sh"
}

# ---------------------------------------------------------------------------
# resolve: non-interactive wins
# ---------------------------------------------------------------------------

@test "resolve: --caller noninteractive skips, ignoring --tests and the recorded default" {
  set_cfg '{"commit_prompt_default":"full"}'
  tgd resolve --caller noninteractive --tests full
  expect_ok "$(exp skip '"skip"' full config true "$NI_REASON")"
}

@test "resolve: --inline skips, ignoring --tests and the recorded default" {
  set_cfg '{"commit_prompt_default":"scoped"}'
  tgd resolve --inline --tests full
  expect_ok "$(exp skip '"skip"' scoped config true "$NI_REASON")"
}

@test "resolve: JENGA_COMMIT_INLINE=1 skips, ignoring --tests and the recorded default" {
  set_cfg '{"commit_prompt_default":"full"}'
  JENGA_COMMIT_INLINE=1 tgd resolve --tests scoped
  expect_ok "$(exp skip '"skip"' full config true "$NI_REASON")"
}

@test "resolve: JENGA_COMMIT_NONINTERACTIVE=1 skips, ignoring --tests and the recorded default" {
  set_cfg '{"commit_prompt_default":"full"}'
  JENGA_COMMIT_NONINTERACTIVE=1 tgd resolve --tests ask
  expect_ok "$(exp skip '"skip"' full config true "$NI_REASON")"
}

@test "resolve: each trigger skips on its own with no config and no --tests" {
  tgd resolve --caller noninteractive
  expect_ok "$(exp skip '"skip"' "" absent true "$NI_REASON")"
  tgd resolve --inline
  expect_ok "$(exp skip '"skip"' "" absent true "$NI_REASON")"
  JENGA_COMMIT_INLINE=1 tgd resolve
  expect_ok "$(exp skip '"skip"' "" absent true "$NI_REASON")"
  JENGA_COMMIT_NONINTERACTIVE=1 tgd resolve
  expect_ok "$(exp skip '"skip"' "" absent true "$NI_REASON")"
}

@test "resolve: the environment triggers fire only for the exact value 1" {
  JENGA_COMMIT_INLINE=0 JENGA_COMMIT_NONINTERACTIVE=true tgd resolve
  expect_ok "$(exp prompt null "" absent false "no recorded default")"
  JENGA_COMMIT_INLINE="" JENGA_COMMIT_NONINTERACTIVE=yes tgd resolve
  expect_ok "$(exp prompt null "" absent false "no recorded default")"
}

@test "resolve: --caller interactive does not make the call non-interactive" {
  tgd resolve --caller interactive
  expect_ok "$(exp prompt null "" absent false "no recorded default")"
}

@test "resolve: a non-interactive caller with a bad --tests is still a usage error" {
  tgd resolve --caller noninteractive --tests bogus
  expect_usage_error
  JENGA_COMMIT_INLINE=1 tgd resolve --tests bogus
  expect_usage_error
}

# ---------------------------------------------------------------------------
# resolve: --tests
# ---------------------------------------------------------------------------

@test "resolve: --tests ask prompts" {
  tgd resolve --tests ask
  expect_ok "$(exp prompt null "" absent false "per-invocation override")"
}

@test "resolve: --tests skip skips" {
  tgd resolve --tests skip
  expect_ok "$(exp skip '"skip"' "" absent false "per-invocation override")"
}

@test "resolve: --tests scoped runs scoped" {
  tgd resolve --tests scoped
  expect_ok "$(exp run '"scoped"' "" absent false "per-invocation override")"
}

@test "resolve: --tests full runs full" {
  tgd resolve --tests full
  expect_ok "$(exp run '"full"' "" absent false "per-invocation override")"
}

@test "resolve: an invalid --tests value is a usage error" {
  local v
  for v in bogus Full all 1 yes ""; do
    tgd resolve --tests "$v"
    expect_usage_error
  done
}

@test "resolve: an invalid --caller value is a usage error" {
  tgd resolve --caller robot
  expect_usage_error
  tgd resolve --caller ""
  expect_usage_error
}

@test "resolve: --tests overrides every recorded default for that invocation" {
  set_cfg '{"commit_prompt_default":"full"}'
  tgd resolve --tests skip
  expect_ok "$(exp skip '"skip"' full config false "per-invocation override")"
  tgd resolve --tests scoped
  expect_ok "$(exp run '"scoped"' full config false "per-invocation override")"
  tgd resolve --tests ask
  expect_ok "$(exp prompt null full config false "per-invocation override")"
}

# ---------------------------------------------------------------------------
# resolve: recorded default
# ---------------------------------------------------------------------------

@test "resolve: recorded default skip skips without a prompt" {
  set_cfg '{"commit_prompt_default":"skip"}'
  tgd resolve
  expect_ok "$(exp skip '"skip"' skip config false "recorded default")"
}

@test "resolve: recorded default scoped runs scoped" {
  set_cfg '{"commit_prompt_default":"scoped"}'
  tgd resolve
  expect_ok "$(exp run '"scoped"' scoped config false "recorded default")"
}

@test "resolve: recorded default full runs full" {
  set_cfg '{"commit_prompt_default":"full"}'
  tgd resolve
  expect_ok "$(exp run '"full"' full config false "recorded default")"
}

@test "resolve: an explicit empty recorded default prompts and counts as configured" {
  set_cfg '{"commit_prompt_default":""}'
  tgd resolve
  expect_ok "$(exp prompt null "" config false "no recorded default")"
}

@test "resolve: unrelated keys in test-config.json do not matter" {
  set_cfg '{"commit_scope_map_file":"templates/test-scope-map.json","tools":{"unit":[]},"commit_prompt_default":"full"}'
  tgd resolve
  expect_ok "$(exp run '"full"' full config false "recorded default")"
}

# ---------------------------------------------------------------------------
# resolve: absent and invalid configuration (never an error)
# ---------------------------------------------------------------------------

@test "resolve: an absent test-config.json reads as no default (absent, no warning)" {
  [ ! -e "$CFG_DIR/test-config.json" ]
  tgd resolve
  expect_ok "$(exp prompt null "" absent false "no recorded default")"
}

@test "resolve: an absent commit_prompt_default key reads as no default (absent, no warning)" {
  set_cfg '{"commit_scope_map_file":"templates/test-scope-map.json"}'
  tgd resolve
  expect_ok "$(exp prompt null "" absent false "no recorded default")"
}

@test "resolve: a null commit_prompt_default reads as no default (absent, no warning)" {
  set_cfg '{"commit_prompt_default":null}'
  tgd resolve
  expect_ok "$(exp prompt null "" absent false "no recorded default")"
}

@test "resolve: a root with no registry at all reads as absent" {
  local bare="$BATS_TEST_TMPDIR/bare"
  mkdir -p "$bare"
  JENGA_PROJECT_ROOT="$bare" tgd resolve
  expect_ok "$(exp prompt null "" absent false "no recorded default")"
}

@test "resolve: an out-of-range string is invalid, warns naming the value, and prompts" {
  set_cfg '{"commit_prompt_default":"bogus"}'
  tgd resolve
  expect_ok "$(exp prompt null "" invalid false "no recorded default" \
    '"test-config.json: commit_prompt_default is \"bogus\", expected \"\", \"skip\", \"scoped\" or \"full\"; treating it as unset"')"
}

@test "resolve: values differing only in case, or of the wrong type, are invalid" {
  local v
  for v in '"Full"' '"SKIP"' '" skip"' '5' 'true' '{}' '[]' '"all"'; do
    set_cfg "{\"commit_prompt_default\":$v}"
    tgd resolve
    [ "$status" -eq 0 ]
    [ "$(printf '%s' "$output" | jq -r '.default_source')" = "invalid" ]
    [ "$(printf '%s' "$output" | jq -r '.recorded_default')" = "" ]
    [ "$(printf '%s' "$output" | jq -r '.action')" = "prompt" ]
    [ "$(printf '%s' "$output" | jq -r '.warnings | length')" = "1" ]
    assert_contains "$(printf '%s' "$output" | jq -r '.warnings[0]')" "commit_prompt_default is $v,"
    [ -z "$stderr" ]
  done
}

@test "resolve: a file that is not valid JSON is invalid with a warning" {
  set_cfg '{"commit_prompt_default": "full"'
  tgd resolve
  expect_ok "$(exp prompt null "" invalid false "no recorded default" \
    '"test-config.json could not be read as a JSON object; treating commit_prompt_default as unset"')"
}

@test "resolve: an empty file, a non-object root and a directory are invalid with a warning" {
  local w='"test-config.json could not be read as a JSON object; treating commit_prompt_default as unset"'
  set_cfg ''
  tgd resolve
  expect_ok "$(exp prompt null "" invalid false "no recorded default" "$w")"
  set_cfg '["skip"]'
  tgd resolve
  expect_ok "$(exp prompt null "" invalid false "no recorded default" "$w")"
  set_cfg '"full"'
  tgd resolve
  expect_ok "$(exp prompt null "" invalid false "no recorded default" "$w")"
  rm -f "$CFG_DIR/test-config.json"
  mkdir "$CFG_DIR/test-config.json"
  tgd resolve
  expect_ok "$(exp prompt null "" invalid false "no recorded default" "$w")"
}

@test "resolve: an unreadable file is invalid with a warning" {
  local w='"test-config.json could not be read as a JSON object; treating commit_prompt_default as unset"'
  if [ "$(id -u)" -eq 0 ]; then
    skip "running as root: file permissions do not make the file unreadable"
  fi
  set_cfg '{"commit_prompt_default":"full"}'
  chmod 000 "$CFG_DIR/test-config.json" 2>/dev/null || skip "chmod unavailable in this environment"
  if [ -r "$CFG_DIR/test-config.json" ]; then
    chmod 600 "$CFG_DIR/test-config.json"
    skip "file stayed readable after chmod 000"
  fi
  tgd resolve
  chmod 600 "$CFG_DIR/test-config.json"
  expect_ok "$(exp prompt null "" invalid false "no recorded default" "$w")"
}

@test "resolve: an invalid default still lets --tests decide and a non-interactive caller skip" {
  set_cfg '{"commit_prompt_default":"bogus"}'
  tgd resolve --tests full
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r '.action')" = "run" ]
  [ "$(printf '%s' "$output" | jq -r '.choice')" = "full" ]
  [ "$(printf '%s' "$output" | jq -r '.default_source')" = "invalid" ]
  tgd resolve --inline
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r '.action')" = "skip" ]
  [ "$(printf '%s' "$output" | jq -r '.noninteractive')" = "true" ]
}

# ---------------------------------------------------------------------------
# resolve: configs resolution and output shape
# ---------------------------------------------------------------------------

@test "resolve: --root anchors configs resolution at the named directory" {
  local other="$BATS_TEST_TMPDIR/other"
  mkdir -p "$other/project/configs"
  printf '%s' '{}' > "$other/project/configs/workflow.json"
  printf '%s' '{"commit_prompt_default":"scoped"}' > "$other/project/configs/test-config.json"
  set_cfg '{"commit_prompt_default":"full"}'
  env -u JENGA_PROJECT_ROOT "$BASH_BIN" "$SCRIPT" resolve --root "$other" > "$BATS_TEST_TMPDIR/out" 2> "$BATS_TEST_TMPDIR/err"
  [ "$(cat "$BATS_TEST_TMPDIR/out")" = "$(exp run '"scoped"' scoped config false "recorded default")" ]
  [ ! -s "$BATS_TEST_TMPDIR/err" ]
}

@test "resolve: --root naming a missing directory is a usage error" {
  tgd resolve --root "$BATS_TEST_TMPDIR/does-not-exist"
  expect_usage_error
}

@test "resolve: output is one compact JSON line with the documented keys in order" {
  set_cfg '{"commit_prompt_default":"skip"}'
  tgd resolve
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | wc -l | tr -d ' ')" = "1" ]
  [ "$(printf '%s' "$output" | jq -c 'keys_unsorted')" = '["action","choice","recorded_default","default_source","noninteractive","reason","warnings"]' ]
  [ "$(printf '%s' "$output" | jq -r '.noninteractive | type')" = "boolean" ]
  [ "$(printf '%s' "$output" | jq -r '.warnings | type')" = "array" ]
}

@test "resolve: choice is the JSON null (not a string) when the action is prompt" {
  tgd resolve
  [ "$(printf '%s' "$output" | jq -r '.choice | type')" = "null" ]
}

@test "resolve: repeated invocations are byte-identical" {
  local a b
  set_cfg '{"commit_prompt_default":"bogus"}'
  a="$("$BASH_BIN" "$SCRIPT" resolve)"
  b="$("$BASH_BIN" "$SCRIPT" resolve)"
  [ "$a" = "$b" ]
}

@test "resolve: without jq it exits 1 with a message naming jq, while prompt still works" {
  local bin="$BATS_TEST_TMPDIR/nojq-bin" t
  mkdir -p "$bin"
  for t in bash dirname tr cat; do
    ln -s "$(command -v "$t")" "$bin/$t"
  done
  run --separate-stderr env PATH="$bin" "$BASH_BIN" "$SCRIPT" resolve
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  assert_contains "$stderr" "jq"
  run --separate-stderr env PATH="$bin" "$BASH_BIN" "$SCRIPT" prompt
  [ "$status" -eq 0 ]
  assert_starts_with "$output" "Run tests before committing?"
}

# ---------------------------------------------------------------------------
# prompt
# ---------------------------------------------------------------------------

@test "prompt is byte-identical to the story's prompt text" {
  local want
  want="$(printf '%s\n' \
    'Run tests before committing?' \
    '1. Test covering committed scope (scoped run)' \
    '2. Run j.test (full suite)' \
    '3. Skip tests' \
    'Enter selection (1-3), or blank to skip:')"
  "$BASH_BIN" "$SCRIPT" prompt > "$BATS_TEST_TMPDIR/got"
  printf '%s\n' "$want" > "$BATS_TEST_TMPDIR/want"
  cmp "$BATS_TEST_TMPDIR/got" "$BATS_TEST_TMPDIR/want"
}

@test "prompt with a default changes only the last line" {
  local d want
  for d in skip scoped full; do
    want="$(printf '%s\n' \
      'Run tests before committing?' \
      '1. Test covering committed scope (scoped run)' \
      '2. Run j.test (full suite)' \
      '3. Skip tests' \
      "Enter selection (1-3), 'default' or blank for the recorded default ($d):")"
    "$BASH_BIN" "$SCRIPT" prompt --default "$d" > "$BATS_TEST_TMPDIR/got"
    printf '%s\n' "$want" > "$BATS_TEST_TMPDIR/want"
    cmp "$BATS_TEST_TMPDIR/got" "$BATS_TEST_TMPDIR/want"
  done
}

@test "prompt rejects a default outside skip, scoped, full" {
  local d
  for d in bogus "" ask; do
    tgd prompt --default "$d"
    expect_usage_error
  done
}

# ---------------------------------------------------------------------------
# answer
# ---------------------------------------------------------------------------

@test "answer accepts 1, 2 and 3" {
  tgd answer 1
  expect_ok "scoped"
  tgd answer 2
  expect_ok "full"
  tgd answer 3
  expect_ok "skip"
}

@test "answer accepts the three words in any case" {
  local w
  for w in scoped Scoped SCOPED sCoPeD; do
    tgd answer "$w"
    expect_ok "scoped"
  done
  for w in full Full FULL; do
    tgd answer "$w"
    expect_ok "full"
  done
  for w in skip Skip SKIP; do
    tgd answer "$w"
    expect_ok "skip"
  done
}

@test "answer trims surrounding whitespace" {
  tgd answer "  2  "
  expect_ok "full"
  tgd answer $'\t3\n'
  expect_ok "skip"
  tgd answer " Scoped "
  expect_ok "scoped"
}

@test "answer: blank is skip without a default" {
  tgd answer ""
  expect_ok "skip"
  tgd answer "   "
  expect_ok "skip"
  tgd answer
  expect_ok "skip"
}

@test "answer: blank is the default when one is given" {
  local d
  for d in skip scoped full; do
    tgd answer "" --default "$d"
    expect_ok "$d"
    tgd answer "  " --default "$d"
    expect_ok "$d"
  done
}

@test "answer: the word default is the default when one is given, in any case" {
  local d
  for d in skip scoped full; do
    tgd answer default --default "$d"
    expect_ok "$d"
    tgd answer " DEFAULT " --default "$d"
    expect_ok "$d"
  done
}

@test "answer: an explicit answer wins over the default" {
  tgd answer 2 --default skip
  expect_ok "full"
  tgd answer scoped --default full
  expect_ok "scoped"
}

@test "answer: default with no recorded default is invalid" {
  tgd answer default
  expect_invalid_answer "'default'"
  assert_contains "$stderr" "no recorded default"
  assert_contains "$stderr" "1-3"
}

@test "answer rejects 4, 0, 1,2 and all with exit 1, empty stdout and a message naming the input" {
  local bad
  for bad in 4 0 "1,2" all; do
    tgd answer "$bad"
    expect_invalid_answer "'$bad'"
    assert_contains "$stderr" "1-3"
  done
}

@test "answer rejects other near-misses, with and without a default" {
  local bad
  for bad in 01 -1 1.5 "1 2" "1;2" yes no scopedd fulll "*" 10 "--default"; do
    tgd answer "$bad"
    expect_invalid_answer "'$bad'"
    tgd answer "$bad" --default full
    expect_invalid_answer "'$bad'"
    assert_contains "$stderr" "recorded default (full)"
  done
}

@test "answer never evaluates the raw text" {
  local marker="$BATS_TEST_TMPDIR/pwned"
  tgd answer "\$(touch $marker)"
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  tgd answer "\`touch $marker\`"
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  tgd answer "1; touch $marker"
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  [ ! -e "$marker" ]
}

@test "answer: control characters in the input never reach stderr raw" {
  tgd answer $'4\x01\x1b[31m'
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  assert_contains "$stderr" "invalid answer '4?"
  run grep -c $'\x1b' <<<"$stderr"
  [ "$output" = "0" ]
}

@test "answer rejects an invalid --default value" {
  tgd answer 1 --default bogus
  expect_usage_error
  tgd answer 1 --default ""
  expect_usage_error
}

# ---------------------------------------------------------------------------
# fallback-prompt and fallback-answer
# ---------------------------------------------------------------------------

@test "fallback-prompt prints the reason, then the two-option menu" {
  tgd fallback-prompt --reason "No suites map to the committed files."
  expect_ok "No suites map to the committed files.${NL}What would you like to do?${NL}1. Run j.test (full suite)${NL}2. Skip tests"
}

@test "fallback-prompt output is byte-exact" {
  "$BASH_BIN" "$SCRIPT" fallback-prompt --reason "map-scope.sh failed (exit 3)" > "$BATS_TEST_TMPDIR/got"
  printf '%s\n' 'map-scope.sh failed (exit 3)' 'What would you like to do?' '1. Run j.test (full suite)' '2. Skip tests' > "$BATS_TEST_TMPDIR/want"
  cmp "$BATS_TEST_TMPDIR/got" "$BATS_TEST_TMPDIR/want"
}

@test "fallback-prompt requires a non-empty --reason" {
  tgd fallback-prompt
  expect_usage_error
  tgd fallback-prompt --reason ""
  expect_usage_error
}

@test "fallback-answer: 1 and full are full, 2 and skip are skip, any case" {
  tgd fallback-answer 1
  expect_ok "full"
  tgd fallback-answer Full
  expect_ok "full"
  tgd fallback-answer 2
  expect_ok "skip"
  tgd fallback-answer SKIP
  expect_ok "skip"
  tgd fallback-answer " 1 "
  expect_ok "full"
}

@test "fallback-answer: a blank answer is skip" {
  tgd fallback-answer ""
  expect_ok "skip"
  tgd fallback-answer "  "
  expect_ok "skip"
  tgd fallback-answer
  expect_ok "skip"
}

@test "fallback-answer rejects everything else with exit 1" {
  local bad
  for bad in 3 0 "1,2" all scoped default; do
    tgd fallback-answer "$bad"
    expect_invalid_answer "'$bad'"
    assert_contains "$stderr" "1-2"
  done
}

# ---------------------------------------------------------------------------
# failure-prompt and failure-answer
# ---------------------------------------------------------------------------

@test "failure-prompt for failed suites" {
  tgd failure-prompt --failed "bats, pytest"
  expect_ok "Tests failed: bats, pytest${NL}What would you like to do?${NL}1. Fix first (nothing is committed)${NL}2. Commit anyway (the failure is logged; the next commit is gated again)${NL}3. Abort the commit (nothing is committed)"
}

@test "failure-prompt --kind failed is the same as the default" {
  local a b
  a="$("$BASH_BIN" "$SCRIPT" failure-prompt --failed x)"
  b="$("$BASH_BIN" "$SCRIPT" failure-prompt --failed x --kind failed)"
  [ "$a" = "$b" ]
}

@test "failure-prompt --kind error changes only the first line" {
  tgd failure-prompt --failed "npm test" --kind error
  expect_ok "Tests could not be run: npm test${NL}What would you like to do?${NL}1. Fix first (nothing is committed)${NL}2. Commit anyway (the failure is logged; the next commit is gated again)${NL}3. Abort the commit (nothing is committed)"
}

@test "failure-prompt output is byte-exact" {
  "$BASH_BIN" "$SCRIPT" failure-prompt --failed "a" > "$BATS_TEST_TMPDIR/got"
  printf '%s\n' 'Tests failed: a' 'What would you like to do?' '1. Fix first (nothing is committed)' \
    '2. Commit anyway (the failure is logged; the next commit is gated again)' '3. Abort the commit (nothing is committed)' > "$BATS_TEST_TMPDIR/want"
  cmp "$BATS_TEST_TMPDIR/got" "$BATS_TEST_TMPDIR/want"
}

@test "failure-prompt requires --failed and a known --kind" {
  tgd failure-prompt
  expect_usage_error
  tgd failure-prompt --failed ""
  expect_usage_error
  tgd failure-prompt --failed x --kind bogus
  expect_usage_error
}

@test "failure-answer accepts 1, 2, 3 and the words in any case" {
  tgd failure-answer 1
  expect_ok "fix"
  tgd failure-answer 2
  expect_ok "anyway"
  tgd failure-answer 3
  expect_ok "abort"
  tgd failure-answer FIX
  expect_ok "fix"
  tgd failure-answer Anyway
  expect_ok "anyway"
  tgd failure-answer aBoRt
  expect_ok "abort"
  tgd failure-answer "  2 "
  expect_ok "anyway"
}

@test "failure-answer rejects a blank answer (no default: an unanswered prompt never commits)" {
  tgd failure-answer ""
  expect_invalid_answer "''"
  assert_contains "$stderr" "no default"
  tgd failure-answer "   "
  expect_invalid_answer "'   '"
  tgd failure-answer
  [ "$status" -eq 1 ]
  [ -z "$output" ]
}

@test "failure-answer rejects everything else with exit 1" {
  local bad
  for bad in 4 0 "1,2" all default skip commit yes y; do
    tgd failure-answer "$bad"
    expect_invalid_answer "'$bad'"
    assert_contains "$stderr" "1-3"
  done
}

# ---------------------------------------------------------------------------
# directive: the whole proceed/halt table
# ---------------------------------------------------------------------------

# expect_gate <result> <choice-or-NONE> <GATE=...> <exit>
expect_gate() {
  if [ "$2" = "NONE" ]; then
    tgd directive "$1"
  else
    tgd directive "$1" --choice "$2"
  fi
  [ "$status" -eq "$4" ]
  [ "$output" = "$3" ]
  [ -z "$stderr" ]
}

@test "directive: passed and skipped PROCEED for any choice or none" {
  local r c
  for r in passed skipped; do
    for c in NONE fix anyway abort; do
      expect_gate "$r" "$c" "GATE=PROCEED" 0
    done
  done
}

@test "directive: unavailable PROCEEDs for any choice or none" {
  local c
  for c in NONE fix anyway abort; do
    expect_gate unavailable "$c" "GATE=PROCEED" 0
  done
}

@test "directive: failed and error PROCEED only with the anyway choice" {
  expect_gate failed anyway "GATE=PROCEED" 0
  expect_gate error anyway "GATE=PROCEED" 0
}

@test "directive: failed and error HALT for fix, abort and no choice" {
  local r c
  for r in failed error; do
    for c in NONE fix abort; do
      expect_gate "$r" "$c" "GATE=HALT" 1
    done
  done
}

@test "directive: interrupted HALTs for any choice or none" {
  local c
  for c in NONE fix anyway abort; do
    expect_gate interrupted "$c" "GATE=HALT" 1
  done
}

@test "directive: an unknown result exits 2 with nothing on stdout" {
  local r
  for r in pass ok PASSED Failed "" timeout unknown; do
    tgd directive "$r"
    expect_usage_error
  done
  tgd directive
  expect_usage_error
}

@test "directive: an unknown choice exits 2, even for a result that ignores the choice" {
  local c r
  for r in passed failed interrupted; do
    for c in yes no Anyway "" commit; do
      tgd directive "$r" --choice "$c"
      expect_usage_error
    done
  done
}

@test "directive: a caller that forgot to ask never proceeds on a failure" {
  tgd directive failed
  [ "$status" -eq 1 ]
  [ "$output" = "GATE=HALT" ]
  tgd directive error
  [ "$status" -eq 1 ]
  [ "$output" = "GATE=HALT" ]
}

# ---------------------------------------------------------------------------
# Round trips: the prompt-and-answer pairs agree
# ---------------------------------------------------------------------------

@test "every numbered option of every prompt is accepted by its answer parser" {
  local n
  for n in 1 2 3; do
    "$BASH_BIN" "$SCRIPT" answer "$n" > /dev/null
    "$BASH_BIN" "$SCRIPT" failure-answer "$n" > /dev/null
  done
  for n in 1 2; do
    "$BASH_BIN" "$SCRIPT" fallback-answer "$n" > /dev/null
  done
}

@test "an answer's output feeds directive's choice vocabulary" {
  local ans
  ans="$("$BASH_BIN" "$SCRIPT" failure-answer 2)"
  run "$BASH_BIN" "$SCRIPT" directive failed --choice "$ans"
  [ "$status" -eq 0 ]
  [ "$output" = "GATE=PROCEED" ]
  ans="$("$BASH_BIN" "$SCRIPT" failure-answer 3)"
  run "$BASH_BIN" "$SCRIPT" directive failed --choice "$ans"
  [ "$status" -eq 1 ]
  [ "$output" = "GATE=HALT" ]
}
