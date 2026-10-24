#!/usr/bin/env bats
#
# Coverage for skills/j-test/scripts/scope-policy.sh (E72_S06_T02).
#
# The script resolves the effective test-run mode (none, scoped or full) of a board scope (task, story, epic) from the
# flat keys test_run_task, test_run_story and test_run_epic of test-config.json. This suite pins the contract in its
# header: the default per scope, the honoured values, the silent absent cases, the warned invalid and unreadable cases,
# the --root and --config overrides, the usage errors and --help.
#
# How the cases are written
#   - The script runs as `bash <script>`, so the behaviour never depends on the file's mode.
#   - Every case uses a scratch consuming-project style root (project/configs/ under BATS_TEST_TMPDIR) reached through
#     JENGA_PROJECT_ROOT or --root. Nothing here reads or writes this repository's project/configs/.
#   - stdout and stderr are captured separately (`run --separate-stderr`). In every non-usage case stdout must be exactly
#     one token, asserted by expect_mode.
#   - Assertions use `[ ]` and tests/helpers/assertions.bash only; a line starting with `[[` is banned repo-wide by
#     tests/bats-assertion-convention.bats.

# shellcheck disable=SC2030,SC2031
# (bats runs each test in a subshell; the helpers read status/output/stderr set by `run`.)

bats_require_minimum_version 1.5.0

load helpers/assertions

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
SCRIPT="$REPO_ROOT/skills/j-test/scripts/scope-policy.sh"
BASH_BIN="$(command -v bash)"

setup() {
  ROOT="$BATS_TEST_TMPDIR/root"
  CFG_DIR="$ROOT/project/configs"
  mkdir -p "$CFG_DIR"
  printf '%s' '{}' > "$CFG_DIR/workflow.json"
  export JENGA_PROJECT_ROOT="$ROOT"
}

# sp <args...>: run the script, stdout in $output, stderr in $stderr.
sp() {
  run --separate-stderr "$BASH_BIN" "$SCRIPT" "$@"
}

# set_cfg <raw file content>: write the scratch test-config.json.
set_cfg() {
  printf '%s' "$1" > "$CFG_DIR/test-config.json"
}

# expect_mode <token>: exit 0, stdout is exactly that one token (no extra line, no spaces).
expect_mode() {
  [ "$status" -eq 0 ]
  [ "$output" = "$1" ]
  case "$output" in
    *[[:space:]]*) return 1 ;;
  esac
}

# expect_silent_mode <token>: expect_mode plus nothing at all on stderr.
expect_silent_mode() {
  expect_mode "$1"
  [ -z "$stderr" ]
}

# expect_warned_mode <token> <key> <value-text>: expect_mode, and exactly one stderr line naming the key, the offending
# value and the default used.
expect_warned_mode() {
  expect_mode "$1"
  [ -n "$stderr" ]
  case "$stderr" in
    *$'\n'*) return 1 ;;
  esac
  assert_contains "$stderr" "$2"
  assert_contains "$stderr" "$3"
  assert_contains "$stderr" "using the default \"$1\""
}

# expect_usage_error: exit 2, empty stdout, usage on stderr.
expect_usage_error() {
  [ "$status" -eq 2 ]
  [ -z "$output" ]
  assert_contains "$stderr" "Usage: scope-policy.sh get <task|story|epic>"
}

# default_for <scope>: the documented default.
default_for() {
  case "$1" in
    task) printf 'none' ;;
    story) printf 'scoped' ;;
    epic) printf 'full' ;;
  esac
}

# ---------------------------------------------------------------------------
# File properties and the header contract
# ---------------------------------------------------------------------------

@test "script exists, is bash, and passes bash -n" {
  [ -f "$SCRIPT" ]
  [ "$(head -n 1 "$SCRIPT")" = "#!/usr/bin/env bash" ]
  "$BASH_BIN" -n "$SCRIPT"
}

@test "script is executable like its j-test siblings" {
  [ -x "$SCRIPT" ]
  [ -x "$REPO_ROOT/skills/j-test/scripts/map-scope.sh" ]
}

@test "header documents usage, defaults, absent versus invalid handling and the exit codes" {
  header="$(sed -n '1,/^set -euo pipefail/p' "$SCRIPT")"
  assert_contains "$header" "Usage:"
  assert_contains "$header" "EXIT CODES"
  assert_contains "$header" "test_run_task"
  assert_contains "$header" "test_run_story"
  assert_contains "$header" "test_run_epic"
  assert_contains "$header" "ABSENT versus INVALID"
  assert_contains "$header" "usage error"
  assert_contains "$header" "--root"
  assert_contains "$header" "--config"
}

@test "script uses set -euo pipefail" {
  grep -q '^set -euo pipefail$' "$SCRIPT"
}

@test "script passes shellcheck" {
  if ! command -v shellcheck >/dev/null 2>&1; then
    skip "shellcheck is not installed"
  fi
  run shellcheck -S warning "$SCRIPT"
  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# --help
# ---------------------------------------------------------------------------

@test "--help exits 0 on stdout and mentions the exit codes" {
  sp --help
  [ "$status" -eq 0 ]
  [ -z "$stderr" ]
  assert_contains "$output" "Usage: scope-policy.sh get <task|story|epic>"
  assert_contains "$output" "Exit: 0"
  assert_contains "$output" "2 usage error"
}

@test "-h is the same as --help" {
  sp -h
  [ "$status" -eq 0 ]
  assert_contains "$output" "Exit: 0"
}

# ---------------------------------------------------------------------------
# Defaults: absent file, empty file, config lacking the keys
# ---------------------------------------------------------------------------

@test "each scope prints its default when there is no config file" {
  for scope in task story epic; do
    sp get "$scope"
    expect_silent_mode "$(default_for "$scope")"
  done
}

@test "each scope prints its default through --root with no config file" {
  for scope in task story epic; do
    sp get "$scope" --root "$ROOT"
    expect_silent_mode "$(default_for "$scope")"
  done
}

@test "each scope prints its default when no configs directory exists at all" {
  empty="$BATS_TEST_TMPDIR/bare"
  mkdir -p "$empty"
  for scope in task story epic; do
    sp get "$scope" --root "$empty"
    expect_silent_mode "$(default_for "$scope")"
  done
}

@test "the defaults are none, scoped and full for task, story and epic" {
  sp get task
  expect_silent_mode none
  sp get story
  expect_silent_mode scoped
  sp get epic
  expect_silent_mode full
}

@test "an empty config file prints the default silently" {
  set_cfg ''
  for scope in task story epic; do
    sp get "$scope"
    expect_silent_mode "$(default_for "$scope")"
  done
}

@test "a whitespace-only config file prints the default silently" {
  set_cfg $'  \n\t\n'
  for scope in task story epic; do
    sp get "$scope"
    expect_silent_mode "$(default_for "$scope")"
  done
}

@test "an empty JSON object prints the default silently" {
  set_cfg '{}'
  for scope in task story epic; do
    sp get "$scope"
    expect_silent_mode "$(default_for "$scope")"
  done
}

@test "a config lacking the three keys (an older config) prints the default silently" {
  set_cfg '{"tools":[{"tool_name":"bats","type":"unit"}],"commit_prompt_default":"full"}'
  for scope in task story epic; do
    sp get "$scope"
    expect_silent_mode "$(default_for "$scope")"
  done
}

@test "a config with only one of the keys leaves the other scopes at their defaults" {
  set_cfg '{"test_run_story":"none"}'
  sp get task
  expect_silent_mode none
  sp get story
  expect_silent_mode none
  sp get epic
  expect_silent_mode full
}

# ---------------------------------------------------------------------------
# Valid values are honoured for every scope (the 9 combinations)
# ---------------------------------------------------------------------------

@test "each of none, scoped and full is honoured for each scope" {
  for scope in task story epic; do
    for mode in none scoped full; do
      set_cfg "{\"test_run_${scope}\":\"${mode}\"}"
      sp get "$scope"
      expect_silent_mode "$mode"
    done
  done
}

@test "a configured value for one scope does not leak into another" {
  set_cfg '{"test_run_task":"full","test_run_story":"none","test_run_epic":"scoped"}'
  sp get task
  expect_silent_mode full
  sp get story
  expect_silent_mode none
  sp get epic
  expect_silent_mode scoped
}

@test "the shipped defaults written out explicitly resolve to themselves" {
  set_cfg '{"test_run_task":"none","test_run_story":"scoped","test_run_epic":"full"}'
  sp get task
  expect_silent_mode none
  sp get story
  expect_silent_mode scoped
  sp get epic
  expect_silent_mode full
}

# ---------------------------------------------------------------------------
# Present but invalid: default, one stderr warning, exit 0, clean stdout
# ---------------------------------------------------------------------------

@test "a wrong string falls back to the default with a warning naming the key and the value" {
  set_cfg '{"test_run_story":"banana"}'
  sp get story
  expect_warned_mode scoped test_run_story '"banana"'
}

@test "a wrong string is rejected for every scope and falls back to that scope's default" {
  for scope in task story epic; do
    set_cfg "{\"test_run_${scope}\":\"banana\"}"
    sp get "$scope"
    expect_warned_mode "$(default_for "$scope")" "test_run_${scope}" '"banana"'
  done
}

@test "a number falls back to the default with a warning" {
  set_cfg '{"test_run_epic":3}'
  sp get epic
  expect_warned_mode full test_run_epic '3'
}

@test "null falls back to the default with a warning" {
  set_cfg '{"test_run_task":null}'
  sp get task
  expect_warned_mode none test_run_task 'null'
}

@test "the empty string falls back to the default with a warning" {
  set_cfg '{"test_run_story":""}'
  sp get story
  expect_warned_mode scoped test_run_story '""'
}

@test "a boolean, an object and an array fall back to the default with a warning" {
  set_cfg '{"test_run_story":true}'
  sp get story
  expect_warned_mode scoped test_run_story 'true'
  set_cfg '{"test_run_story":{"mode":"full"}}'
  sp get story
  expect_warned_mode scoped test_run_story '{"mode":"full"}'
  set_cfg '{"test_run_story":["full"]}'
  sp get story
  expect_warned_mode scoped test_run_story '["full"]'
}

@test "values are matched exactly: wrong case and padding are invalid" {
  set_cfg '{"test_run_epic":"Full"}'
  sp get epic
  expect_warned_mode full test_run_epic '"Full"'
  set_cfg '{"test_run_task":" none"}'
  sp get task
  expect_warned_mode none test_run_task '" none"'
}

@test "an invalid value for one scope does not disturb another scope's valid value" {
  set_cfg '{"test_run_task":"banana","test_run_story":"full"}'
  sp get story
  expect_silent_mode full
}

@test "a multi-line looking invalid value still yields a single warning line" {
  set_cfg '{"test_run_story":"a\nb"}'
  sp get story
  expect_warned_mode scoped test_run_story 'a\nb'
}

# ---------------------------------------------------------------------------
# Unreadable or malformed: treated like invalid, the gate must still gate
# ---------------------------------------------------------------------------

@test "malformed JSON falls back to the default with a warning naming the key" {
  set_cfg '{"test_run_story": "full"'
  sp get story
  expect_mode scoped
  [ -n "$stderr" ]
  case "$stderr" in
    *$'\n'*) return 1 ;;
  esac
  assert_contains "$stderr" "test_run_story"
  assert_contains "$stderr" "using the default \"scoped\""
}

@test "malformed JSON falls back for every scope with its own default" {
  set_cfg 'not json at all'
  for scope in task story epic; do
    sp get "$scope"
    expect_mode "$(default_for "$scope")"
    assert_contains "$stderr" "test_run_${scope}"
  done
}

@test "a JSON value that is not an object falls back with a warning" {
  set_cfg '["full"]'
  sp get epic
  expect_mode full
  assert_contains "$stderr" "test_run_epic"
  set_cfg '"full"'
  sp get task
  expect_mode none
  assert_contains "$stderr" "test_run_task"
}

@test "a config path that is a directory falls back with a warning" {
  mkdir -p "$CFG_DIR/test-config.json"
  sp get story
  expect_mode scoped
  assert_contains "$stderr" "test_run_story"
}

@test "an unreadable config file falls back with a warning" {
  if [ "$(id -u)" -eq 0 ]; then
    skip "root can read a mode 000 file"
  fi
  set_cfg '{"test_run_story":"full"}'
  chmod 000 "$CFG_DIR/test-config.json"
  sp get story
  chmod 600 "$CFG_DIR/test-config.json"
  expect_mode scoped
  assert_contains "$stderr" "test_run_story"
}

# ---------------------------------------------------------------------------
# --config and --root
# ---------------------------------------------------------------------------

@test "--config reads that file instead of the configs directory" {
  set_cfg '{"test_run_story":"none"}'
  printf '%s' '{"test_run_story":"full"}' > "$BATS_TEST_TMPDIR/other.json"
  sp get story --config "$BATS_TEST_TMPDIR/other.json"
  expect_silent_mode full
}

@test "--config wins over --root" {
  other="$BATS_TEST_TMPDIR/other-root/project/configs"
  mkdir -p "$other"
  printf '%s' '{}' > "$other/workflow.json"
  printf '%s' '{"test_run_epic":"none"}' > "$other/test-config.json"
  printf '%s' '{"test_run_epic":"scoped"}' > "$BATS_TEST_TMPDIR/explicit.json"
  sp get epic --root "$BATS_TEST_TMPDIR/other-root" --config "$BATS_TEST_TMPDIR/explicit.json"
  expect_silent_mode scoped
}

@test "--config naming a missing file prints the default silently" {
  sp get epic --config "$BATS_TEST_TMPDIR/nope.json"
  expect_silent_mode full
}

@test "--config with an invalid value warns and falls back" {
  printf '%s' '{"test_run_task":"banana"}' > "$BATS_TEST_TMPDIR/bad.json"
  sp get task --config "$BATS_TEST_TMPDIR/bad.json"
  expect_warned_mode none test_run_task '"banana"'
}

@test "--root selects the project whose configs directory is read" {
  other="$BATS_TEST_TMPDIR/other-root/project/configs"
  mkdir -p "$other"
  printf '%s' '{}' > "$other/workflow.json"
  printf '%s' '{"test_run_story":"none"}' > "$other/test-config.json"
  set_cfg '{"test_run_story":"full"}'
  sp get story --root "$BATS_TEST_TMPDIR/other-root"
  expect_silent_mode none
  sp get story --root "$ROOT"
  expect_silent_mode full
}

@test "options may come before the subcommand" {
  set_cfg '{"test_run_story":"none"}'
  sp --root "$ROOT" get story
  expect_silent_mode none
}

@test "the script never writes into the configs directory" {
  set_cfg '{"test_run_story":"banana"}'
  before="$(cksum < "$CFG_DIR/test-config.json")"
  sp get story
  [ "$(cksum < "$CFG_DIR/test-config.json")" = "$before" ]
  [ "$(ls "$CFG_DIR" | wc -l | tr -d ' ')" = "2" ]
}

# ---------------------------------------------------------------------------
# Usage errors: exit 2, nothing on stdout, usage on stderr
# ---------------------------------------------------------------------------

@test "no arguments is a usage error" {
  sp
  expect_usage_error
  assert_contains "$stderr" "missing subcommand"
}

@test "an unknown subcommand is a usage error" {
  sp frobnicate task
  expect_usage_error
  assert_contains "$stderr" "unknown subcommand: frobnicate"
}

@test "get without a scope is a usage error" {
  sp get
  expect_usage_error
  assert_contains "$stderr" "missing scope"
}

@test "an unknown scope is a usage error" {
  sp get sprint
  expect_usage_error
  assert_contains "$stderr" "unknown scope: sprint"
}

@test "a scope is case sensitive" {
  sp get Task
  expect_usage_error
}

@test "an extra argument is a usage error" {
  sp get task story
  expect_usage_error
  assert_contains "$stderr" "unexpected argument: story"
}

@test "an unknown option is a usage error" {
  sp get task --frobnicate
  expect_usage_error
  assert_contains "$stderr" "unknown option: --frobnicate"
}

@test "--root without a value is a usage error" {
  sp get task --root
  expect_usage_error
  assert_contains "$stderr" "--root needs"
}

@test "--config without a value is a usage error" {
  sp get task --config
  expect_usage_error
  assert_contains "$stderr" "--config needs"
}

@test "--root naming a missing directory is a usage error" {
  sp get task --root "$BATS_TEST_TMPDIR/does-not-exist"
  expect_usage_error
  assert_contains "$stderr" "--root is not a directory"
}

@test "a usage error never prints a mode token" {
  set_cfg '{"test_run_task":"full"}'
  sp get nonsense
  [ "$status" -eq 2 ]
  [ -z "$output" ]
}
