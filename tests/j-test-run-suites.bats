#!/usr/bin/env bats
#
# Coverage for skills/j-test/scripts/run-suites.sh (E72_S02_T04).
#
# The script runs the suites a user selected from a build-catalog.sh catalog, in order, from a root directory, and
# prints the fixed `Test Results` summary. This suite checks that contract: order, exactly-once, continue-on-failure,
# the summary layout (compared as exact text), the exit codes (0 / 1 / 2 / 130), validation-before-execution, and the
# interrupt path.
#
# How the cases are written
#   - Catalogs are hand-written JSON under tests/fixtures/j-test/run/ (the build-catalog.sh contract, written from its
#     header) or built inline under BATS_TEST_TMPDIR. Nothing here calls build-catalog.sh or discover-tests.sh against
#     the repo, and no case runs npm, bats on the repo's suites, or any other real project suite: every suite command
#     is a trivial shell snippet (echo, true, exit N, sleep).
#   - A fixture command records that it ran by appending a line to "$RUN_MARK" (exported in setup() to a file under
#     BATS_TEST_TMPDIR). "Nothing executed" is therefore proved by that file not existing, not by trusting output.
#   - The interrupt cases start the script from a small launcher under `set -m`. A non-interactive shell starts an
#     `&` job with SIGINT ignored, and a script cannot trap a signal it inherited as ignored, so without job control
#     the SIGINT could never be delivered. The launcher bounds every wait, so a regression cannot hang the suite.
#   - Everything scratch lives under BATS_TEST_TMPDIR. The fixtures themselves are only read.

# shellcheck disable=SC2016,SC2030,SC2031
# SC2016: the JSON fixtures and the interrupt launcher are single-quoted on purpose ($RUN_MARK and $(...) must reach the
# suite command or the child shell unexpanded). SC2030/SC2031: bats runs every @test in its own subshell, so reading
# $status after `run` is correct.

bats_require_minimum_version 1.5.0

load helpers/assertions

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
RUN="$REPO_ROOT/skills/j-test/scripts/run-suites.sh"
FIX="$REPO_ROOT/tests/fixtures/j-test/run"
BASH_BIN="$(command -v bash)"

setup() {
  RUN_ROOT="$BATS_TEST_TMPDIR/root"
  mkdir -p "$RUN_ROOT"
  RUN_MARK="$BATS_TEST_TMPDIR/mark"
  export RUN_MARK
}

# --- helpers -------------------------------------------------------------------------------------------------------

# suites <args...>: run the script; sets $status, $output (stdout) and $stderr.
suites() {
  run --separate-stderr "$BASH_BIN" "$RUN" "$@"
}

# write_catalog <file> <json>: write a catalog fixture inline.
write_catalog() {
  printf '%s\n' "$2" > "$1"
}

# refuse <expected stderr substring> <args...>: the run must be refused with exit 2, with the cause on stderr, nothing
# on stdout, and no suite executed (RUN_MARK, which every fixture command writes, must not exist).
refuse() {
  local needle="$1"
  shift
  suites "$@"
  [ "$status" -eq 2 ]
  [ -z "$output" ]
  assert_contains "$stderr" "$needle"
  [ ! -e "$RUN_MARK" ]
}

# marks: the lines the fixture commands recorded, joined with commas.
marks() {
  paste -sd, "$RUN_MARK"
}

# --- shape ---------------------------------------------------------------------------------------------------------

@test "the script exists, is executable, is mode 100755 in git, and is shellcheck clean" {
  [ -f "$RUN" ]
  [ -x "$RUN" ]
  if git -C "$REPO_ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    local mode
    mode="$(git -C "$REPO_ROOT" ls-files -s -- skills/j-test/scripts/run-suites.sh | cut -d' ' -f1)"
    [ "$mode" = "100755" ]
  fi
  if command -v shellcheck >/dev/null 2>&1; then
    run shellcheck -S warning "$RUN"
    [ "$status" -eq 0 ]
  fi
}

@test "--help prints usage and exits 0 without running anything" {
  suites --help
  [ "$status" -eq 0 ]
  assert_starts_with "$output" "Usage: run-suites.sh --catalog"
  assert_output_contains "--root"
  [ ! -e "$RUN_MARK" ]
}

@test "the script never calls build-catalog.sh or discover-tests.sh" {
  # Statically: no line has an invocation shape for either script (a command word, resolve_helper, or a sibling-path
  # lookup followed by the script name) on a non-comment line. Prose that merely names them, such as the --help text, is not a call.
  grep -v '^[[:space:]]*#' "$RUN" > "$BATS_TEST_TMPDIR/code-only.sh"
  run grep -E '(bash|exec|source|resolve_helper|SCRIPT_DIR/|\.)[[:space:]"/$A-Za-z_{}]*(build-catalog|discover-tests)' "$BATS_TEST_TMPDIR/code-only.sh"
  [ "$status" -eq 1 ]
  # Dynamically: stubs of both, placed where a sibling lookup would find them, are never run.
  local copy="$BATS_TEST_TMPDIR/copy/skills/j-test/scripts"
  mkdir -p "$copy"
  cp "$RUN" "$copy/run-suites.sh"
  local name
  for name in build-catalog.sh discover-tests.sh; do
    printf '#!/usr/bin/env bash\ntouch "%s.%s"\n' "$BATS_TEST_TMPDIR/stub-ran" "$name" > "$copy/$name"
  done
  run --separate-stderr "$BASH_BIN" "$copy/run-suites.sh" --catalog "$FIX/all-pass.json" --root "$RUN_ROOT" 1
  [ "$status" -eq 0 ]
  [ ! -e "$BATS_TEST_TMPDIR/stub-ran.build-catalog.sh" ]
  [ ! -e "$BATS_TEST_TMPDIR/stub-ran.discover-tests.sh" ]
}

@test "the script has no hardcoded project/ path" {
  run grep -n 'project/' "$RUN"
  [ "$status" -eq 1 ]
}

# --- execution -----------------------------------------------------------------------------------------------------

@test "all suites pass: exit 0 and the summary is exact" {
  suites --catalog "$FIX/all-pass.json" --root "$RUN_ROOT" 1 2 3
  [ "$status" -eq 0 ]
  [ -z "$stderr" ]
  local expected
  expected="$(printf '%s\n' \
    '==> [1/3] alpha (unit)' \
    '==> [2/3] beta (integration)' \
    '==> [3/3] gamma (sast)' \
    'Test Results' \
    '============' \
    '✓ alpha (unit)' \
    '✓ beta (integration)' \
    '✓ gamma (sast)' \
    '' \
    '3 passed, 0 failed. Exit code: 0')"
  [ "$output" = "$expected" ]
  [ "$(marks)" = "alpha,beta,gamma" ]
}

@test "one failing suite among passers: the run continues, exit 1, summary and counts exact" {
  suites --catalog "$FIX/one-fail.json" --root "$RUN_ROOT" 1 2 3
  [ "$status" -eq 1 ]
  local expected
  expected="$(printf '%s\n' \
    '==> [1/3] first (unit)' \
    '==> [2/3] second (sast)' \
    '==> [3/3] third (unit)' \
    'Test Results' \
    '============' \
    '✓ first (unit)' \
    '✗ second (sast)' \
    '✓ third (unit)' \
    '' \
    '2 passed, 1 failed. Exit code: 1')"
  [ "$output" = "$expected" ]
  # the suite after the failure really ran
  [ "$(marks)" = "first,second,third" ]
}

@test "a failure in the first and the last position both leave every other suite run and exit 1" {
  suites --catalog "$FIX/one-fail.json" --root "$RUN_ROOT" 2 1 3
  [ "$status" -eq 1 ]
  assert_output_contains "✗ second (sast)"
  assert_output_contains "2 passed, 1 failed. Exit code: 1"
  [ "$(marks)" = "second,first,third" ]
}

@test "every suite failing exits 1 with 0 passed" {
  suites --catalog "$FIX/one-fail.json" --root "$RUN_ROOT" 2
  [ "$status" -eq 1 ]
  assert_output_contains "0 passed, 1 failed. Exit code: 1"
}

@test "exit 127 (command not found) counts as failed and does not stop the run" {
  suites --catalog "$FIX/command-not-found.json" --root "$RUN_ROOT" 1 2
  [ "$status" -eq 1 ]
  assert_output_contains "✗ missing tool (unit)"
  assert_output_contains "✓ after (unit)"
  assert_output_contains "1 passed, 1 failed. Exit code: 1"
  assert_contains "$stderr" "definitely-not-a-real-command-e72s02t04"
  [ "$(marks)" = "after" ]
}

@test "run order equals argument order" {
  suites --catalog "$FIX/all-pass.json" --root "$RUN_ROOT" 3 1 2
  [ "$status" -eq 0 ]
  [ "$(marks)" = "gamma,alpha,beta" ]
  local expected
  expected="$(printf '%s\n' \
    '==> [1/3] gamma (sast)' \
    '==> [2/3] alpha (unit)' \
    '==> [3/3] beta (integration)' \
    'Test Results' \
    '============' \
    '✓ gamma (sast)' \
    '✓ alpha (unit)' \
    '✓ beta (integration)' \
    '' \
    '3 passed, 0 failed. Exit code: 0')"
  [ "$output" = "$expected" ]
}

@test "a selection that skips a middle suite does not run, list or count it" {
  suites --catalog "$FIX/all-pass.json" --root "$RUN_ROOT" 1 3
  [ "$status" -eq 0 ]
  [ "$(marks)" = "alpha,gamma" ]
  assert_output_not_contains "beta"
  assert_output_contains "2 passed, 0 failed. Exit code: 0"
  assert_output_contains "==> [2/2] gamma (sast)"
}

@test "a single selected suite runs once and only that one" {
  suites --catalog "$FIX/all-pass.json" --root "$RUN_ROOT" 2
  [ "$status" -eq 0 ]
  [ "$(marks)" = "beta" ]
  assert_output_contains "1 passed, 0 failed. Exit code: 0"
}

@test "flags and numbers may be interleaved, and -- ends the options" {
  suites 2 --root "$RUN_ROOT" --catalog "$FIX/all-pass.json" -- 1
  [ "$status" -eq 0 ]
  [ "$(marks)" = "beta,alpha" ]
}

@test "a suite's stdout and stderr pass through live, between its header and the summary" {
  write_catalog "$BATS_TEST_TMPDIR/talk.json" \
    '{"runnable":[{"n":1,"name":"talker","type":"unit","command":"echo out-line; echo err-line >&2"}]}'
  suites --catalog "$BATS_TEST_TMPDIR/talk.json" --root "$RUN_ROOT" 1
  [ "$status" -eq 0 ]
  local expected
  expected="$(printf '%s\n' \
    '==> [1/1] talker (unit)' \
    'out-line' \
    'Test Results' \
    '============' \
    '✓ talker (unit)' \
    '' \
    '1 passed, 0 failed. Exit code: 0')"
  [ "$output" = "$expected" ]
  [ "$stderr" = "err-line" ]
}

@test "a command using a glob and a pipe runs correctly (it is one shell string, not word-split)" {
  printf 'abc\n' > "$RUN_ROOT/a.dat"
  printf 'def\n' > "$RUN_ROOT/b.dat"
  suites --catalog "$FIX/shell-forms.json" --root "$RUN_ROOT" 1
  [ "$status" -eq 0 ]
  [ "$(cat "$RUN_MARK")" = "$(printf 'ABC\nDEF')" ]
}

@test "stdin of a suite is /dev/null, even when the script itself is given input" {
  run --separate-stderr "$BASH_BIN" "$RUN" --catalog "$FIX/shell-forms.json" --root "$RUN_ROOT" 2 <<< "this must not reach the suite"
  [ "$status" -eq 0 ]
  [ "$(cat "$RUN_MARK")" = "stdin-bytes=0" ]
}

@test "--root sets the working directory the commands run in" {
  mkdir -p "$BATS_TEST_TMPDIR/elsewhere"
  suites --catalog "$FIX/shell-forms.json" --root "$RUN_ROOT" 3
  [ "$status" -eq 0 ]
  [ "$(cat "$RUN_MARK")" = "$(cd "$RUN_ROOT" && pwd -P)" ]
}

@test "a relative --root is honoured" {
  mkdir -p "$BATS_TEST_TMPDIR/rel/inner"
  cd "$BATS_TEST_TMPDIR/rel"
  suites --catalog "$FIX/shell-forms.json" --root inner 3
  [ "$status" -eq 0 ]
  [ "$(cat "$RUN_MARK")" = "$(cd inner && pwd -P)" ]
}

@test "without --root the commands run in the root scripts/resolve-root.sh resolves" {
  local anchor="$BATS_TEST_TMPDIR/anchor"
  mkdir -p "$anchor/project/configs"
  printf '%s' '{}' > "$anchor/project/configs/workflow.json"
  run --separate-stderr env JENGA_PROJECT_ROOT="$anchor" "$BASH_BIN" "$RUN" --catalog "$FIX/shell-forms.json" 3
  [ "$status" -eq 0 ]
  [ "$(cat "$RUN_MARK")" = "$(cd "$anchor" && pwd -P)" ]
}

@test "the caller's cwd is left alone: the suite runs in --root, not where the script was started" {
  mkdir -p "$BATS_TEST_TMPDIR/start"
  cd "$BATS_TEST_TMPDIR/start"
  suites --catalog "$FIX/shell-forms.json" --root "$RUN_ROOT" 3
  [ "$status" -eq 0 ]
  [ "$(cat "$RUN_MARK")" != "$(pwd -P)" ]
}

@test "a catalog with extra fields and not_runnable entries: extras ignored, not_runnable never run, listed or counted" {
  suites --catalog "$FIX/extras.json" --root "$RUN_ROOT" 2 1
  [ "$status" -eq 0 ]
  [ "$(marks)" = "semgrep,one" ]
  [ ! -e "$RUN_MARK.not-runnable" ]
  local expected
  expected="$(printf '%s\n' \
    '==> [1/2] semgrep (sast)' \
    '==> [2/2] one (unit)' \
    'Test Results' \
    '============' \
    '✓ semgrep (sast)' \
    '✓ one (unit)' \
    '' \
    '2 passed, 0 failed. Exit code: 0')"
  [ "$output" = "$expected" ]
  assert_output_not_contains "cfg"
}

@test "the suite command is never evaluated by the script: shell metacharacters in a name are printed, not run" {
  write_catalog "$BATS_TEST_TMPDIR/meta.json" \
    '{"runnable":[{"n":1,"name":"a $(touch evil) `touch evil2` b","type":"unit","command":"true"}]}'
  suites --catalog "$BATS_TEST_TMPDIR/meta.json" --root "$RUN_ROOT" 1
  [ "$status" -eq 0 ]
  assert_output_contains '✓ a $(touch evil) `touch evil2` b (unit)'
  [ ! -e "$RUN_ROOT/evil" ]
  [ ! -e "$RUN_ROOT/evil2" ]
}

@test "the script writes nothing to disk" {
  local cwd="$BATS_TEST_TMPDIR/cwd" tmp="$BATS_TEST_TMPDIR/tmpdir"
  mkdir -p "$cwd" "$tmp"
  write_catalog "$BATS_TEST_TMPDIR/quiet.json" '{"runnable":[{"n":1,"name":"t","type":"unit","command":"true"}]}'
  cd "$cwd"
  run --separate-stderr env TMPDIR="$tmp" "$BASH_BIN" "$RUN" --catalog "$BATS_TEST_TMPDIR/quiet.json" --root "$RUN_ROOT" 1
  [ "$status" -eq 0 ]
  [ -z "$(find "$cwd" "$tmp" "$RUN_ROOT" -mindepth 1)" ]
}

@test "runs under the system /bin/bash 3.2 on macOS" {
  [ -x /bin/bash ] || skip "no /bin/bash"
  run --separate-stderr /bin/bash "$RUN" --catalog "$FIX/one-fail.json" --root "$RUN_ROOT" 1 2 3
  [ "$status" -eq 1 ]
  assert_output_contains "2 passed, 1 failed. Exit code: 1"
}

# --- validation: exit 2 before anything runs --------------------------------------------------------------------------

@test "a number outside the runnable range is refused, naming the valid range, and nothing runs (even a valid earlier number)" {
  refuse "valid: 1 through 3" --catalog "$FIX/all-pass.json" --root "$RUN_ROOT" 1 4
}

@test "suite 0 is refused and nothing runs" {
  refuse "not a suite number" --catalog "$FIX/all-pass.json" --root "$RUN_ROOT" 1 0
}

@test "a non-numeric selection is refused and nothing runs" {
  refuse "not a suite number: 'abc'" --catalog "$FIX/all-pass.json" --root "$RUN_ROOT" 1 abc
}

@test "a decimal, a leading-zero number and an empty argument are refused and nothing runs" {
  refuse "not a suite number: '1.5'" --catalog "$FIX/all-pass.json" --root "$RUN_ROOT" 1.5
  refuse "not a suite number: '01'" --catalog "$FIX/all-pass.json" --root "$RUN_ROOT" 1 01
  refuse "not a suite number: ''" --catalog "$FIX/all-pass.json" --root "$RUN_ROOT" 1 ""
}

@test "a repeated number is refused and nothing runs" {
  refuse "suite 1 was given more than once" --catalog "$FIX/all-pass.json" --root "$RUN_ROOT" 1 2 1
}

@test "no numbers is refused and nothing runs" {
  refuse "no suite numbers" --catalog "$FIX/all-pass.json" --root "$RUN_ROOT"
}

@test "a number that is a not_runnable entry (not in runnable) is refused" {
  refuse "valid: 1 through 2" --catalog "$FIX/extras.json" --root "$RUN_ROOT" 3
}

@test "an empty runnable list refuses every number" {
  refuse "no runnable suites" --catalog "$FIX/empty.json" --root "$RUN_ROOT" 1
}

@test "a runnable entry with an empty command is not runnable and is refused" {
  write_catalog "$BATS_TEST_TMPDIR/emptycmd.json" \
    '{"runnable":[{"n":1,"name":"ok","type":"unit","command":"echo ok >> \"$RUN_MARK\""},{"n":2,"name":"hollow","type":"unit","command":""}]}'
  refuse "valid: 1 through 2" --catalog "$BATS_TEST_TMPDIR/emptycmd.json" --root "$RUN_ROOT" 1 2
}

@test "an invalid-JSON catalog is refused and nothing runs" {
  printf '%s' '{"runnable": [ {"n":1, ' > "$BATS_TEST_TMPDIR/bad.json"
  refuse "not valid JSON" --catalog "$BATS_TEST_TMPDIR/bad.json" --root "$RUN_ROOT" 1
}

@test "an empty catalog file and a two-document file are refused" {
  : > "$BATS_TEST_TMPDIR/zero.json"
  refuse "not valid JSON" --catalog "$BATS_TEST_TMPDIR/zero.json" --root "$RUN_ROOT" 1
  printf '%s\n%s\n' '{"runnable":[]}' '{"runnable":[]}' > "$BATS_TEST_TMPDIR/two.json"
  refuse "not valid JSON" --catalog "$BATS_TEST_TMPDIR/two.json" --root "$RUN_ROOT" 1
}

@test "valid JSON that is not a catalog (no runnable array) is refused" {
  write_catalog "$BATS_TEST_TMPDIR/notcat.json" '{"suites":[]}'
  refuse "runnable array" --catalog "$BATS_TEST_TMPDIR/notcat.json" --root "$RUN_ROOT" 1
  write_catalog "$BATS_TEST_TMPDIR/arr.json" '[1,2,3]'
  refuse "runnable array" --catalog "$BATS_TEST_TMPDIR/arr.json" --root "$RUN_ROOT" 1
}

@test "an unreadable (missing) catalog is refused and nothing runs" {
  refuse "not a readable file" --catalog "$BATS_TEST_TMPDIR/no-such.json" --root "$RUN_ROOT" 1
}

@test "a missing --catalog, a --catalog without a value and an unknown flag are usage errors" {
  refuse "--catalog" --root "$RUN_ROOT" 1
  refuse "--catalog needs" 1 --catalog
  refuse "unknown option: --bogus" --catalog "$FIX/all-pass.json" --bogus 1
  refuse "--root needs" --catalog "$FIX/all-pass.json" 1 --root
}

@test "a --root that is not a directory is refused and nothing runs" {
  refuse "root is not a directory" --catalog "$FIX/all-pass.json" --root "$BATS_TEST_TMPDIR/nope" 1
}

@test "jq missing is exit 2 (never 1, which means a suite failed), names jq, and nothing runs" {
  local bin="$BATS_TEST_TMPDIR/nojq-bin" tool
  mkdir -p "$bin"
  for tool in bash cat dirname basename pwd env git sed awk grep sort head tail tr cut date uname readlink realpath ls mkdir; do
    if command -v "$tool" >/dev/null 2>&1; then
      ln -s "$(command -v "$tool")" "$bin/$tool"
    fi
  done
  run --separate-stderr env PATH="$bin" "$BASH_BIN" "$RUN" --catalog "$FIX/all-pass.json" --root "$RUN_ROOT" 1
  [ "$status" -eq 2 ]
  assert_contains "$stderr" "jq is required"
  [ ! -e "$RUN_MARK" ]
}

# --- interrupt -------------------------------------------------------------------------------------------------------

# interrupt_run <signal>: start the interrupt fixture (suites 1-4; suite 2 sleeps), wait until suite 2 is running, send
# the signal, and wait for the script to exit. Every wait is bounded. The script's exit status becomes $status, its
# stdout/stderr land in $OUT/$ERR.
interrupt_run() {
  OUT="$BATS_TEST_TMPDIR/int.out"
  ERR="$BATS_TEST_TMPDIR/int.err"
  export OUT ERR
  local launcher='
    set -m
    sig="$1"; shift
    "$@" > "$OUT" 2> "$ERR" &
    pid=$!
    n=0
    while [ ! -f "$RUN_MARK.started" ] && [ "$n" -lt 100 ]; do sleep 0.1; n=$((n + 1)); done
    if [ ! -f "$RUN_MARK.started" ]; then kill -KILL -- "-$pid" 2>/dev/null; exit 97; fi
    kill -"$sig" "$pid"
    n=0
    while kill -0 "$pid" 2>/dev/null && [ "$n" -lt 100 ]; do sleep 0.1; n=$((n + 1)); done
    if kill -0 "$pid" 2>/dev/null; then kill -KILL -- "-$pid" 2>/dev/null; exit 98; fi
    wait "$pid"
  '
  run "$BASH_BIN" -c "$launcher" _ "$1" "$BASH_BIN" "$RUN" --catalog "$FIX/interrupt.json" --root "$RUN_ROOT" 1 2 3 4
}

# assert_interrupted: the shared expectations of both signals.
assert_interrupted() {
  [ "$status" -eq 130 ]
  local expected
  expected="$(printf '%s\n' \
    '==> [1/4] quick (unit)' \
    '==> [2/4] slow (integration)' \
    'Test Results' \
    '============' \
    '✓ quick (unit)' \
    '- slow (integration) (interrupted)' \
    '- never (sast) (not run)' \
    '- never too (unit) (not run)' \
    '' \
    '1 passed, 0 failed, 3 not finished. Exit code: 130')"
  [ "$(cat "$OUT")" = "$expected" ]
  [ ! -s "$ERR" ]
  # the unfinished suites never ran, and the interrupted one did not run to its end
  [ "$(marks)" = "quick" ]
  # the interrupted suite's whole process group is gone (its `sleep 31` child included)
  local sleeper n=0
  sleeper="$(cat "$RUN_MARK.sleeppid")"
  while kill -0 "$sleeper" 2>/dev/null && [ "$n" -lt 30 ]; do sleep 0.1; n=$((n + 1)); done
  if kill -0 "$sleeper" 2>/dev/null; then
    kill -KILL "$sleeper" 2>/dev/null
    return 1
  fi
}

@test "SIGTERM mid-run: the running suite is stopped, later ones are not started, the summary marks them, exit 130" {
  interrupt_run TERM
  assert_interrupted
}

@test "SIGINT mid-run: same summary and exit 130" {
  skip "disabled until the E77 SIGINT-in-background fix lands: fails whenever bats runs as a background job (SIGINT inherited as ignored); see project/rapports/analysis/mirror-test-subject-invariant-sigint-background-20261023.md"
  interrupt_run INT
  assert_interrupted
}
