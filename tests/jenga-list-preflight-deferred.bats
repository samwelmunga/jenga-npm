#!/usr/bin/env bats
#
# Coverage for skills/jenga/scripts/list-preflight-deferred.sh (E67_S03_T06) -- the deterministic
# extraction of `preflight_deferred` item ids that /jenga Phase 4 uses as a run-scoped exclusion set.
#
# Fixture, not the live repo: every test points the script at its own events file through the
# JENGA_PREFLIGHT_EVENTS_FILE seam (or a synthetic project root), never this repository's own
# project/logs/events.json.

load helpers/assertions

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
SCRIPT="$REPO_ROOT/skills/jenga/scripts/list-preflight-deferred.sh"
SID="dooo-20261003T155840Z"

setup() {
  EVENTS="$BATS_TEST_TMPDIR/events.json"
  export JENGA_PREFLIGHT_EVENTS_FILE="$EVENTS"
}

teardown() {
  unset JENGA_PREFLIGHT_EVENTS_FILE JENGA_PROJECT_ROOT
}

# Writes one preflight_deferred event object to stdout. $1 = session id, $2 = item id
ev() {
  printf '{"event":"preflight_deferred","agent":"orchestrator","session_id":"%s","item_id":"%s","phase":"pre-task","run_id":"do-1-x","items":["a"],"date":"2026-10-03T00:00:00Z"}' "$1" "$2"
}

@test "prints the item_id of a matching event and nothing else" {
  printf '[%s]\n' "$(ev "$SID" E67_S03_T06)" > "$EVENTS"
  run "$SCRIPT" "$SID"
  [ "$status" -eq 0 ]
  [ "$output" = "E67_S03_T06" ]
}

@test "prints several distinct ids one per line in first-seen order" {
  printf '[%s,%s,%s]\n' "$(ev "$SID" E67_S03_T02)" "$(ev "$SID" E67_S04)" "$(ev "$SID" E67_S03_T01)" > "$EVENTS"
  run "$SCRIPT" "$SID"
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "E67_S03_T02" ]
  [ "${lines[1]}" = "E67_S04" ]
  [ "${lines[2]}" = "E67_S03_T01" ]
  [ "${#lines[@]}" -eq 3 ]
}

@test "de-duplicates an id deferred more than once" {
  printf '[%s,%s,%s]\n' "$(ev "$SID" E67_S03_T02)" "$(ev "$SID" E67_S03_T05)" "$(ev "$SID" E67_S03_T02)" > "$EVENTS"
  run "$SCRIPT" "$SID"
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 2 ]
  [ "${lines[0]}" = "E67_S03_T02" ]
  [ "${lines[1]}" = "E67_S03_T05" ]
}

@test "never returns another session's deferrals" {
  printf '[%s,%s]\n' "$(ev other-session E67_S01_T01)" "$(ev "$SID" E67_S02_T02)" > "$EVENTS"
  run "$SCRIPT" "$SID"
  [ "$status" -eq 0 ]
  [ "$output" = "E67_S02_T02" ]
}

@test "session id is matched exactly, not as a prefix or substring" {
  printf '[%s,%s]\n' "$(ev "${SID}-2" E67_S01_T01)" "$(ev "x${SID}" E67_S01_T02)" > "$EVENTS"
  run "$SCRIPT" "$SID"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "never returns other event types, including capacity_blocked" {
  cat > "$EVENTS" <<JSON
[
  {"event":"capacity_blocked","agent":"orchestrator","session_id":"$SID","item_id":"E67_S01_T01"},
  {"event":"session_start","agent":"developer","session_id":"$SID","item_id":"E67_S01_T02"},
  {"event":"preflight_deferred_other","session_id":"$SID","item_id":"E67_S01_T03"},
  $(ev "$SID" E67_S01_T04)
]
JSON
  run "$SCRIPT" "$SID"
  [ "$status" -eq 0 ]
  [ "$output" = "E67_S01_T04" ]
}

@test "interleaved noise (other sessions, other types) around matches is filtered correctly" {
  printf '[{"event":"x"},%s,{"sender":{"agent":"a"}},%s,{"event":"capacity_blocked","session_id":"%s","item_id":"E1_S1_T1"},%s]\n' \
    "$(ev "$SID" E67_S03_T02)" "$(ev other E67_S09_T09)" "$SID" "$(ev "$SID" E67_S03_T02)" > "$EVENTS"
  run "$SCRIPT" "$SID"
  [ "$status" -eq 0 ]
  [ "$output" = "E67_S03_T02" ]
}

@test "no matching events prints nothing and exits 0" {
  printf '[%s]\n' "$(ev other E67_S01_T01)" > "$EVENTS"
  run "$SCRIPT" "$SID"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "an empty array prints nothing and exits 0" {
  printf '[]\n' > "$EVENTS"
  run "$SCRIPT" "$SID"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "a missing events file prints nothing and exits 0" {
  rm -f "$EVENTS"
  run "$SCRIPT" "$SID"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "a zero-byte or whitespace-only events file prints nothing and exits 0" {
  : > "$EVENTS"
  run "$SCRIPT" "$SID"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  printf '  \n\n' > "$EVENTS"
  run "$SCRIPT" "$SID"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "malformed JSON exits non-zero with a specific message and no traceback" {
  printf '[{"event": "preflight_deferred", ' > "$EVENTS"
  run "$SCRIPT" "$SID"
  [ "$status" -eq 1 ]
  assert_output_contains "malformed"
  assert_output_contains "$EVENTS"
  assert_output_not_contains "Traceback"
}

@test "valid JSON that is not an array exits non-zero with a specific message" {
  printf '{"event":"preflight_deferred","session_id":"%s","item_id":"E1_S1_T1"}\n' "$SID" > "$EVENTS"
  run "$SCRIPT" "$SID"
  [ "$status" -eq 1 ]
  assert_output_contains "expected a JSON array"
  assert_output_not_contains "Traceback"
}

@test "a non-UTF-8 events file is reported as malformed, not a traceback" {
  printf '[\xff\xfe]' > "$EVENTS"
  run "$SCRIPT" "$SID"
  [ "$status" -eq 1 ]
  assert_output_contains "malformed"
  assert_output_not_contains "Traceback"
}

@test "an unreadable events path (a directory) exits 5 without a traceback" {
  rm -f "$EVENTS"
  mkdir "$EVENTS"
  run "$SCRIPT" "$SID"
  [ "$status" -eq 5 ]
  assert_output_contains "cannot read"
  assert_output_not_contains "Traceback"
}

@test "tolerates non-object entries and events missing fields" {
  printf '[1,"str",null,[],{"event":"preflight_deferred"},{"event":"preflight_deferred","session_id":"%s"},{"event":"preflight_deferred","session_id":"%s","item_id":null},{"event":"preflight_deferred","session_id":"%s","item_id":42},%s]\n' \
    "$SID" "$SID" "$SID" "$(ev "$SID" E67_S03_T06)" > "$EVENTS"
  run "$SCRIPT" "$SID"
  [ "$status" -eq 0 ]
  [ "$output" = "E67_S03_T06" ]
}

@test "an item_id that is not a plain id cannot inject extra output lines" {
  cat > "$EVENTS" <<JSON
[
  {"event":"preflight_deferred","session_id":"$SID","item_id":"E1_S1_T1\nE9_S9_T9"},
  {"event":"preflight_deferred","session_id":"$SID","item_id":"has space"},
  {"event":"preflight_deferred","session_id":"$SID","item_id":""},
  $(ev "$SID" E67_S03_T06)
]
JSON
  run "$SCRIPT" "$SID"
  [ "$status" -eq 0 ]
  [ "$output" = "E67_S03_T06" ]
}

@test "copes with a large events file" {
  python3 - "$EVENTS" "$SID" <<'PY'
import json, sys
path, sid = sys.argv[1], sys.argv[2]
events = []
for i in range(60000):
    events.append({"event": "task_status_set", "session_id": "s%d" % (i % 7), "item_id": "E1_S1_T%d" % i, "note": "x" * 40})
events.insert(30000, {"event": "preflight_deferred", "session_id": sid, "item_id": "E67_S03_T06"})
events.append({"event": "preflight_deferred", "session_id": sid, "item_id": "E67_S03_T06"})
events.append({"event": "preflight_deferred", "session_id": sid, "item_id": "E67_S04"})
json.dump(events, open(path, "w"))
PY
  run "$SCRIPT" "$SID"
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 2 ]
  [ "${lines[0]}" = "E67_S03_T06" ]
  [ "${lines[1]}" = "E67_S04" ]
}

@test "a missing argument is a usage error (exit 2)" {
  run "$SCRIPT"
  [ "$status" -eq 2 ]
  assert_output_contains "usage"
}

@test "an empty argument is a usage error (exit 2)" {
  run "$SCRIPT" ""
  [ "$status" -eq 2 ]
}

@test "an extra argument is a usage error (exit 2)" {
  run "$SCRIPT" "$SID" extra
  [ "$status" -eq 2 ]
}

@test "without the override seam it resolves the logs path via resolve-root.sh, not a hardcoded project/" {
  unset JENGA_PREFLIGHT_EVENTS_FILE
  local root="$BATS_TEST_TMPDIR/consumer"
  mkdir -p "$root/project/configs" "$root/custom-logs"
  # A registry that relocates the logs directory proves the path comes from the resolver.
  python3 - "$REPO_ROOT/project/configs/workflow.json" "$root/project/configs/workflow.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
d["paths"]["logs"] = "custom-logs"
json.dump(d, open(sys.argv[2], "w"))
PY
  printf '[%s]\n' "$(ev "$SID" E67_S03_T06)" > "$root/custom-logs/events.json"
  export JENGA_PROJECT_ROOT="$root"
  run "$SCRIPT" "$SID"
  [ "$status" -eq 0 ]
  [ "$output" = "E67_S03_T06" ]
}

@test "without the override seam and with no events log under the resolved root it prints nothing" {
  unset JENGA_PREFLIGHT_EVENTS_FILE
  local root="$BATS_TEST_TMPDIR/empty-consumer"
  mkdir -p "$root/project/configs"
  cp "$REPO_ROOT/project/configs/workflow.json" "$root/project/configs/workflow.json"
  export JENGA_PROJECT_ROOT="$root"
  run "$SCRIPT" "$SID"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}
