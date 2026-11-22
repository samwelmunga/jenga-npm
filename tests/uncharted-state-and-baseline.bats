#!/usr/bin/env bats
# bats file_tags=tier:integration
#
# Coverage for the uncharted state, baseline and validation scripts under skills/j-uncharted/scripts/ (E43_S01_T02):
#
#   elicitation-state.sh   find-scan-baseline.sh   diff-since-baseline.sh   validate-proposed-items.sh
#
# These scripts anchor their state on THEIR OWN repository (elicitation-state.sh writes <repo>/project/queue/elicitation-state/,
# diff-since-baseline.sh resolves baseline_commit in the script's own git history), so every test runs a copy inside the sandbox
# repo built by tests/helpers/uncharted.bash. Nothing here can reach the live project/queue/, project/board/ or
# project/logs/events.json.
#
# The refresh pipeline is covered in its documented stdin forms: write-scan-record.sh -> find-scan-baseline.sh ->
# diff-since-baseline.sh, with the baseline arriving on stdin and the fresh report supplied through --fresh (file and stdin).
#
# Fixtures: tests/fixtures/uncharted-validate/board (six board files and expected.json: the exit code each must produce).
# Rule 2 (project/documentation/bats-fixture-convention.md): a mode flag (--fresh, --analysis-dir, --board-dir, --json) is named in
# the tests that use it.

bats_require_minimum_version 1.5.0

load helpers/assertions
load helpers/uncharted

VALIDATE_FIXTURES="$UNCHARTED_FIXTURES/uncharted-validate/board"

setup() {
  uncharted_sandbox
  STATE="$SCRIPTS/elicitation-state.sh"
  FIND="$SCRIPTS/find-scan-baseline.sh"
  DIFF="$SCRIPTS/diff-since-baseline.sh"
  VALIDATE="$SCRIPTS/validate-proposed-items.sh"
  RECORD="$SCRIPTS/write-scan-record.sh"
  STATE_DIR="$SB/project/queue/elicitation-state"
}

# make_history: a baseline commit and a later commit in the sandbox. alpha changes after the baseline, beta does not, gamma appears.
# Sets BASE (the baseline commit's short sha).
make_history() {
  mkdir -p "$SB/alpha" "$SB/beta"
  printf 'a\n' >"$SB/alpha/f.txt"
  printf 'b\n' >"$SB/beta/f.txt"
  ( cd "$SB" && git add -A && git commit -q -m baseline ) >/dev/null
  BASE="$(git -C "$SB" rev-parse --short HEAD)"
  printf 'a2\n' >>"$SB/alpha/f.txt"
  mkdir -p "$SB/gamma"
  printf 'g\n' >"$SB/gamma/f.txt"
  ( cd "$SB" && git add -A && git commit -q -m later ) >/dev/null
}

# baseline_json <commit> <file>: a find-scan-baseline.sh Tier 1 result naming alpha, beta and delta.
baseline_json() {
  jq -n --arg c "$1" '{source: "scan-record", root: ".", baseline_commit: $c, scanned_at: "2026-01-01T00:00:00Z",
    candidates: [{path: "alpha", files: 1, lines: 1}, {path: "beta", files: 1, lines: 1}, {path: "delta", files: 1, lines: 1}]}' >"$2"
}

# fresh_json <file>: a discover-subsystems.sh-shaped report naming alpha, beta and gamma.
fresh_json() {
  jq -n '{script: "discover-subsystems.sh", version: 1, root: ".",
    candidates: [{rank: 1, path: "alpha", files: 1, lines: 2}, {rank: 2, path: "beta", files: 1, lines: 1}, {rank: 3, path: "gamma", files: 1, lines: 1}]}' >"$1"
}

@test "every case directory under tests/fixtures/uncharted-validate has an expected.json" {
  local dir
  for dir in "$UNCHARTED_FIXTURES"/uncharted-validate/*/; do
    [ -f "$dir/expected.json" ] || { echo "missing expected.json in $dir"; return 1; }
  done
}

# ---------------------------------------------------------------------------------------------------------------------
# elicitation-state.sh
# ---------------------------------------------------------------------------------------------------------------------

@test "elicitation-state.sh init creates the state file in the script's own repo, and a second init does not overwrite it" {
  run --separate-stderr bash "$STATE" init --id t1 --target . --cap 2 </dev/null
  [ "$status" -eq 0 ]
  run jq -e '.created == true and .state.status == "in_progress" and .state.cap == 2' <<<"$output"
  [ "$status" -eq 0 ]
  [ -f "$STATE_DIR/t1.json" ]
  bash "$STATE" turn --id t1 --node n1 </dev/null >/dev/null
  run --separate-stderr bash "$STATE" init --id t1 --target . --cap 9 </dev/null
  [ "$status" -eq 0 ]
  run jq -e '.created == false' <<<"$output"
  [ "$status" -eq 0 ]
  # the second init did not reset the turn count or the cap
  run jq -e '.nodes.n1.turns == 1 and .cap == 2' "$STATE_DIR/t1.json"
  [ "$status" -eq 0 ]
}

@test "elicitation-state.sh turn counts up and exits 3 at the cap, with the increment persisted (a signal, not a failure)" {
  bash "$STATE" init --id t1 --target . --cap 2 </dev/null >/dev/null
  run --separate-stderr bash "$STATE" turn --id t1 --node n1 </dev/null
  [ "$status" -eq 0 ]
  run jq -e '.turns == 1 and .cap_reached == false' <<<"$output"
  [ "$status" -eq 0 ]
  run --separate-stderr bash "$STATE" turn --id t1 --node n1 </dev/null
  [ "$status" -eq 3 ]
  run jq -e '.turns == 2 and .cap_reached == true' <<<"$output"
  [ "$status" -eq 0 ]
  run jq -e '.nodes.n1.turns == 2' "$STATE_DIR/t1.json"
  [ "$status" -eq 0 ]
}

@test "elicitation-state.sh converge marks the node converged with its note, and does so before any cap is hit" {
  bash "$STATE" init --id t1 --target . --cap 5 </dev/null >/dev/null
  run --separate-stderr bash "$STATE" converge --id t1 --node billing --note "confirmed" </dev/null
  [ "$status" -eq 0 ]
  run jq -e '.nodes.billing.status == "converged" and .nodes.billing.note == "confirmed"' "$STATE_DIR/t1.json"
  [ "$status" -eq 0 ]
}

@test "elicitation-state.sh checkpoint --json - reads the object from stdin, and a second call merges one level deep instead of clobbering" {
  bash "$STATE" init --id t1 --target . </dev/null >/dev/null
  run --separate-stderr bash -c 'printf "{\"depth\":{\"a\":1},\"plain\":\"x\"}" | bash "$1" checkpoint --id t1 --json -' _ "$STATE"
  [ "$status" -eq 0 ]
  run --separate-stderr bash -c 'printf "{\"depth\":{\"b\":2},\"plain\":\"y\"}" | bash "$1" checkpoint --id t1 --json -' _ "$STATE"
  [ "$status" -eq 0 ]
  run jq -c '.checkpoint' "$STATE_DIR/t1.json"
  [ "$output" = '{"depth":{"a":1,"b":2},"plain":"y"}' ]
}

@test "elicitation-state.sh checkpoint --json <file> reads the object from a file" {
  bash "$STATE" init --id t1 --target . </dev/null >/dev/null
  printf '{"k": 1}\n' >"$BATS_TEST_TMPDIR/cp.json"
  run --separate-stderr bash "$STATE" checkpoint --id t1 --json "$BATS_TEST_TMPDIR/cp.json" </dev/null
  [ "$status" -eq 0 ]
  run jq -c '.checkpoint' "$STATE_DIR/t1.json"
  [ "$output" = '{"k":1}' ]
}

@test "elicitation-state.sh pause then list-paused reports the paused state, and complete removes it from that list" {
  bash "$STATE" init --id t1 --target . </dev/null >/dev/null
  bash "$STATE" pause --id t1 </dev/null >/dev/null
  run --separate-stderr bash "$STATE" list-paused </dev/null
  [ "$status" -eq 0 ]
  run jq -e 'length == 1 and .[0].id == "t1"' <<<"$output"
  [ "$status" -eq 0 ]
  run --separate-stderr bash "$STATE" complete --id t1 </dev/null
  [ "$status" -eq 0 ]
  [ -f "$STATE_DIR/t1.json" ]
  run --separate-stderr bash "$STATE" list-paused </dev/null
  [ "$output" = "[]" ]
}

@test "elicitation-state.sh status is read-only: it prints the state and changes nothing" {
  bash "$STATE" init --id t1 --target . </dev/null >/dev/null
  local before
  before="$(cat "$STATE_DIR/t1.json")"
  run --separate-stderr bash "$STATE" status --id t1 </dev/null
  [ "$status" -eq 0 ]
  [ "$(jq -S . <<<"$output")" = "$(jq -S . "$STATE_DIR/t1.json")" ]
  [ "$(cat "$STATE_DIR/t1.json")" = "$before" ]
}

@test "elicitation-state.sh exit codes: 1 usage, 2 missing state or non-object checkpoint input, 4 unwritable state directory" {
  run --separate-stderr bash "$STATE" bogus </dev/null
  [ "$status" -eq 1 ]
  run --separate-stderr bash "$STATE" turn --id t1 </dev/null
  [ "$status" -eq 1 ]
  run --separate-stderr bash "$STATE" status --id no-such-state </dev/null
  [ "$status" -eq 2 ]
  bash "$STATE" init --id t1 --target . </dev/null >/dev/null
  run --separate-stderr bash -c 'printf "[1]" | bash "$1" checkpoint --id t1 --json -' _ "$STATE"
  [ "$status" -eq 2 ]
  chmod 555 "$STATE_DIR"
  run --separate-stderr bash "$STATE" pause --id t1 </dev/null
  chmod 755 "$STATE_DIR"
  [ "$status" -eq 4 ]
}

# ---------------------------------------------------------------------------------------------------------------------
# find-scan-baseline.sh
# ---------------------------------------------------------------------------------------------------------------------

@test "find-scan-baseline.sh Tier 1: finds the scan-record write-scan-record.sh wrote, and tags it scan-record" {
  baseline_json "abc1234" "$BATS_TEST_TMPDIR/seed.json"
  jq '{script: "discover-subsystems.sh", version: 1, root: ".", candidates: [.candidates[] | {rank: 1, path, files, lines}]}' "$BATS_TEST_TMPDIR/seed.json" \
    | bash "$RECORD" --out-dir "$SB/project/rapports/analysis" >/dev/null
  run --separate-stderr bash "$FIND" . </dev/null
  [ "$status" -eq 0 ]
  run jq -e '.source == "scan-record" and .root == "." and (.candidates | length) == 3 and (.baseline_commit | length) > 0' <<<"$output"
  [ "$status" -eq 0 ]
}

@test "find-scan-baseline.sh Tier 2: falls back to board evidence (provenance: backfilled) and tags it inferred, without candidates" {
  mkdir -p "$SB/alpha"
  printf 'a\n' >"$SB/alpha/f.txt"
  printf -- '---\nid: E05\ntitle: Alpha\nstatus: Pending\nprovenance: backfilled\ndocs: ["alpha"]\n---\nbody\n' >"$SB/project/board/epics/E05_alpha.md"
  ( cd "$SB" && git add -A && git commit -q -m board ) >/dev/null
  run --separate-stderr bash "$FIND" alpha </dev/null
  [ "$status" -eq 0 ]
  run jq -e '.source == "inferred" and (has("candidates") | not) and (.inferred_from | length) == 1 and .inferred_from[0].id == "E05"' <<<"$output"
  [ "$status" -eq 0 ]
}

@test "find-scan-baseline.sh exit 3 (no baseline) is distinct from the usage and environment errors" {
  run --separate-stderr bash "$FIND" nothing-here </dev/null
  [ "$status" -eq 3 ]
  [ -z "$output" ]
}

@test "find-scan-baseline.sh exit codes: 0 --help, 1 usage, 2 under --board-dir that does not exist, 4 under --json-out into a missing directory" {
  run --separate-stderr bash "$FIND" --help </dev/null
  [ "$status" -eq 0 ]
  run --separate-stderr bash "$FIND" </dev/null
  [ "$status" -eq 1 ]
  run --separate-stderr bash "$FIND" --no-such-flag . </dev/null
  [ "$status" -eq 1 ]
  run --separate-stderr bash "$FIND" --board-dir "$BATS_TEST_TMPDIR/no-such-board" . </dev/null
  [ "$status" -eq 2 ]
  baseline_json "abc1234" "$BATS_TEST_TMPDIR/seed.json"
  jq '{script: "discover-subsystems.sh", version: 1, root: ".", candidates: [.candidates[] | {rank: 1, path, files, lines}]}' "$BATS_TEST_TMPDIR/seed.json" \
    | bash "$RECORD" --out-dir "$SB/project/rapports/analysis" >/dev/null
  run --separate-stderr bash "$FIND" --json-out "$BATS_TEST_TMPDIR/no-such-dir/out.json" . </dev/null
  [ "$status" -eq 4 ]
}

# ---------------------------------------------------------------------------------------------------------------------
# diff-since-baseline.sh
# ---------------------------------------------------------------------------------------------------------------------

@test "diff-since-baseline.sh Tier 1 under --fresh classifies unchanged, changed, new and removed candidates" {
  make_history
  baseline_json "$BASE" "$BATS_TEST_TMPDIR/base.json"
  fresh_json "$BATS_TEST_TMPDIR/fresh.json"
  run --separate-stderr bash "$DIFF" --fresh "$BATS_TEST_TMPDIR/fresh.json" "$BATS_TEST_TMPDIR/base.json" </dev/null
  [ "$status" -eq 0 ]
  run jq -e '([.unchanged[].path] == ["beta"]) and ([.changed[].path] == ["alpha"]) and ([.new[].path] == ["gamma"])
             and ([.removed[].path] == ["delta"]) and (.changed[0].changed_files == ["alpha/f.txt"])' <<<"$output"
  [ "$status" -eq 0 ]
}

@test "diff-since-baseline.sh invariant: every fresh candidate lands in exactly one of unchanged/changed/new, and the *_count fields match the arrays" {
  make_history
  baseline_json "$BASE" "$BATS_TEST_TMPDIR/base.json"
  fresh_json "$BATS_TEST_TMPDIR/fresh.json"
  run --separate-stderr bash "$DIFF" --fresh "$BATS_TEST_TMPDIR/fresh.json" "$BATS_TEST_TMPDIR/base.json" </dev/null
  [ "$status" -eq 0 ]
  run jq -e --slurpfile f "$BATS_TEST_TMPDIR/fresh.json" '
      ([.unchanged[].path, .changed[].path, .new[].path] | sort) == ([$f[0].candidates[].path] | sort)
      and (.unchanged_count == (.unchanged | length)) and (.changed_count == (.changed | length))
      and (.new_count == (.new | length)) and (.removed_count == (.removed | length))' <<<"$output"
  [ "$status" -eq 0 ]
}

@test "diff-since-baseline.sh reads the baseline from stdin (the find-scan-baseline.sh | diff-since-baseline.sh form), as bare stdin and as '-'" {
  make_history
  baseline_json "$BASE" "$BATS_TEST_TMPDIR/base.json"
  fresh_json "$BATS_TEST_TMPDIR/fresh.json"
  run --separate-stderr bash "$DIFF" --fresh "$BATS_TEST_TMPDIR/fresh.json" "$BATS_TEST_TMPDIR/base.json" </dev/null
  local from_file
  from_file="$(jq -S . <<<"$output")"
  run --separate-stderr bash "$DIFF" --fresh "$BATS_TEST_TMPDIR/fresh.json" <"$BATS_TEST_TMPDIR/base.json"
  [ "$status" -eq 0 ]
  [ "$(jq -S . <<<"$output")" = "$from_file" ]
  run --separate-stderr bash "$DIFF" --fresh "$BATS_TEST_TMPDIR/fresh.json" - <"$BATS_TEST_TMPDIR/base.json"
  [ "$status" -eq 0 ]
  [ "$(jq -S . <<<"$output")" = "$from_file" ]
}

@test "diff-since-baseline.sh under --fresh - reads the fresh report from stdin while the baseline comes from a file" {
  make_history
  baseline_json "$BASE" "$BATS_TEST_TMPDIR/base.json"
  fresh_json "$BATS_TEST_TMPDIR/fresh.json"
  run --separate-stderr bash "$DIFF" --fresh - "$BATS_TEST_TMPDIR/base.json" <"$BATS_TEST_TMPDIR/fresh.json"
  [ "$status" -eq 0 ]
  run jq -e '([.new[].path] == ["gamma"]) and ([.changed[].path] == ["alpha"])' <<<"$output"
  [ "$status" -eq 0 ]
}

@test "diff-since-baseline.sh Tier 2 (inferred baseline) never computes new or removed, and says so" {
  make_history
  jq -n --arg c "$BASE" '{source: "inferred", root: ".", baseline_commit: $c, inferred_from: [{id: "E05"}]}' >"$BATS_TEST_TMPDIR/tier2.json"
  fresh_json "$BATS_TEST_TMPDIR/fresh.json"
  run --separate-stderr bash "$DIFF" --fresh "$BATS_TEST_TMPDIR/fresh.json" "$BATS_TEST_TMPDIR/tier2.json" </dev/null
  [ "$status" -eq 0 ]
  local notice="$stderr" result="$output"
  assert_contains "$notice" "Tier 2"
  run jq -e '.new == [] and .removed == [] and ([.changed[].path] | sort) == ["alpha", "gamma"] and ([.unchanged[].path] == ["beta"])' <<<"$result"
  [ "$status" -eq 0 ]
}

@test "diff-since-baseline.sh exit 1 when both the baseline and --fresh are stdin, and for an unknown flag" {
  run --separate-stderr bash "$DIFF" --fresh - - </dev/null
  [ "$status" -eq 1 ]
  run --separate-stderr bash "$DIFF" --no-such-flag </dev/null
  [ "$status" -eq 1 ]
}

@test "diff-since-baseline.sh exit 2 for a missing baseline, an unrecognised baseline shape, and a baseline_commit not in history" {
  make_history
  fresh_json "$BATS_TEST_TMPDIR/fresh.json"
  run --separate-stderr bash "$DIFF" --fresh "$BATS_TEST_TMPDIR/fresh.json" "$BATS_TEST_TMPDIR/no-such-baseline.json" </dev/null
  [ "$status" -eq 2 ]
  run --separate-stderr bash -c 'printf "{\"x\":1}" | bash "$1" --fresh "$2"' _ "$DIFF" "$BATS_TEST_TMPDIR/fresh.json"
  [ "$status" -eq 2 ]
  baseline_json "deadbeef0000" "$BATS_TEST_TMPDIR/ghost.json"
  run --separate-stderr bash "$DIFF" --fresh "$BATS_TEST_TMPDIR/fresh.json" "$BATS_TEST_TMPDIR/ghost.json" </dev/null
  [ "$status" -eq 2 ]
}

@test "diff-since-baseline.sh never reuses exit 3: a missing baseline is an input error, not 'no baseline found'" {
  fresh_json "$BATS_TEST_TMPDIR/fresh.json"
  run --separate-stderr bash "$DIFF" --fresh "$BATS_TEST_TMPDIR/fresh.json" "$BATS_TEST_TMPDIR/absent.json" </dev/null
  [ "$status" -ne 3 ]
}

# ---------------------------------------------------------------------------------------------------------------------
# validate-proposed-items.sh
# ---------------------------------------------------------------------------------------------------------------------

@test "validate-proposed-items.sh gives the exit code recorded in expected.json for each fixture board file" {
  cd "$VALIDATE_FIXTURES"
  local file expected
  while IFS=$'\t' read -r file expected; do
    run --separate-stderr bash "$VALIDATE" "$file" </dev/null
    [ "$status" -eq "$expected" ] || { echo "$file: expected exit $expected, got $status"; return 1; }
  done < <(jq -r 'to_entries[] | [.key, .value] | @tsv' "$VALIDATE_FIXTURES/expected.json")
}

@test "validate-proposed-items.sh reports EVERY failure across several files, not just the first" {
  cd "$VALIDATE_FIXTURES"
  run --separate-stderr bash "$VALIDATE" bad-status-epic.md story-no-dod.md story-no-acceptance.md story-dod-no-checkbox.md valid-epic.md </dev/null
  [ "$status" -eq 1 ]
  local file
  for file in bad-status-epic.md story-no-dod.md story-no-acceptance.md story-dod-no-checkbox.md; do
    assert_contains "$stderr" "$file"
  done
  # a passing file is not reported as a failure
  assert_not_contains "$stderr" "valid-epic.md —"
}

@test "validate-proposed-items.sh names the story-format defect by validate-story-format.sh exit code (2 acceptance, 3 definition of done, 4 checkboxes)" {
  cd "$VALIDATE_FIXTURES"
  run --separate-stderr bash "$VALIDATE" story-no-acceptance.md </dev/null
  assert_contains "$stderr" "validate-story-format.sh exit 2"
  run --separate-stderr bash "$VALIDATE" story-no-dod.md </dev/null
  assert_contains "$stderr" "validate-story-format.sh exit 3"
  run --separate-stderr bash "$VALIDATE" story-dod-no-checkbox.md </dev/null
  assert_contains "$stderr" "validate-story-format.sh exit 4"
}

@test "validate-proposed-items.sh passes valid files together and never modifies a board file" {
  cd "$VALIDATE_FIXTURES"
  local before
  before="$(cat valid-epic.md valid-story.md | shasum)"
  run --separate-stderr bash "$VALIDATE" valid-epic.md valid-story.md </dev/null
  [ "$status" -eq 0 ]
  assert_contains "$output" "2 board file(s) valid"
  [ "$(cat valid-epic.md valid-story.md | shasum)" = "$before" ]
}

@test "validate-proposed-items.sh exit 1 for a file that does not exist" {
  run --separate-stderr bash "$VALIDATE" "$BATS_TEST_TMPDIR/no-such-file.md" </dev/null
  [ "$status" -eq 1 ]
}

@test "validate-proposed-items.sh exit 2 for no arguments, and when a required validator is missing" {
  run --separate-stderr bash "$VALIDATE" </dev/null
  [ "$status" -eq 2 ]
  rm "$SB/scripts/validate-board.sh"
  run --separate-stderr bash "$VALIDATE" "$VALIDATE_FIXTURES/valid-epic.md" </dev/null
  [ "$status" -eq 2 ]
}
