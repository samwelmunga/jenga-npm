#!/usr/bin/env bats
# bats file_tags=tier:integration
#
# Coverage for the known-red baseline and the slowness line of skills/j-test/scripts/scope-test-gate.sh (E89_S06_T10).
#
# A failing run is downgraded to "satisfied with known-red" only when every failed suite failed solely on cases listed,
# by exact file and exact case name, in the baseline. This suite pins: a baselined failure alone is exit 0 and is never
# reported as a pass; a deliberate regression (a case not in the baseline) still exits 1, alone and mixed with a
# baselined one; a failed suite with no parseable case (non-bats) still exits 1; a missing or malformed baseline
# changes nothing; the slowness note is a separate line that never changes the verdict; and --json carries the keys.
#
# The suite commands print TAP lines of their own, so no real bats run is needed. discover-tests.sh is a stub.

# shellcheck disable=SC2016,SC2030,SC2031

bats_require_minimum_version 1.5.0

load helpers/assertions

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd -P)"
BASH_BIN="$(command -v bash)"

setup() {
  export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null GIT_CONFIG_NOSYSTEM=1
  unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE JENGA_PROJECT_ROOT
  export TMPDIR="$BATS_TEST_TMPDIR/tmp"
  mkdir -p "$TMPDIR"

  PKG="$BATS_TEST_TMPDIR/pkg"
  GATE="$PKG/skills/j-test/scripts/scope-test-gate.sh"
  mkdir -p "$PKG/skills/j-test/scripts/lib" "$PKG/scripts" "$PKG/templates/permission-levels"
  cp "$REPO_ROOT"/skills/j-test/scripts/*.sh "$PKG/skills/j-test/scripts/"
  cp -R "$REPO_ROOT"/skills/j-test/scripts/lib/. "$PKG/skills/j-test/scripts/lib/"
  cp "$REPO_ROOT/scripts/resolve-root.sh" "$PKG/scripts/"
  cp "$REPO_ROOT/templates/test-scope-map.json" "$PKG/templates/"
  cp "$REPO_ROOT/templates/permission-levels/level-2-guarded.json" "$PKG/templates/permission-levels/"
  cat > "$PKG/skills/j-test/scripts/discover-tests.sh" <<'STUB'
#!/usr/bin/env bash
cat "$DISC_STUB_JSON"
STUB

  REPO="$BATS_TEST_TMPDIR/proj"
  mkdir -p "$REPO/project/configs" "$REPO/one" "$REPO/two"
  git -C "$REPO" init -q
  git -C "$REPO" config user.name F
  git -C "$REPO" config user.email f@example.invalid
  git -C "$REPO" config commit.gpgsign false
  mkdir -p "$REPO/src/one" "$REPO/src/two"
  printf 'x\n' > "$REPO/src/one/a.sh"; printf 'x\n' > "$REPO/src/two/b.sh"
  printf 'x\n' > "$REPO/one/a.bats"; printf 'x\n' > "$REPO/two/b.bats"
  git -C "$REPO" add -A && git -C "$REPO" commit -q -m seed
  printf 'y\n' >> "$REPO/src/one/a.sh"
  git -C "$REPO" add -A && git -C "$REPO" commit -q -m "task(E98_S01_T01): change"
  printf '{}' > "$REPO/project/configs/workflow.json"
  printf '%s' '{"map_version":1,"rules":[{"source":"src/one/*.sh","tests":["one/*.bats"]},{"source":"src/two/*.sh","tests":["two/*.bats"]}]}' > "$REPO/project/scope-map.json"
  printf '%s' '{"commit_scope_map_file":"project/scope-map.json","test_run_task":"scoped","test_default_suite_set":"two/*.bats"}' > "$REPO/project/configs/test-config.json"

  # Two suites. "one" prints the TAP that SUITE_ONE_TAP names; "two" is a plain suite that passes.
  DISC_STUB_JSON="$BATS_TEST_TMPDIR/discovery.json"
  export DISC_STUB_JSON
  jq -n '{"suites":[
    {"id":"s:one","name":"one tests","type":"unit","ecosystem":"bats","command":"cat \"$TAP_FILE\"; exit $TAP_RC","paths":["one/*.bats"]},
    {"id":"s:two","name":"two tests","type":"unit","ecosystem":"bats","command":"true","paths":["two/*.bats"]}],"warnings":[]}' > "$DISC_STUB_JSON"
  TAP_FILE="$BATS_TEST_TMPDIR/tap"
  export TAP_FILE TAP_RC=1

  BASELINE="$BATS_TEST_TMPDIR/known-red.json"
  put_baseline '[{"file":"one/a.bats","case":"known broken case"}]'
}

put_baseline() { printf '{"version":1,"cases":%s}' "$1" > "$BASELINE"; }

tap_fail() {  # tap_fail <file> <case> ...: one `not ok` per pair, then an ok
  : > "$TAP_FILE"
  local n=1
  while [ "$#" -ge 2 ]; do
    printf 'not ok %d %s\n# (in test file %s, line 9)\n#   `false'"'"' failed\n' "$n" "$2" "$1" >> "$TAP_FILE"
    n=$((n + 1)); shift 2
  done
  printf 'ok %d fine\n' "$n" >> "$TAP_FILE"
}

gate() { run --separate-stderr "$BASH_BIN" "$GATE" --root "$REPO" --scope task --id E98_S01_T01 --known-red "$BASELINE" "$@"; }

@test "a failure that is only a baselined case is satisfied with known-red, exit 0, and is never worded as a pass" {
  tap_fail one/a.bats "known broken case"
  gate
  [ "$status" -eq 0 ]
  assert_output_contains "known-red cases failed"
  assert_output_contains "one/a.bats: known broken case"
  assert_output_contains "scope test gate: satisfied with known-red"
  assert_output_contains "are NOT passes"
}

@test "a deliberate regression that is not in the baseline still blocks closure (exit 1)" {
  tap_fail one/a.bats "a brand new regression"
  gate
  [ "$status" -eq 1 ]
  assert_output_contains "failing cases NOT in the known-red baseline"
  assert_output_contains "one/a.bats: a brand new regression"
  assert_output_contains "scope test gate: FAILED"
}

@test "a baselined case failing next to a new regression still blocks closure (exit 1) and names only the new one as blocking" {
  tap_fail one/a.bats "known broken case" one/a.bats "a brand new regression"
  gate
  [ "$status" -eq 1 ]
  assert_output_contains "scope test gate: FAILED"
  [[ "$output" == *"NOT in the known-red baseline"*"a brand new regression"* ]]
}

@test "the baseline matches on the exact file: the same case name in another file is a regression" {
  tap_fail two/b.bats "known broken case"
  gate
  [ "$status" -eq 1 ]
}

@test "the baseline matches on the exact case name: a renamed case is a regression" {
  tap_fail one/a.bats "known broken case (renamed)"
  gate
  [ "$status" -eq 1 ]
}

@test "a failed suite that printed no parseable failing case is never baselined (exit 1)" {
  printf 'boom, no tap here\n' > "$TAP_FILE"
  gate
  [ "$status" -eq 1 ]
  assert_output_contains "scope test gate: FAILED"
}

@test "with no baseline file the gate behaves as before: a failure is exit 1" {
  tap_fail one/a.bats "known broken case"
  rm -f "$BASELINE"
  gate
  [ "$status" -eq 1 ]
  assert_output_contains "scope test gate: FAILED"
}

@test "a malformed baseline is ignored with a warning and the failure stays exit 1" {
  tap_fail one/a.bats "known broken case"
  printf 'not json' > "$BASELINE"
  gate
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"malformed"* ]]
}

@test "a passing run is unaffected by the baseline" {
  TAP_RC=0
  printf 'ok 1 fine\n' > "$TAP_FILE"
  export TAP_RC
  gate
  [ "$status" -eq 0 ]
  assert_output_contains "scope test gate: satisfied ("
}

@test "--json reports the known-red and the new failures, and slow_machine false" {
  tap_fail one/a.bats "known broken case"
  gate --json
  [ "$status" -eq 0 ]
  printf '%s' "$output" | jq -e '.exit_code == 0 and .failed == 1
    and (.known_red_failures == [{file:"one/a.bats", case:"known broken case"}])
    and (.new_failures == []) and (.slow_machine == false)' > /dev/null
}

@test "--json on a regression lists it under new_failures with exit_code 1" {
  tap_fail one/a.bats "a brand new regression"
  gate --json
  [ "$status" -eq 1 ]
  printf '%s' "$output" | jq -e '.exit_code == 1 and (.new_failures == [{file:"one/a.bats", case:"a brand new regression"}]) and (.known_red_failures == [])' > /dev/null
}

@test "the slowness note is a separate environment line and does not change a failing verdict" {
  tap_fail one/a.bats "a brand new regression"
  printf 'Note: the slowness probe found this machine slow before the run; wall-clock durations in this run are not a measure of the tests.\n' >> "$TAP_FILE"
  gate --json
  [ "$status" -eq 1 ]
  printf '%s' "$output" | jq -e '.slow_machine == true and .exit_code == 1' > /dev/null
  [[ "$stderr" == *"environment: the slowness probe found this machine slow"* ]]
}

@test "the slowness line is reported next to a known-red pass too, and is not mixed into the failure list" {
  tap_fail one/a.bats "known broken case"
  printf 'Note: the slowness probe found this machine slow before the run; wall-clock durations in this run are not a measure of the tests.\n' >> "$TAP_FILE"
  gate
  [ "$status" -eq 0 ]
  assert_output_contains "environment: the slowness probe found this machine slow"
  assert_output_contains "satisfied with known-red"
}

@test "the real baseline file is valid and records tests/perceived-branch.bats case 24" {
  jq -e '.version == 1 and any(.cases[]; .file == "tests/perceived-branch.bats"
         and (.case | startswith("the hook with no session key at all")) and (.reason | length > 0) and (.follow_up | length > 0))' \
    "$REPO_ROOT/project/configs/test-known-red.json" > /dev/null
}
