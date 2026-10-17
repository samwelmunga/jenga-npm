#!/usr/bin/env bats
#
# Coverage for skills/j-commit/scripts/test-gate-run.sh (E72_S04_T03).
#
# The script is the execution half of j.commit's test gate: `full` and `scoped` run a selection through
# skills/j-test/scripts/run-suites.sh and end with TEST_GATE_RESULT / TEST_GATE_FAILED; `log` appends a
# `commit_test_gate` event to events.json under scripts/with-lock.sh. Contract under test: the script's header and the
# task text, not the implementation.
#
# How the cases are written
#   - The script locates the j-test scripts, resolve-root.sh and with-lock.sh relative to itself, so every case runs a
#     COPY of it inside a throwaway package tree ($PKG) holding the real j-test scripts, the real resolver and the real
#     lock. Where a case needs run-suites.sh to behave in a way real suites cannot produce (print nothing, exit 7,
#     exit 130 without a signal), that one script in $PKG is replaced by a stub; build-catalog.sh is replaced the same
#     way for "the catalog cannot be built".
#   - Suite commands are trivial shell snippets (echo, exit N, sleep) that record themselves by appending a line to
#     $RUN_MARK, so "nothing ran" is proved by that file not existing. Discovery documents are inline JSON handed over
#     with --discovery-file, so no real discovery (25-35 s on this repo) happens. Nothing here runs this repository's
#     `npm test` or `bats tests/*.bats`.
#   - Every events.json is a scratch file under $PROJ (a project root inside BATS_TEST_TMPDIR, reached through
#     `log --root`). This repository's project/logs/events.json is never written.
#   - Every script invocation goes through `bash <script>`, so the executable bit is not relied on.
#   - No line below begins with `[[`.

# shellcheck disable=SC2016,SC2030,SC2031,SC2317
# SC2016: JSON fixtures and suite commands are single-quoted on purpose ($RUN_MARK must reach the suite's shell
# unexpanded). SC2030/SC2031: bats runs each @test in its own subshell, so reading $status/$output after `run` is
# correct. SC2317: helper functions are reached through bats' own dispatch.

bats_require_minimum_version 1.5.0

load helpers/assertions

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd -P)"
BASH_BIN="$(command -v bash)"
SCRIPT_SRC="$REPO_ROOT/skills/j-commit/scripts/test-gate-run.sh"

setup() {
  export LC_ALL=C
  unset JENGA_PROJECT_ROOT
  export TMPDIR="$BATS_TEST_TMPDIR/tmp"
  mkdir -p "$TMPDIR"

  PKG="$BATS_TEST_TMPDIR/pkg"
  GATE="$PKG/skills/j-commit/scripts/test-gate-run.sh"
  PROJ="$BATS_TEST_TMPDIR/proj"
  OUT="$BATS_TEST_TMPDIR/out"
  DISC="$BATS_TEST_TMPDIR/discovery.json"
  EVENTS="$PROJ/project/logs/events.json"
  RUN_MARK="$BATS_TEST_TMPDIR/run-mark"
  export RUN_MARK
  mkdir -p "$PROJ" "$OUT"
  build_pkg
}

# ---- fixture helpers ---------------------------------------------------------------------------------------------

# build_pkg: the throwaway package tree around a copy of the script.
build_pkg() {
  mkdir -p "$PKG/skills/j-commit/scripts" "$PKG/skills/j-test/scripts" "$PKG/scripts"
  cp "$SCRIPT_SRC" "$GATE"
  cp "$REPO_ROOT"/skills/j-test/scripts/*.sh "$PKG/skills/j-test/scripts/"
  cp "$REPO_ROOT/scripts/resolve-root.sh" "$REPO_ROOT/scripts/with-lock.sh" "$PKG/scripts/"
}

# stub_runner: replace run-suites.sh with a script that prints $STUB_RS_OUT (when set) and exits $STUB_RS_EXIT.
stub_runner() {
  cat > "$PKG/skills/j-test/scripts/run-suites.sh" <<'EOF'
#!/usr/bin/env bash
printf 'run\n' >> "$RUN_MARK"
[ -z "${STUB_RS_OUT:-}" ] || printf '%s\n' "$STUB_RS_OUT"
exit "${STUB_RS_EXIT:-0}"
EOF
}

# make_disc <name> <type> <command> [<name> <type> <command> ...]: a discovery document (the file at $DISC) whose
# suites are s1, s2, ... in that order, so build-catalog.sh numbers them 1, 2, ... in the same order.
make_disc() {
  local json='[]' i=0
  while [ "$#" -ge 3 ]; do
    i=$((i + 1))
    json="$(printf '%s' "$json" | jq -c --arg id "s$i" --arg name "$1" --arg type "$2" --arg cmd "$3" \
      '. + [{id: $id, name: $name, type: $type, ecosystem: "stub", command: $cmd, paths: []}]')"
    shift 3
  done
  printf '{"suites":%s,"warnings":[]}\n' "$json" > "$DISC"
}

# three_pass: three passing suites that record "one", "two", "three".
three_pass() {
  make_disc "one" unit 'echo one >> "$RUN_MARK"' \
            "two" integration 'echo two >> "$RUN_MARK"' \
            "three" sast 'echo three >> "$RUN_MARK"'
}

# write_catalog <file> <json>: a catalog (the build-catalog.sh contract) for `scoped`.
write_catalog() {
  printf '%s\n' "$2" > "$1"
}

# write_plan <status> <selection-json> <catalog-file-or-null>
write_plan() {
  PLAN="$BATS_TEST_TMPDIR/plan.json"
  if [ "$3" = "null" ]; then
    printf '{"status":"%s","source":"staged","changed_count":1,"selection":%s,"catalog_file":null}\n' "$1" "$2" > "$PLAN"
  else
    printf '{"status":"%s","source":"staged","changed_count":1,"selection":%s,"catalog_file":"%s"}\n' "$1" "$2" "$3" > "$PLAN"
  fi
}

THREE_CAT='{"runnable":[
 {"n":1,"id":"a","name":"one","type":"unit","ecosystem":"stub","command":"echo one >> \"$RUN_MARK\"","also":[]},
 {"n":2,"id":"b","name":"two","type":"unit","ecosystem":"stub","command":"echo two >> \"$RUN_MARK\"","also":[]},
 {"n":3,"id":"c","name":"three","type":"unit","ecosystem":"stub","command":"echo three >> \"$RUN_MARK\"","also":[]}
],"not_runnable":[],"warnings":[]}'

# ---- running and reading -----------------------------------------------------------------------------------------

# gate_full <extra args...>: `full` against $DISC and the scratch project; sets $status, $output and $stderr.
gate_full() {
  run --separate-stderr "$BASH_BIN" "$GATE" full --out-dir "$OUT" --root "$PROJ" --discovery-file "$DISC" "$@"
}

# gate_scoped <plan> <extra args...>
gate_scoped() {
  local plan="$1"
  shift
  run --separate-stderr "$BASH_BIN" "$GATE" scoped --plan "$plan" --root "$PROJ" "$@"
}

# gate_log <args...>
gate_log() {
  run --separate-stderr "$BASH_BIN" "$GATE" log --root "$PROJ" "$@"
}

# marks: the lines the suites recorded, joined with commas.
marks() {
  paste -sd, "$RUN_MARK"
}

# trailer_is <result> <failed>: the LAST TWO lines of stdout are exactly the two trailer lines.
trailer_is() {
  local got want
  got="$(printf '%s\n' "$output" | tail -n 2)"
  want="$(printf 'TEST_GATE_RESULT=%s\nTEST_GATE_FAILED=%s' "$1" "$2")"
  if [ "$got" != "$want" ]; then
    printf 'trailer mismatch\n--- got ---\n%s\n--- want ---\n%s\n-----------\n' "$got" "$want"
    return 1
  fi
}

# refuse_plan <plan> <stderr needle>: a refused plan is exit 2, a cause on stderr, nothing on stdout (so no
# TEST_GATE_ line), and no suite run.
refuse_plan() {
  gate_scoped "$1"
  [ "$status" -eq 2 ]
  [ -z "$output" ]
  assert_contains "$stderr" "$2"
  [ ! -e "$RUN_MARK" ]
}

# events_ok: events.json is exactly one JSON array.
events_ok() {
  jq -e 'type == "array"' "$EVENTS" > /dev/null
}

# ================================================================================================================
# Script text and usage
# ================================================================================================================

@test "the header documents the subcommands, result words, exit codes and the events schema" {
  local head_text
  head_text="$(sed -n '1,/^set -u/p' "$SCRIPT_SRC")"
  assert_contains "$head_text" "Usage:"
  assert_contains "$head_text" "test-gate-run.sh full"
  assert_contains "$head_text" "test-gate-run.sh scoped"
  assert_contains "$head_text" "test-gate-run.sh log"
  assert_contains "$head_text" "TEST_GATE_RESULT=passed|failed|error|interrupted|unavailable"
  assert_contains "$head_text" "TEST_GATE_FAILED="
  assert_contains "$head_text" "EXIT CODES"
  assert_contains "$head_text" "EVENTS"
  assert_contains "$head_text" "commit_test_gate"
  assert_contains "$head_text" "failed_suites"
  assert_contains "$head_text" "with-lock.sh"
  assert_contains "$head_text" "bash 3.2"
}

@test "the script uses no bash 4 feature (macOS bash 3.2 compatible)" {
  # Comment lines are skipped; the patterns are the bash 4+ features named in the repo's other scripts.
  if grep -v '^[[:space:]]*#' "$SCRIPT_SRC" | grep -E 'mapfile|readarray|declare -A|local -A|\$\{[A-Za-z_]+(,,|\^\^)\}|&>>|\|&' > /dev/null; then
    printf 'a bash 4+ construct is used in %s\n' "$SCRIPT_SRC"
    return 1
  fi
}

@test "the script is shellcheck clean" {
  command -v shellcheck > /dev/null 2>&1 || skip "shellcheck is not installed"
  run shellcheck -S warning -x "$SCRIPT_SRC"
  [ "$status" -eq 0 ]
}

@test "--help prints usage and exits 0 without writing anything" {
  run --separate-stderr "$BASH_BIN" "$GATE" --help
  [ "$status" -eq 0 ]
  assert_output_contains "Usage: test-gate-run.sh full"
  assert_output_contains "test-gate-run.sh log"
  [ ! -e "$RUN_MARK" ]
}

@test "usage errors exit 2 with the cause on stderr and nothing on stdout" {
  run --separate-stderr "$BASH_BIN" "$GATE"
  [ "$status" -eq 2 ]
  [ -z "$output" ]
  assert_contains "$stderr" "a subcommand is required"

  run --separate-stderr "$BASH_BIN" "$GATE" bogus
  [ "$status" -eq 2 ]
  [ -z "$output" ]
  assert_contains "$stderr" "unknown subcommand: bogus"

  run --separate-stderr "$BASH_BIN" "$GATE" full
  [ "$status" -eq 2 ]
  [ -z "$output" ]
  assert_contains "$stderr" "--out-dir <dir> is required"

  run --separate-stderr "$BASH_BIN" "$GATE" full --out-dir "$BATS_TEST_TMPDIR/does-not-exist"
  [ "$status" -eq 2 ]
  [ -z "$output" ]
  assert_contains "$stderr" "not an existing directory"

  run --separate-stderr "$BASH_BIN" "$GATE" full --out-dir "$OUT" --bogus
  [ "$status" -eq 2 ]
  [ -z "$output" ]
  assert_contains "$stderr" "unknown argument '--bogus'"

  run --separate-stderr "$BASH_BIN" "$GATE" scoped
  [ "$status" -eq 2 ]
  [ -z "$output" ]
  assert_contains "$stderr" "--plan <plan.json> is required"

  run --separate-stderr "$BASH_BIN" "$GATE" scoped --plan
  [ "$status" -eq 2 ]
  assert_contains "$stderr" "--plan needs a value"

  run --separate-stderr "$BASH_BIN" "$GATE" log
  [ "$status" -eq 2 ]
  assert_contains "$stderr" "--action is required"

  [ ! -e "$RUN_MARK" ]
}

# ================================================================================================================
# full
# ================================================================================================================

@test "full: passing suites each run once, in catalog order, and end with passed, an empty failed list and exit 0" {
  three_pass
  gate_full
  [ "$status" -eq 0 ]
  [ "$(marks)" = "one,two,three" ]
  trailer_is passed ""
  assert_output_contains "==> [1/3] one (unit)"
  assert_output_contains "==> [3/3] three (sast)"
  assert_output_contains "3 passed, 0 failed. Exit code: 0"
  # the catalog was built once into the out dir, and the run was copied to run.log
  [ "$(jq -r '.runnable | length' "$OUT/catalog.json")" -eq 3 ]
  [ -s "$OUT/run.log" ]
  assert_contains "$(cat "$OUT/run.log")" "3 passed, 0 failed. Exit code: 0"
  assert_not_contains "$(cat "$OUT/run.log")" "TEST_GATE_RESULT"
}

@test "full: runs unchanged under /bin/bash (3.2 on macOS) with the same result" {
  [ -x /bin/bash ] || skip "no /bin/bash"
  three_pass
  run --separate-stderr /bin/bash "$GATE" full --out-dir "$OUT" --root "$PROJ" --discovery-file "$DISC"
  [ "$status" -eq 0 ]
  [ "$(marks)" = "one,two,three" ]
  trailer_is passed ""
}

@test "full: a failing suite is failed, exits 1, names the suite, and the suite after it still runs" {
  make_disc "first" unit 'echo first >> "$RUN_MARK"' \
            "broken" unit 'echo broken >> "$RUN_MARK"; echo "boom" >&2; exit 3' \
            "last" unit 'echo last >> "$RUN_MARK"'
  gate_full
  [ "$status" -eq 1 ]
  [ "$(marks)" = "first,broken,last" ]
  trailer_is failed "broken"
  assert_output_contains "✗ broken (unit)"
  # the suite's stderr reaches the caller's stderr and the log
  assert_contains "$stderr" "boom"
  assert_contains "$(cat "$OUT/run.log")" "boom"
}

@test "full: two failures give both names separated by ';' and a passing suite between them still runs" {
  make_disc "bad one" unit 'echo bad1 >> "$RUN_MARK"; exit 1' \
            "fine" unit 'echo fine >> "$RUN_MARK"' \
            "bad two" sast 'echo bad2 >> "$RUN_MARK"; exit 2'
  gate_full
  [ "$status" -eq 1 ]
  [ "$(marks)" = "bad1,fine,bad2" ]
  trailer_is failed "bad one;bad two"
}

@test "full: a suite that exits 127 or prints nothing is failed like any other, never a pass" {
  make_disc "missing tool" unit 'jenga-gate-no-such-command-xyz' \
            "silent failure" unit 'exit 1'
  gate_full
  [ "$status" -eq 1 ]
  trailer_is failed "missing tool;silent failure"
  assert_output_not_contains "TEST_GATE_RESULT=passed"
}

@test "full: the suite's exit code survives the output capture (a failing run is failed although its output is copied)" {
  make_disc "loud failure" unit 'echo noisy output; echo more noise >&2; exit 9'
  gate_full
  [ "$status" -eq 1 ]
  trailer_is failed "loud failure"
  assert_contains "$(cat "$OUT/run.log")" "noisy output"
  assert_contains "$(cat "$OUT/run.log")" "more noise"
}

@test "full: no runnable suite is unavailable, prints the plain line, exits 3 and runs nothing" {
  make_disc "docs only" sast ''
  gate_full
  [ "$status" -eq 3 ]
  assert_output_contains "No runnable test suites were found; no tests were run."
  trailer_is unavailable ""
  assert_output_not_contains "TEST_GATE_RESULT=passed"
  assert_output_not_contains "Test Results"
  [ ! -e "$RUN_MARK" ]
  [ ! -e "$OUT/run.log" ]
}

@test "full: a discovery with no suite at all is unavailable too" {
  printf '{"suites":[],"warnings":[]}\n' > "$DISC"
  gate_full
  [ "$status" -eq 3 ]
  trailer_is unavailable ""
  [ ! -e "$RUN_MARK" ]
}

@test "full: a catalog that cannot be built is error (exit 2) and runs nothing" {
  three_pass
  printf '#!/usr/bin/env bash\necho "stub catalog failure" >&2\nexit 1\n' > "$PKG/skills/j-test/scripts/build-catalog.sh"
  gate_full
  [ "$status" -eq 2 ]
  trailer_is error ""
  assert_contains "$stderr" "could not be built"
  [ ! -e "$RUN_MARK" ]
}

@test "full: an unreadable discovery file is error (exit 2) and runs nothing" {
  gate_full --discovery-file "$BATS_TEST_TMPDIR/no-such-discovery.json"
  [ "$status" -eq 2 ]
  trailer_is error ""
  [ ! -e "$RUN_MARK" ]
}

# ================================================================================================================
# classification of run-suites.sh's exit code
# ================================================================================================================

@test "classification: run-suites exit 1 with no parsable failed line reports 'unknown suite', never empty" {
  three_pass
  stub_runner
  export STUB_RS_EXIT=1 STUB_RS_OUT="the suites went wrong"
  gate_full
  [ "$status" -eq 1 ]
  trailer_is failed "unknown suite"
}

@test "classification: run-suites exit 0 is passed, exit 2 and any other code are error (exit 2), 130 is interrupted" {
  three_pass
  stub_runner

  export STUB_RS_EXIT=0
  gate_full
  [ "$status" -eq 0 ]
  trailer_is passed ""

  export STUB_RS_EXIT=2 STUB_RS_OUT="run-suites.sh: no suite numbers given"
  gate_full
  [ "$status" -eq 2 ]
  trailer_is error ""

  export STUB_RS_EXIT=7 STUB_RS_OUT=""
  gate_full
  [ "$status" -eq 2 ]
  trailer_is error ""

  export STUB_RS_EXIT=130
  gate_full
  [ "$status" -eq 130 ]
  trailer_is interrupted ""
}

@test "classification: a run-suites validation failure maps to error (exit 2) with the cause on stderr" {
  write_catalog "$BATS_TEST_TMPDIR/cat.json" "$THREE_CAT"
  write_plan mapped '[9]' "$BATS_TEST_TMPDIR/cat.json"
  gate_scoped "$PLAN"
  [ "$status" -eq 2 ]
  trailer_is error ""
  assert_contains "$stderr" "suite 9 is not a runnable suite"
  [ ! -e "$RUN_MARK" ]
}

@test "classification: names of suites that failed before an interrupt are still reported" {
  three_pass
  stub_runner
  STUB_RS_OUT="$(printf 'Test Results\n============\n✗ one (unit)\n- two (integration) (interrupted)\n- three (sast) (not run)\n\n0 passed, 1 failed, 2 not finished. Exit code: 130')"
  export STUB_RS_EXIT=130 STUB_RS_OUT
  gate_full
  [ "$status" -eq 130 ]
  trailer_is interrupted "one"
}

@test "classification: failed names are resolved to the catalog's name, even when a name already ends in its type" {
  make_disc "integration (integration)" integration 'exit 1' \
            "plain" unit 'exit 4'
  gate_full
  [ "$status" -eq 1 ]
  trailer_is failed "integration (integration);plain"
}

# ================================================================================================================
# scoped
# ================================================================================================================

@test "scoped: runs exactly the plan's selection against the plan's catalog; an unselected suite does not run" {
  write_catalog "$BATS_TEST_TMPDIR/cat.json" "$THREE_CAT"
  write_plan mapped '[1,3]' "$BATS_TEST_TMPDIR/cat.json"
  gate_scoped "$PLAN"
  [ "$status" -eq 0 ]
  [ "$(marks)" = "one,three" ]
  trailer_is passed ""
  assert_output_contains "==> [1/2] one (unit)"
  assert_output_contains "==> [2/2] three (unit)"
  assert_output_not_contains "two"
  # run.log goes next to the plan by default
  [ -s "$BATS_TEST_TMPDIR/run.log" ]
}

@test "scoped: --out-dir moves run.log" {
  write_catalog "$BATS_TEST_TMPDIR/cat.json" "$THREE_CAT"
  write_plan mapped '[2]' "$BATS_TEST_TMPDIR/cat.json"
  gate_scoped "$PLAN" --out-dir "$OUT"
  [ "$status" -eq 0 ]
  [ "$(marks)" = "two" ]
  [ -s "$OUT/run.log" ]
  [ ! -e "$BATS_TEST_TMPDIR/run.log" ]
}

@test "scoped: a failing selected suite is failed with its name, and a later selected suite still runs" {
  write_catalog "$BATS_TEST_TMPDIR/cat.json" '{"runnable":[
    {"n":1,"id":"a","name":"alpha","type":"unit","ecosystem":"stub","command":"echo alpha >> \"$RUN_MARK\"","also":[]},
    {"n":4,"id":"d","name":"delta","type":"unit","ecosystem":"stub","command":"echo delta >> \"$RUN_MARK\"; exit 1","also":[]},
    {"n":5,"id":"e","name":"echo","type":"unit","ecosystem":"stub","command":"echo echo >> \"$RUN_MARK\"","also":[]}
  ],"not_runnable":[],"warnings":[]}'
  write_plan mapped '[4,5]' "$BATS_TEST_TMPDIR/cat.json"
  gate_scoped "$PLAN"
  [ "$status" -eq 1 ]
  [ "$(marks)" = "delta,echo" ]
  trailer_is failed "delta"
}

@test "scoped: a plan with status zero is refused: exit 2, nothing run, no result line" {
  write_catalog "$BATS_TEST_TMPDIR/cat.json" "$THREE_CAT"
  write_plan zero '[]' "$BATS_TEST_TMPDIR/cat.json"
  refuse_plan "$PLAN" "status is 'zero'"
}

@test "scoped: a plan with status error is refused even when it carries a selection and a catalog" {
  write_catalog "$BATS_TEST_TMPDIR/cat.json" "$THREE_CAT"
  write_plan error '[1]' "$BATS_TEST_TMPDIR/cat.json"
  refuse_plan "$PLAN" "status is 'error'"
}

@test "scoped: an unreadable plan (absent, empty, not JSON, not an object) is refused" {
  refuse_plan "$BATS_TEST_TMPDIR/no-such-plan.json" "not a readable JSON object"

  : > "$BATS_TEST_TMPDIR/empty-plan.json"
  refuse_plan "$BATS_TEST_TMPDIR/empty-plan.json" "not a readable JSON object"

  printf 'this is not json\n' > "$BATS_TEST_TMPDIR/junk-plan.json"
  refuse_plan "$BATS_TEST_TMPDIR/junk-plan.json" "not a readable JSON object"

  printf '[1,2,3]\n' > "$BATS_TEST_TMPDIR/array-plan.json"
  refuse_plan "$BATS_TEST_TMPDIR/array-plan.json" "not a readable JSON object"
}

@test "scoped: a plan with no status is refused" {
  write_catalog "$BATS_TEST_TMPDIR/cat.json" "$THREE_CAT"
  printf '{"selection":[1],"catalog_file":"%s"}\n' "$BATS_TEST_TMPDIR/cat.json" > "$BATS_TEST_TMPDIR/nostatus.json"
  refuse_plan "$BATS_TEST_TMPDIR/nostatus.json" "status is 'missing'"
}

@test "scoped: a missing, null, non-string or unreadable catalog_file is refused" {
  write_plan mapped '[1]' "$BATS_TEST_TMPDIR/no-such-catalog.json"
  refuse_plan "$PLAN" "catalog_file is missing or unreadable"

  write_plan mapped '[1]' null
  refuse_plan "$PLAN" "catalog_file is missing or unreadable"

  printf '{"status":"mapped","selection":[1],"catalog_file":42}\n' > "$BATS_TEST_TMPDIR/numeric.json"
  refuse_plan "$BATS_TEST_TMPDIR/numeric.json" "catalog_file is missing or unreadable"

  mkdir "$BATS_TEST_TMPDIR/a-directory"
  write_plan mapped '[1]' "$BATS_TEST_TMPDIR/a-directory"
  refuse_plan "$PLAN" "catalog_file is missing or unreadable"
}

@test "scoped: a mapped plan without a usable selection is refused" {
  write_catalog "$BATS_TEST_TMPDIR/cat.json" "$THREE_CAT"
  write_plan mapped '[]' "$BATS_TEST_TMPDIR/cat.json"
  refuse_plan "$PLAN" "no usable selection"

  write_plan mapped '"1"' "$BATS_TEST_TMPDIR/cat.json"
  refuse_plan "$PLAN" "no usable selection"

  write_plan mapped '["1"]' "$BATS_TEST_TMPDIR/cat.json"
  refuse_plan "$PLAN" "no usable selection"

  write_plan mapped '[0]' "$BATS_TEST_TMPDIR/cat.json"
  refuse_plan "$PLAN" "no usable selection"
}

# ================================================================================================================
# interrupt
# ================================================================================================================

# interrupt_run <signal>: start `scoped` on a plan whose first suite sleeps, wait until it is running, send the
# signal to the script, and wait for it to exit. Every wait is bounded. The script runs from a launcher under `set -m`
# (a non-interactive shell starts an `&` job with SIGINT ignored, and a script cannot trap a signal it inherited as
# ignored). The script's stdout and stderr land in $INT_OUT and $INT_ERR; its exit status becomes $status.
interrupt_run() {
  INT_OUT="$BATS_TEST_TMPDIR/int.out"
  INT_ERR="$BATS_TEST_TMPDIR/int.err"
  export INT_OUT INT_ERR
  write_catalog "$BATS_TEST_TMPDIR/slow-cat.json" '{"runnable":[
    {"n":1,"id":"q","name":"quick","type":"unit","ecosystem":"stub","command":"echo quick >> \"$RUN_MARK\"","also":[]},
    {"n":2,"id":"s","name":"slow","type":"unit","ecosystem":"stub","command":"sleep 31 & echo $! > \"$RUN_MARK.sleeppid\"; echo started > \"$RUN_MARK.started\"; wait; echo finished >> \"$RUN_MARK\"","also":[]},
    {"n":3,"id":"n","name":"never","type":"unit","ecosystem":"stub","command":"echo never >> \"$RUN_MARK\"","also":[]}
  ],"not_runnable":[],"warnings":[]}'
  write_plan mapped '[1,2,3]' "$BATS_TEST_TMPDIR/slow-cat.json"
  local launcher='
    set -m
    sig="$1"; shift
    "$@" > "$INT_OUT" 2> "$INT_ERR" &
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
  run "$BASH_BIN" -c "$launcher" _ "$1" "$BASH_BIN" "$GATE" scoped --plan "$PLAN" --root "$PROJ" --out-dir "$OUT"
}

# assert_interrupted: the shared expectations of both signals.
assert_interrupted() {
  [ "$status" -eq 130 ]
  output="$(cat "$INT_OUT")"
  trailer_is interrupted ""
  assert_output_contains "- slow (unit) (interrupted)"
  assert_output_contains "- never (unit) (not run)"
  assert_output_contains "1 passed, 0 failed, 2 not finished. Exit code: 130"
  assert_output_not_contains "TEST_GATE_RESULT=passed"
  # the later suite never ran, and the interrupted one did not run to its end
  [ "$(marks)" = "quick" ]
  # the interrupted suite's whole process group is gone (its `sleep 31` child included)
  local sleeper n=0
  sleeper="$(cat "$RUN_MARK.sleeppid")"
  while kill -0 "$sleeper" 2>/dev/null && [ "$n" -lt 30 ]; do sleep 0.1; n=$((n + 1)); done
  if kill -0 "$sleeper" 2>/dev/null; then
    kill -KILL "$sleeper" 2>/dev/null
    return 1
  fi
  # the interrupted run was still copied to the log
  assert_contains "$(cat "$OUT/run.log")" "Exit code: 130"
}

@test "interrupt: SIGTERM during a run is interrupted, exit 130, the running suite is stopped and later ones never start" {
  interrupt_run TERM
  assert_interrupted
}

@test "interrupt: SIGINT during a run gives the same result" {
  interrupt_run INT
  assert_interrupted
}

# ================================================================================================================
# log
# ================================================================================================================

@test "log: appends a well-formed commit_test_gate event with every documented field, creating events.json (and its directory)" {
  [ ! -e "$PROJ/project" ]
  gate_log --action failed --choice anyway --reason "tests failed, committed anyway" --failed "bats tests;shellcheck" --caller interactive
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  events_ok
  [ "$(jq 'length' "$EVENTS")" -eq 1 ]
  jq -e '.[0] | keys == ["action","agent","caller","choice","date","event","failed_suites","reason"]' "$EVENTS" > /dev/null
  jq -e '.[0] | .event == "commit_test_gate" and .agent == "j.commit" and .action == "failed" and .choice == "anyway"
         and .reason == "tests failed, committed anyway" and .caller == "interactive"
         and .failed_suites == ["bats tests","shellcheck"]' "$EVENTS" > /dev/null
  jq -e '.[0].date | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$")' "$EVENTS" > /dev/null
}

@test "log: absent options are null and an empty failed list" {
  gate_log --action skip
  [ "$status" -eq 0 ]
  jq -e '.[0] | .action == "skip" and .choice == null and .reason == null and .failed_suites == [] and .caller == null' "$EVENTS" > /dev/null
}

@test "log: every documented action is accepted and an unknown one is a usage error that writes nothing" {
  local a
  for a in skip passed failed error override halt fallback unavailable interrupted; do
    gate_log --action "$a"
    [ "$status" -eq 0 ]
  done
  [ "$(jq 'length' "$EVENTS")" -eq 9 ]
  [ "$(jq -r '[.[].action] | join(",")' "$EVENTS")" = "skip,passed,failed,error,override,halt,fallback,unavailable,interrupted" ]

  gate_log --action explode
  [ "$status" -eq 2 ]
  assert_contains "$stderr" "unknown action 'explode'"
  gate_log --action skip --caller robot
  [ "$status" -eq 2 ]
  assert_contains "$stderr" "--caller must be interactive or noninteractive"
  [ "$(jq 'length' "$EVENTS")" -eq 9 ]
}

@test "log: --failed is ';'-separated, empty items are dropped" {
  gate_log --action failed --failed ";a;;b c;"
  [ "$status" -eq 0 ]
  jq -e '.[0].failed_suites == ["a","b c"]' "$EVENTS" > /dev/null
}

@test "log: awkward text (quotes, a dollar sign, a newline, a leading dash) is stored verbatim" {
  gate_log --action override --reason 'said "yes" to $HOME and `ls`
second line' --choice "-x"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.[0].reason' "$EVENTS")" = 'said "yes" to $HOME and `ls`
second line' ]
  [ "$(jq -r '.[0].choice' "$EVENTS")" = "-x" ]
}

@test "log: extends an existing events.json and leaves the earlier entries intact" {
  mkdir -p "$PROJ/project/logs"
  printf '[{"event":"session_start","agent":"developer","n":1},{"event":"other","n":2}]\n' > "$EVENTS"
  gate_log --action passed
  [ "$status" -eq 0 ]
  [ "$(jq 'length' "$EVENTS")" -eq 3 ]
  jq -e '.[0] == {"event":"session_start","agent":"developer","n":1} and .[1] == {"event":"other","n":2}
         and .[2].event == "commit_test_gate"' "$EVENTS" > /dev/null
}

@test "log: an empty events.json becomes a one-element array" {
  mkdir -p "$PROJ/project/logs"
  : > "$EVENTS"
  gate_log --action halt
  [ "$status" -eq 0 ]
  events_ok
  [ "$(jq 'length' "$EVENTS")" -eq 1 ]
  [ "$(jq -r '.[0].action' "$EVENTS")" = "halt" ]
}

@test "log: an events.json that is not a single JSON array is left untouched and the call fails with exit 1" {
  mkdir -p "$PROJ/project/logs"
  local before
  printf '{"not":"an array"}\n' > "$EVENTS"
  before="$(cksum < "$EVENTS")"
  gate_log --action skip
  [ "$status" -eq 1 ]
  [ "$(cksum < "$EVENTS")" = "$before" ]
  assert_contains "$stderr" "nothing was written"

  printf '[1,2]\n[3]\n' > "$EVENTS"
  before="$(cksum < "$EVENTS")"
  gate_log --action skip
  [ "$status" -eq 1 ]
  [ "$(cksum < "$EVENTS")" = "$before" ]

  printf 'not json at all\n' > "$EVENTS"
  before="$(cksum < "$EVENTS")"
  gate_log --action skip
  [ "$status" -eq 1 ]
  [ "$(cksum < "$EVENTS")" = "$before" ]

  # no temp file left behind in the logs directory
  [ -z "$(find "$PROJ/project/logs" -name 'events_tmp.*' -print)" ]
}

@test "log: concurrent calls under the lock all land: no lost update, a valid JSON array afterwards" {
  local i pids="" p failed=0
  for i in 1 2 3 4 5 6 7 8; do
    "$BASH_BIN" "$GATE" log --root "$PROJ" --action failed --reason "writer $i" --failed "suite $i" --caller interactive \
      > /dev/null 2>&1 &
    pids="$pids $!"
  done
  for p in $pids; do
    wait "$p" || failed=$((failed + 1))
  done
  [ "$failed" -eq 0 ]
  events_ok
  [ "$(jq 'length' "$EVENTS")" -eq 8 ]
  [ "$(jq -r '[.[].reason] | unique | length' "$EVENTS")" -eq 8 ]
  [ -z "$(find "$PROJ/project/logs" -name 'events_tmp.*' -print)" ]
  [ ! -e "$EVENTS.lock.d" ]
}

@test "log: a lock that cannot be acquired exits 4 without writing" {
  mkdir -p "$PROJ/project/logs"
  printf '[{"event":"earlier"}]\n' > "$EVENTS"
  local before
  before="$(cksum < "$EVENTS")"
  mkdir "$EVENTS.lock.d"
  export WITH_LOCK_TIMEOUT_SECONDS=1
  gate_log --action skip
  [ "$status" -eq 4 ]
  assert_contains "$stderr" "could not acquire the lock"
  [ "$(cksum < "$EVENTS")" = "$before" ]
}

@test "log: writes only events.json, and test-config.json is byte-identical before and after (a failure choice is never persisted)" {
  mkdir -p "$PROJ/project/configs"
  printf '{"commit_prompt_default":"","other":true}\n' > "$PROJ/project/configs/test-config.json"
  local before
  before="$(cksum < "$PROJ/project/configs/test-config.json")"

  gate_log --action failed --choice anyway --failed "x" --caller interactive
  [ "$status" -eq 0 ]
  gate_log --action override --choice anyway --caller interactive
  [ "$status" -eq 0 ]
  gate_log --action halt --choice abort
  [ "$status" -eq 0 ]

  [ "$(cksum < "$PROJ/project/configs/test-config.json")" = "$before" ]
  # the only files under the scratch project: the config it started with and events.json
  [ "$(find "$PROJ" -type f | sort | paste -sd, -)" = "$PROJ/project/configs/test-config.json,$EVENTS" ]
  [ -z "$(find "$PROJ" -name '*.lock.d' -print)" ]
}

@test "log: the logs directory comes from the project's workflow.json registry when one exists" {
  mkdir -p "$PROJ/project/configs"
  jq '.paths.logs = "var/gate-logs"' "$REPO_ROOT/project/configs/workflow.json" > "$PROJ/project/configs/workflow.json"
  gate_log --action skip
  [ "$status" -eq 0 ]
  [ -f "$PROJ/var/gate-logs/events.json" ]
  [ ! -e "$PROJ/project/logs/events.json" ]
}

@test "log: a --root that is not a directory is a usage error" {
  run --separate-stderr "$BASH_BIN" "$GATE" log --root "$BATS_TEST_TMPDIR/nowhere" --action skip
  [ "$status" -eq 2 ]
  assert_contains "$stderr" "--root is not a directory"
}
