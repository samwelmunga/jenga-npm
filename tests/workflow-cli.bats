#!/usr/bin/env bats
#
# Coverage for skills/j-workflow/scripts/workflow-cli.sh (E80_S05_T02): the list/run/status renderers and the
# number-to-id resolution behind `j.workflow`.
#
# Every test points JENGA_WORKFLOW_LOADER and JENGA_RUN_STATE at fixture scripts built in BATS_TEST_TMPDIR, so
# the assertions describe the script and not whichever workflows or runs exist in this repository.

bats_require_minimum_version 1.5.0
load helpers/assertions

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
SCRIPT="$REPO_ROOT/skills/j-workflow/scripts/workflow-cli.sh"

setup() {
  # Loader fixture: prints $LOADER_JSON (default: three definitions), echoes $LOADER_STDERR, exits $LOADER_RC.
  cat > "$BATS_TEST_TMPDIR/loader.sh" <<'LOADER'
#!/usr/bin/env bash
[ -z "${LOADER_STDERR:-}" ] || printf '%s\n' "$LOADER_STDERR" >&2
if [ -n "${LOADER_JSON+x}" ]; then printf '%s\n' "$LOADER_JSON"; else cat <<'JSON'
[
  {"id":"alpha","name":"Alpha Flow","source":"builtin","file":"a.json"},
  {"id":"beta","name":"Beta Flow","source":"project","file":"b.json"},
  {"id":"gamma","name":"Gamma Flow","source":"builtin","file":"g.json"}
]
JSON
fi
exit "${LOADER_RC:-0}"
LOADER
  # Run-state fixture: logs its argv, serves `list` from $RS_ROWS and `status <id>` from a JSON file.
  cat > "$BATS_TEST_TMPDIR/run-state.sh" <<'RUNSTATE'
#!/usr/bin/env bash
echo "$*" >> "$RS_LOG"
case "$1" in
  list) [ ! -f "$RS_ROWS" ] || cat "$RS_ROWS"; [ -z "${RS_LIST_ERR:-}" ] || echo "$RS_LIST_ERR" >&2; exit "${RS_LIST_RC:-0}" ;;
  status) [ -f "$BATS_TEST_TMPDIR/status-$2.json" ] || exit 3; cat "$BATS_TEST_TMPDIR/status-$2.json" ;;
  *) echo "unexpected run-state subcommand: $1" >&2; exit 9 ;;
esac
RUNSTATE
  export RS_LOG="$BATS_TEST_TMPDIR/rs.log" RS_ROWS="$BATS_TEST_TMPDIR/rows.tsv"
  : > "$RS_LOG"
  printf 'r-run\twf-a\trunning\t2026-01-01T00:00:01Z\n'  >  "$RS_ROWS"
  printf 'r-pau\twf-a\tpaused\t2026-01-01T00:00:02Z\n'   >> "$RS_ROWS"
  printf 'r-done\twf-b\tcompleted\t2026-01-01T00:00:03Z\n' >> "$RS_ROWS"
  printf 'r-await\twf-b\tawaiting_confirmation\t2026-01-01T00:00:04Z\n' >> "$RS_ROWS"
  printf 'r-canc\twf-a\tcancelled\t2026-01-01T00:00:05Z\n' >> "$RS_ROWS"
  printf 'r-fail\twf-b\tfailed\t2026-01-01T00:00:06Z\n'   >> "$RS_ROWS"
  cat > "$BATS_TEST_TMPDIR/status-r-pau.json" <<'JSON'
{"run_id":"r-pau","workflow_id":"wf-a","status":"paused","updated_at":"2026-01-01T00:00:02Z","last_checkpoint":"s2",
 "steps":[{"id":"s1","type":"skill","status":"completed","checkpoint":false,"outputs":{"path":"out.txt","n":3}},
          {"id":"s2","type":"confirm","status":"paused","checkpoint":true,"outputs":{}}]}
JSON
  cat > "$BATS_TEST_TMPDIR/status-r-bare.json" <<'JSON'
{"run_id":"r-bare","workflow_id":"wf-b","status":"running","updated_at":"2026-01-02T00:00:00Z","last_checkpoint":null,
 "steps":[{"id":"only","type":"skill","status":"running","checkpoint":false}]}
JSON
  export JENGA_WORKFLOW_LOADER="$BATS_TEST_TMPDIR/loader.sh" JENGA_RUN_STATE="$BATS_TEST_TMPDIR/run-state.sh"
}

@test "list-render prints one numbered line per definition with its source" {
  run --separate-stderr bash "$SCRIPT" list-render
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 3 ]
  [ "${lines[0]}" = "1. alpha - Alpha Flow (builtin)" ]
  [ "${lines[1]}" = "2. beta - Beta Flow (project)" ]
  [ "${lines[2]}" = "3. gamma - Gamma Flow (builtin)" ]
}

@test "list-render appends invalid lines after a blank line, reasons verbatim, other warnings forwarded" {
  export LOADER_STDERR="load-workflows.sh: warning: dropped invalid project workflow p/bad.json:
  missing field: steps
  unknown type: nope
load-workflows.sh: warning: dropped builtin workflow b/worse.json: not valid JSON
load-workflows.sh: warning: id collision on alpha"
  run --separate-stderr bash "$SCRIPT" list-render
  [ "$status" -eq 0 ]
  [ "${lines[2]}" = "3. gamma - Gamma Flow (builtin)" ]
  assert_contains "$output" "(builtin)"$'\n\n'"invalid: p/bad.json - missing field: steps; unknown type: nope"$'\n'"invalid: b/worse.json - not valid JSON"
  assert_contains "$stderr" "id collision on alpha"
}

@test "list-render with an empty catalog and no warnings prints nothing and exits 0" {
  export LOADER_JSON='[]'
  run --separate-stderr bash "$SCRIPT" list-render
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "list-render with only invalid definitions prints the invalid lines without a leading blank line" {
  export LOADER_JSON='[]' LOADER_STDERR="load-workflows.sh: warning: dropped project workflow x.json: broken"
  run --separate-stderr bash "$SCRIPT" list-render
  [ "$status" -eq 0 ]
  [ "$output" = "invalid: x.json - broken" ]
}

@test "list-render exits 2 and surfaces loader stderr when the loader fails" {
  export LOADER_RC=2 LOADER_STDERR="load-workflows.sh: error: catalog unreadable"
  run --separate-stderr bash "$SCRIPT" list-render
  [ "$status" -eq 2 ]
  [ -z "$output" ]
  assert_contains "$stderr" "catalog unreadable"
}

@test "runs-render numbers every run in order and names paused and awaiting_confirmation runs" {
  run --separate-stderr bash "$SCRIPT" runs-render
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "1. r-run - wf-a - running" ]
  [ "${lines[1]}" = "2. r-pau - wf-a - paused" ]
  [ "${lines[5]}" = "6. r-fail - wf-b - failed" ]
  assert_contains "$output" "failed"$'\n\n'"paused: r-pau"$'\n'"awaiting_confirmation: r-await"
}

@test "runs-render with no runs prints nothing and exits 0" {
  : > "$RS_ROWS"
  run --separate-stderr bash "$SCRIPT" runs-render
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "runs-render tolerates run-state exit 4 after a full listing and forwards the warning" {
  export RS_LIST_RC=4 RS_LIST_ERR="run-state.sh: warning: skipped corrupt state file"
  run --separate-stderr bash "$SCRIPT" runs-render
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "1. r-run - wf-a - running" ]
}

@test "runs-render exits 2 when run-state list fails" {
  export RS_LIST_RC=5
  run --separate-stderr bash "$SCRIPT" runs-render
  [ "$status" -eq 2 ]
}

@test "resumable keeps paused, awaiting_confirmation and failed runs, renumbered from 1" {
  run --separate-stderr bash "$SCRIPT" resumable
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "1. r-pau - wf-a - paused" ]
  [ "${lines[1]}" = "2. r-await - wf-b - awaiting_confirmation" ]
  [ "${lines[2]}" = "3. r-fail - wf-b - failed" ]
  assert_not_contains "$output" "r-done"
  assert_not_contains "$output" "r-canc"
  assert_not_contains "$output" "r-run "
}

@test "status-render with a run id shows run, workflow, lifecycle, checkpoint marker and outputs" {
  run --separate-stderr bash "$SCRIPT" status-render r-pau
  [ "$status" -eq 0 ]
  assert_contains "$output" "run: r-pau"
  assert_contains "$output" "workflow: wf-a"
  assert_contains "$output" "lifecycle: paused"
  assert_contains "$output" "updated: 2026-01-01T00:00:02Z"
  assert_contains "$output" "last checkpoint: s2"
  assert_contains "$output" "  1. s1 (skill) - completed"
  assert_contains "$output" "  2. s2 (confirm) - paused [checkpoint]"
  assert_contains "$output" "  s1.path: out.txt"
  assert_contains "$output" "  s1.n: 3"
}

@test "status-render shows none for a run with no checkpoint and no outputs" {
  run --separate-stderr bash "$SCRIPT" status-render r-bare
  [ "$status" -eq 0 ]
  assert_contains "$output" "last checkpoint: none"
  assert_contains "$output" "  none"
  assert_not_contains "$output" "[checkpoint]"
}

@test "status-render without a run id equals runs-render" {
  run --separate-stderr bash "$SCRIPT" runs-render
  expected="$output"
  run --separate-stderr bash "$SCRIPT" status-render
  [ "$status" -eq 0 ]
  [ "$output" = "$expected" ]
}

@test "status-render exits 1 for an unknown run and 2 for any other run-state failure" {
  run --separate-stderr bash "$SCRIPT" status-render no-such-run
  [ "$status" -eq 1 ]
  cat > "$BATS_TEST_TMPDIR/run-state.sh" <<'RUNSTATE'
#!/usr/bin/env bash
exit 6
RUNSTATE
  run --separate-stderr bash "$SCRIPT" status-render r-pau
  [ "$status" -eq 2 ]
}

@test "resolve-definition prints the id of the numbered list-render line" {
  run --separate-stderr bash "$SCRIPT" resolve-definition 1
  [ "$status" -eq 0 ]
  [ "$output" = "alpha" ]
  run --separate-stderr bash "$SCRIPT" resolve-definition 3
  [ "$output" = "gamma" ]
}

@test "resolve-definition rejects 0, past-the-end and non-numeric input with the range on stderr" {
  for bad in 0 4 abc -1 1.5; do
    run --separate-stderr bash "$SCRIPT" resolve-definition "$bad"
    [ "$status" -eq 1 ]
    [ -z "$output" ]
    assert_contains "$stderr" "valid range is 1-3"
  done
}

@test "resolve-definition on an empty catalog exits 1 saying the list is empty" {
  export LOADER_JSON='[]'
  run --separate-stderr bash "$SCRIPT" resolve-definition 1
  [ "$status" -eq 1 ]
  assert_contains "$stderr" "the list is empty"
}

@test "resolve-run prints the run id of the numbered runs-render line" {
  run --separate-stderr bash "$SCRIPT" resolve-run 4
  [ "$status" -eq 0 ]
  [ "$output" = "r-await" ]
}

@test "resolve-run --resumable numbers within the resumable list" {
  run --separate-stderr bash "$SCRIPT" resolve-run 3 --resumable
  [ "$status" -eq 0 ]
  [ "$output" = "r-fail" ]
  run --separate-stderr bash "$SCRIPT" resolve-run 4 --resumable
  [ "$status" -eq 1 ]
  assert_contains "$stderr" "valid range is 1-3"
}

@test "resolve-run rejects 0, past-the-end and non-numeric input with the range on stderr" {
  for bad in 0 7 x; do
    run --separate-stderr bash "$SCRIPT" resolve-run "$bad"
    [ "$status" -eq 1 ]
    assert_contains "$stderr" "valid range is 1-6"
  done
}

@test "usage errors exit 2: unknown subcommand, wrong argument counts, bad flag" {
  for args in "" "bogus" "list-render extra" "resolve-definition" "resolve-run" "resolve-run 1 --nope" "status-render a b"; do
    # shellcheck disable=SC2086
    run --separate-stderr bash "$SCRIPT" $args
    [ "$status" -eq 2 ]
  done
}

@test "read-only: only the list and status subcommands of run-state are ever invoked" {
  bash "$SCRIPT" runs-render >/dev/null
  bash "$SCRIPT" resumable >/dev/null
  bash "$SCRIPT" status-render r-pau >/dev/null
  bash "$SCRIPT" resolve-run 2 >/dev/null
  verbs="$(awk '{print $1}' "$RS_LOG" | sort -u | tr '\n' ' ')"
  [ "$verbs" = "list status " ]
}

@test "structural: bash -n passes and no state-path move or project-path literal appears on code lines" {
  bash -n "$SCRIPT"
  code="$(grep -v '^[[:space:]]*#' "$SCRIPT")"
  needle="proj""ect/"
  assert_not_contains "$code" "$needle"
  ! printf '%s\n' "$code" | grep -Eq '(^|[^[:alnum:]_])mv[[:space:]]'
}
