#!/usr/bin/env bats
# bats file_tags=tier:integration
#
# Coverage for the `/uncharted onboard` subsystem pipeline under skills/j-uncharted/scripts/ (E43_S01_T02):
#
#   discover-subsystems.sh | apply-subsystem-cap.sh | write-backfilled-epics.sh      (and | write-scan-record.sh)
#   directory-triage.sh
#
# The priority assertion is the stdin regression found in E40_S04_T03: a `python3 - <<PY` heredoc occupies python's stdin, so
# an apply-subsystem-cap.sh written that way cannot read the piped report and the documented
# `discover-subsystems.sh | apply-subsystem-cap.sh` form breaks (exit 2, "not valid JSON"). The test named
# "pipeline: discover-subsystems.sh | apply-subsystem-cap.sh ..." runs the REAL pipe and fails if that returns. Its mutation proof
# is in project/documentation/summaries/E43_S01_T02-summary.md.
#
# Conventions (project/documentation/bats-fixture-convention.md)
#   - Rule 1: every candidate set, ranking, count and drop record is asserted on a fixture tree under
#     tests/fixtures/uncharted-subsystems/, copied into $BATS_TEST_TMPDIR (see tests/helpers/uncharted.bash), never on the
#     repository root. Every script runs from a throwaway sandbox repo, so a defaulted output directory lands there.
#   - Rule 2: a genuinely non-default MODE is named in the @test description (--include-framework, --cap N, --rapport, ...).
#     `--root`-style pointing at a fixture is the fixture mechanism, not a mode, and is not named. A @test with no flag in
#     its name measures the default path.
#   - Invariants over instances: kept+dropped == candidates, JSON notices == rendered notices, and so on, wherever a script
#     emits paired or derived output.
#   - Every invocation gets an explicit stdin: `< /dev/null`, or the piped input that is the form under test.

bats_require_minimum_version 1.5.0

load helpers/assertions
load helpers/uncharted

FIXTURE_DIR="$UNCHARTED_FIXTURES/uncharted-subsystems"
FRAMEWORK_DIRS="agents hooks project skills templates"

setup() {
  uncharted_sandbox
  uncharted_tree "$FIXTURE_DIR/app/tree" app git
  APP="$TREE"
  # Ignored and vendored directories are created here, not committed: the repository's own .gitignore would refuse them.
  mkdir -p "$APP/node_modules/leftpad" "$APP/ignored_dir"
  printf 'module.exports = 1;\n' >"$APP/node_modules/leftpad/index.js"
  printf 'junk\n' >"$APP/ignored_dir/junk.js"
  OUT="$BATS_TEST_TMPDIR/cap-out"
  mkdir -p "$OUT"
  DISCOVER="$SCRIPTS/discover-subsystems.sh"
  CAP="$SCRIPTS/apply-subsystem-cap.sh"
  EPICS="$SCRIPTS/write-backfilled-epics.sh"
  RECORD="$SCRIPTS/write-scan-record.sh"
  TRIAGE="$SCRIPTS/directory-triage.sh"
}

# discover_projection: the stable, auditable shape of a discovery report (ranks and scores are checked separately).
discover_projection() {
  jq -S '{
    framework_excluded,
    candidate_paths: ([.candidates[].path] | sort),
    excluded_paths: ([.excluded[].path] | sort),
    containers: ([.containers[] | {path, expanded_into}] | sort_by(.path))
  }'
}

# synthetic_report <count> <file>: a discover-subsystems.sh-shaped report with <count> ranked candidates, for caps at scale.
synthetic_report() {
  jq -n --argjson n "$1" '{
    script: "discover-subsystems.sh", version: 1, root: "big-app", root_absolute: "/nowhere/big-app",
    candidates: [range(1; $n + 1) | {rank: ., path: "mod/m\(.)", absolute_path: "/nowhere/big-app/mod/m\(.)",
                                     score: (100 - .), files: (. + 1), lines: (. * 10)}]
  }' >"$2"
}

# ---------------------------------------------------------------------------------------------------------------------
# Fixture guard
# ---------------------------------------------------------------------------------------------------------------------

@test "every case directory under tests/fixtures/uncharted-subsystems has an expected.json and a tree" {
  local dir count=0
  for dir in "$FIXTURE_DIR"/*/; do
    count=$((count + 1))
    [ -f "$dir/expected.json" ] || { echo "missing expected.json in $dir"; return 1; }
    [ -d "$dir/tree" ] || { echo "missing tree in $dir"; return 1; }
    jq -e . "$dir/expected.json" >/dev/null
  done
  [ "$count" -ge 1 ]
}

@test "the fixture tree is inert: no executable bit, no test construct" {
  run find "$FIXTURE_DIR" -type f -perm -u+x
  [ -z "$output" ]
  run grep -rEl '(@test|def test_|func Test)' "$FIXTURE_DIR"
  [ -z "$output" ]
}

# ---------------------------------------------------------------------------------------------------------------------
# discover-subsystems.sh
# ---------------------------------------------------------------------------------------------------------------------

@test "discover-subsystems.sh on the DEFAULT path (framework excluded) matches expected.json" {
  run --separate-stderr bash "$DISCOVER" "$APP" </dev/null
  [ "$status" -eq 0 ]
  assert_json_equals "$(printf '%s' "$output" | discover_projection)" "$FIXTURE_DIR/app/expected.json"
}

@test "discover-subsystems.sh on the DEFAULT path never lists a Jenga framework directory as a candidate and reports each exclusion" {
  run --separate-stderr bash "$DISCOVER" "$APP" </dev/null
  [ "$status" -eq 0 ]
  local result="$output" dir
  for dir in $FRAMEWORK_DIRS; do
    run jq -e --arg d "$dir" '[.candidates[].path] | index($d) == null' <<<"$result"
    [ "$status" -eq 0 ]
    # Nothing is silently dropped: each framework dir is in "excluded" with the way back in.
    run jq -e --arg d "$dir" '.excluded[] | select(.path == $d) | .reason | contains("--include-framework")' <<<"$result"
    [ "$status" -eq 0 ]
  done
}

@test "discover-subsystems.sh under --include-framework (framework NOT excluded) matches expected-include-framework.json" {
  run --separate-stderr bash "$DISCOVER" --include-framework "$APP" </dev/null
  [ "$status" -eq 0 ]
  assert_json_equals "$(printf '%s' "$output" | discover_projection)" "$FIXTURE_DIR/app/expected-include-framework.json"
}

@test "discover-subsystems.sh under --include-framework lists every framework directory as a candidate and excludes none" {
  run --separate-stderr bash "$DISCOVER" --include-framework "$APP" </dev/null
  [ "$status" -eq 0 ]
  local result="$output" dir
  for dir in $FRAMEWORK_DIRS; do
    run jq -e --arg d "$dir" '[.candidates[].path] | index($d) != null' <<<"$result"
    [ "$status" -eq 0 ]
  done
  run jq -e '.framework_excluded == false and (.excluded | length) == 0' <<<"$result"
  [ "$status" -eq 0 ]
}

@test "discover-subsystems.sh: the default and the --include-framework candidate sets differ by exactly the framework directories" {
  run --separate-stderr bash "$DISCOVER" "$APP" </dev/null
  local default_paths="$output"
  run --separate-stderr bash "$DISCOVER" --include-framework "$APP" </dev/null
  local included_paths="$output"
  run jq -n -r --argjson d "$default_paths" --argjson i "$included_paths" \
    '[($i.candidates | map(.path)) - ($d.candidates | map(.path))] | .[0] | sort | join(" ")'
  [ "$status" -eq 0 ]
  [ "$output" = "agents hooks project skills templates" ]
  # Nothing the default path found may vanish under the flag.
  run jq -n -e --argjson d "$default_paths" --argjson i "$included_paths" \
    '(($d.candidates | map(.path)) - ($i.candidates | map(.path))) | length == 0'
  [ "$status" -eq 0 ]
}

@test "discover-subsystems.sh default path: ranks are 1..N with no gap and candidate_count equals the array length" {
  run --separate-stderr bash "$DISCOVER" "$APP" </dev/null
  [ "$status" -eq 0 ]
  run jq -e '.candidate_count == (.candidates | length) and ([.candidates[].rank] == [range(1; (.candidates | length) + 1)])' <<<"$output"
  [ "$status" -eq 0 ]
}

@test "discover-subsystems.sh default path is deterministic: two runs on an unchanged tree are byte-identical" {
  run --separate-stderr bash "$DISCOVER" "$APP" </dev/null
  local first="$output"
  run --separate-stderr bash "$DISCOVER" "$APP" </dev/null
  [ "$output" = "$first" ]
}

@test "discover-subsystems.sh default path never offers a .gitignore'd directory and ignores a vendored name" {
  run --separate-stderr bash "$DISCOVER" "$APP" </dev/null
  [ "$status" -eq 0 ]
  assert_not_contains "$output" "ignored_dir"
  assert_not_contains "$output" "node_modules"
}

@test "discover-subsystems.sh under --max-depth 1 treats src and services as candidates instead of expanding them" {
  run --separate-stderr bash "$DISCOVER" --max-depth 1 "$APP" </dev/null
  [ "$status" -eq 0 ]
  run jq -r '[.candidates[].path] | sort | join(" ")' <<<"$output"
  [ "$output" = "docs-site services src tools" ]
}

@test "discover-subsystems.sh on an empty root exits 0 with no candidates and an explanatory notice" {
  mkdir -p "$BATS_TEST_TMPDIR/empty-root"
  run --separate-stderr bash "$DISCOVER" "$BATS_TEST_TMPDIR/empty-root" </dev/null
  [ "$status" -eq 0 ]
  run jq -e '(.candidates | length) == 0 and (.notices | length) >= 1' <<<"$output"
  [ "$status" -eq 0 ]
}

@test "discover-subsystems.sh exit 0 for --help" {
  run --separate-stderr bash "$DISCOVER" --help </dev/null
  [ "$status" -eq 0 ]
  assert_output_contains "Usage:"
}

@test "discover-subsystems.sh exit 1 for a usage error: unknown flag, missing root, extra root, bad numeric value" {
  run --separate-stderr bash "$DISCOVER" --no-such-flag "$APP" </dev/null
  [ "$status" -eq 1 ]
  run --separate-stderr bash "$DISCOVER" </dev/null
  [ "$status" -eq 1 ]
  run --separate-stderr bash "$DISCOVER" "$APP" "$APP" </dev/null
  [ "$status" -eq 1 ]
  run --separate-stderr bash "$DISCOVER" --max-depth 0 "$APP" </dev/null
  [ "$status" -eq 1 ]
  run --separate-stderr bash "$DISCOVER" --max-depth abc "$APP" </dev/null
  [ "$status" -eq 1 ]
}

@test "discover-subsystems.sh exit 2 when the root is missing or is a file" {
  run --separate-stderr bash "$DISCOVER" "$BATS_TEST_TMPDIR/no-such-root" </dev/null
  [ "$status" -eq 2 ]
  run --separate-stderr bash "$DISCOVER" "$APP/README.md" </dev/null
  [ "$status" -eq 2 ]
}

@test "discover-subsystems.sh exit 3 when enumerate-target.sh is missing" {
  rm "$SCRIPTS/enumerate-target.sh"
  run --separate-stderr bash "$DISCOVER" "$APP" </dev/null
  [ "$status" -eq 3 ]
}

# ---------------------------------------------------------------------------------------------------------------------
# apply-subsystem-cap.sh
# ---------------------------------------------------------------------------------------------------------------------

@test "apply-subsystem-cap.sh on the DEFAULT cap (8) with 6 candidates drops nothing, exits 0 and still writes the record" {
  bash "$DISCOVER" "$APP" </dev/null >"$BATS_TEST_TMPDIR/report.json"
  run --separate-stderr bash "$CAP" --out-dir "$OUT" "$BATS_TEST_TMPDIR/report.json" </dev/null
  [ "$status" -eq 0 ]
  run jq -e '.cap == 8 and .capped == false and .dropped == [] and .dropped_count == 0 and .kept_count == 6' <<<"$output"
  [ "$status" -eq 0 ]
  local rapport
  rapport="$(jq -r .rapport <<<"$(bash "$CAP" --out-dir "$OUT" "$BATS_TEST_TMPDIR/report.json" </dev/null 2>/dev/null)")"
  [ -f "$rapport" ]
  assert_contains "$(cat "$rapport")" "Every discovered subsystem is on the board"
}

@test "apply-subsystem-cap.sh under --cap 4 names EVERY dropped subsystem in the JSON and in the rapport, with no elision" {
  bash "$DISCOVER" "$APP" </dev/null >"$BATS_TEST_TMPDIR/report.json"
  run --separate-stderr bash "$CAP" --cap 4 --out-dir "$OUT" "$BATS_TEST_TMPDIR/report.json" </dev/null
  [ "$status" -eq 0 ]
  local result="$output" rapport path n
  rapport="$(jq -r .rapport <<<"$result")"
  [ -f "$rapport" ]
  # invariant: nothing is lost between the discoverer and the cap
  run jq -e '.kept_count + .dropped_count == .candidate_count and .candidate_count == 6 and .capped == true' <<<"$result"
  [ "$status" -eq 0 ]
  run jq -e --slurpfile r "$BATS_TEST_TMPDIR/report.json" \
    '([.kept[].path] + [.dropped[].path]) == [$r[0].candidates[].path]' <<<"$result"
  [ "$status" -eq 0 ]
  n="$(jq '.dropped | length' <<<"$result")"
  [ "$n" -eq 2 ]
  # every dropped entry is named, individually, in the durable record, and carries a reason
  while IFS= read -r path; do
    assert_contains "$(cat "$rapport")" "\`$path\`"
  done < <(jq -r '.dropped[].path' <<<"$result")
  run jq -e 'all(.dropped[]; .reason == "below cap of 4")' <<<"$result"
  [ "$status" -eq 0 ]
  run grep -E '(and|\.\.\.|…) *[0-9]+ more' "$rapport"
  [ "$status" -ne 0 ]
}

@test "apply-subsystem-cap.sh under --cap 8 on a 40-candidate report names all 32 dropped subsystems (no elision at scale)" {
  synthetic_report 40 "$BATS_TEST_TMPDIR/big.json"
  run --separate-stderr bash "$CAP" --cap 8 --out-dir "$OUT" "$BATS_TEST_TMPDIR/big.json" </dev/null
  [ "$status" -eq 0 ]
  local result="$output" rapport named
  rapport="$(jq -r .rapport <<<"$result")"
  run jq -e '.dropped_count == 32 and (.dropped | length) == 32 and .kept_count == 8' <<<"$result"
  [ "$status" -eq 0 ]
  # invariant: the number of dropped subsystem rows rendered in the rapport equals the number in the JSON
  named="$(grep -cE '^\| +[0-9]+ \| +[0-9.]+ \| `mod/m[0-9]+` \|.*below cap of 8 \|$' "$rapport")"
  [ "$named" -eq 32 ]
  local i
  for i in $(seq 9 40); do
    assert_contains "$(cat "$rapport")" "\`mod/m$i\`"
  done
}

@test "apply-subsystem-cap.sh under --cap equal to the candidate count drops nothing; under --cap 1 keeps exactly one" {
  bash "$DISCOVER" "$APP" </dev/null >"$BATS_TEST_TMPDIR/report.json"
  run --separate-stderr bash "$CAP" --cap 6 --out-dir "$OUT" "$BATS_TEST_TMPDIR/report.json" </dev/null
  [ "$status" -eq 0 ]
  run jq -e '.dropped == [] and .capped == false' <<<"$output"
  [ "$status" -eq 0 ]
  run --separate-stderr bash "$CAP" --cap 1 --out-dir "$OUT" "$BATS_TEST_TMPDIR/report.json" </dev/null
  [ "$status" -eq 0 ]
  run jq -e '.kept_count == 1 and .dropped_count == 5 and .kept[0].rank == 1' <<<"$output"
  [ "$status" -eq 0 ]
}

@test "apply-subsystem-cap.sh under --cap 0, --cap -1, --cap=0 and a non-integer --cap is a usage ERROR (exit 1), not an empty run" {
  bash "$DISCOVER" "$APP" </dev/null >"$BATS_TEST_TMPDIR/report.json"
  local bad
  for bad in "--cap 0" "--cap -1" "--cap -50" "--cap=0" "--cap abc" "--cap 1.5"; do
    # shellcheck disable=SC2086
    run --separate-stderr bash "$CAP" $bad --out-dir "$OUT" "$BATS_TEST_TMPDIR/report.json" </dev/null
    [ "$status" -eq 1 ] || { echo "'$bad' exited $status, expected 1"; return 1; }
    # an error, not a no-op: nothing on stdout, and the stderr says why
    [ -z "$output" ] || { echo "'$bad' wrote to stdout"; return 1; }
    assert_contains "$stderr" "--cap"
  done
  # and no record was written for any of them
  run find "$OUT" -type f
  [ -z "$output" ]
}

@test "apply-subsystem-cap.sh exit 1 for an unknown flag, a missing flag value and two input files" {
  run --separate-stderr bash "$CAP" --no-such-flag </dev/null
  [ "$status" -eq 1 ]
  run --separate-stderr bash "$CAP" --cap </dev/null
  [ "$status" -eq 1 ]
  run --separate-stderr bash "$CAP" a.json b.json </dev/null
  [ "$status" -eq 1 ]
}

@test "apply-subsystem-cap.sh exit 0 for --help" {
  run --separate-stderr bash "$CAP" --help </dev/null
  [ "$status" -eq 0 ]
  assert_output_contains "Usage:"
}

@test "apply-subsystem-cap.sh exit 2 for a missing report file, unparseable JSON on stdin, and JSON with no candidates array" {
  run --separate-stderr bash "$CAP" --out-dir "$OUT" "$BATS_TEST_TMPDIR/no-such-report.json" </dev/null
  [ "$status" -eq 2 ]
  run --separate-stderr bash -c 'printf "not json" | bash "$1" --out-dir "$2"' _ "$CAP" "$OUT"
  [ "$status" -eq 2 ]
  run --separate-stderr bash -c 'printf "{}" | bash "$1" --out-dir "$2"' _ "$CAP" "$OUT"
  [ "$status" -eq 2 ]
}

@test "apply-subsystem-cap.sh exit 2 on an EMPTY stdin (nothing piped in is an input error, never a silent empty run)" {
  run --separate-stderr bash "$CAP" --out-dir "$OUT" </dev/null
  [ "$status" -eq 2 ]
}

@test "apply-subsystem-cap.sh exit 4 when --rapport names a document that does not exist, and when --out-dir is a file" {
  bash "$DISCOVER" "$APP" </dev/null >"$BATS_TEST_TMPDIR/report.json"
  run --separate-stderr bash "$CAP" --rapport "$BATS_TEST_TMPDIR/no-such-doc.md" "$BATS_TEST_TMPDIR/report.json" </dev/null
  [ "$status" -eq 4 ]
  : >"$BATS_TEST_TMPDIR/a-file"
  run --separate-stderr bash "$CAP" --out-dir "$BATS_TEST_TMPDIR/a-file" "$BATS_TEST_TMPDIR/report.json" </dev/null
  [ "$status" -eq 4 ]
}

@test "apply-subsystem-cap.sh under --rapport appends to the existing analysis document and keeps its content" {
  bash "$DISCOVER" "$APP" </dev/null >"$BATS_TEST_TMPDIR/report.json"
  printf '# Existing analysis\n\nPre-existing paragraph.\n' >"$BATS_TEST_TMPDIR/analysis.md"
  run --separate-stderr bash "$CAP" --cap 4 --rapport "$BATS_TEST_TMPDIR/analysis.md" "$BATS_TEST_TMPDIR/report.json" </dev/null
  [ "$status" -eq 0 ]
  run jq -e '.rapport_mode == "appended"' <<<"$output"
  [ "$status" -eq 0 ]
  assert_contains "$(cat "$BATS_TEST_TMPDIR/analysis.md")" "Pre-existing paragraph."
  assert_contains "$(cat "$BATS_TEST_TMPDIR/analysis.md")" "## Subsystem Cap"
}

@test "apply-subsystem-cap.sh notices: JSON notices count equals the rendered Notices bullets, and stderr repeats each one (appended twice)" {
  bash "$DISCOVER" "$APP" </dev/null >"$BATS_TEST_TMPDIR/report.json"
  printf '# Existing analysis\n' >"$BATS_TEST_TMPDIR/analysis.md"
  bash "$CAP" --cap 4 --rapport "$BATS_TEST_TMPDIR/analysis.md" "$BATS_TEST_TMPDIR/report.json" </dev/null >/dev/null 2>&1
  # The second run finds an earlier Subsystem Cap section and must say so.
  run --separate-stderr bash "$CAP" --cap 4 --rapport "$BATS_TEST_TMPDIR/analysis.md" "$BATS_TEST_TMPDIR/report.json" </dev/null
  [ "$status" -eq 0 ]
  local json_notices rendered stderr_lines expected_stderr
  json_notices="$(jq '.notices | length' <<<"$output")"
  [ "$json_notices" -ge 1 ]
  # Notices bullets belong to the LAST appended section: count the bullets after its final "### Notices" heading.
  rendered="$(awk '/^### Notices$/{n=0; on=1; next} on && /^- /{n++} on && /^## /{on=0} END{print n+0}' "$BATS_TEST_TMPDIR/analysis.md")"
  [ "$rendered" -eq "$json_notices" ]
  # stderr: one "Notice:" line per JSON notice, plus one for the cap itself when it dropped something.
  stderr_lines="$(printf '%s\n' "$stderr" | grep -c '^Notice:' || true)"
  expected_stderr=$((json_notices + 1))
  [ "$stderr_lines" -eq "$expected_stderr" ]
}

@test "apply-subsystem-cap.sh notices: an out-of-rank-order report yields one JSON notice and one rendered bullet" {
  jq '.candidates |= reverse' <(bash "$DISCOVER" "$APP" </dev/null) >"$BATS_TEST_TMPDIR/shuffled.json"
  run --separate-stderr bash "$CAP" --cap 4 --out-dir "$OUT" "$BATS_TEST_TMPDIR/shuffled.json" </dev/null
  [ "$status" -eq 0 ]
  local result="$output" rapport json_notices rendered
  rapport="$(jq -r .rapport <<<"$result")"
  json_notices="$(jq '.notices | length' <<<"$result")"
  rendered="$(awk '/^### Notices$/{on=1; next} on && /^- /{n++} END{print n+0}' "$rapport")"
  [ "$json_notices" -eq 1 ]
  [ "$rendered" -eq "$json_notices" ]
  # array order wins: the cap sliced the array as delivered
  run jq -e --slurpfile r "$BATS_TEST_TMPDIR/shuffled.json" '[.kept[].path] == [$r[0].candidates[:4][].path]' <<<"$result"
  [ "$status" -eq 0 ]
}

@test "apply-subsystem-cap.sh reads the same report from a file argument, from '-', and from bare stdin (all three stdin/file forms agree)" {
  bash "$DISCOVER" "$APP" </dev/null >"$BATS_TEST_TMPDIR/report.json"
  run --separate-stderr bash "$CAP" --cap 4 --out-dir "$OUT" "$BATS_TEST_TMPDIR/report.json" </dev/null
  local from_file
  from_file="$(jq -S 'del(.rapport)' <<<"$output")"
  run --separate-stderr bash "$CAP" --cap 4 --out-dir "$OUT" - <"$BATS_TEST_TMPDIR/report.json"
  [ "$status" -eq 0 ]
  [ "$(jq -S 'del(.rapport)' <<<"$output")" = "$from_file" ]
  run --separate-stderr bash "$CAP" --cap 4 --out-dir "$OUT" <"$BATS_TEST_TMPDIR/report.json"
  [ "$status" -eq 0 ]
  [ "$(jq -S 'del(.rapport)' <<<"$output")" = "$from_file" ]
}

@test "apply-subsystem-cap.sh under --json-out writes the same JSON it prints" {
  bash "$DISCOVER" "$APP" </dev/null >"$BATS_TEST_TMPDIR/report.json"
  run --separate-stderr bash "$CAP" --cap 4 --out-dir "$OUT" --json-out "$BATS_TEST_TMPDIR/cap.json" "$BATS_TEST_TMPDIR/report.json" </dev/null
  [ "$status" -eq 0 ]
  [ "$(jq -S . "$BATS_TEST_TMPDIR/cap.json")" = "$(jq -S . <<<"$output")" ]
}

# ---------------------------------------------------------------------------------------------------------------------
# The pipeline forms, including the python3 stdin-consumption regression (E40_S04_T03)
# ---------------------------------------------------------------------------------------------------------------------

@test "pipeline: discover-subsystems.sh | apply-subsystem-cap.sh reads the piped report (python3 - <<PY stdin-consumption regression)" {
  run --separate-stderr bash -c 'set -o pipefail; bash "$1" "$2" | bash "$3" --cap 4 --out-dir "$4"' \
    _ "$DISCOVER" "$APP" "$CAP" "$OUT"
  # A heredoc-fed python reads an empty stdin: apply-subsystem-cap.sh then exits 2 ("not valid JSON") with nothing on stdout.
  [ "$status" -eq 0 ]
  # Not merely exit 0: the piped report was actually consumed, candidate for candidate.
  run jq -e '.candidate_count == 6 and .kept_count == 4 and .dropped_count == 2' <<<"$output"
  [ "$status" -eq 0 ]
  [ "$(ls "$OUT" | wc -l | tr -d ' ')" -eq 1 ]
}

@test "pipeline: discover-subsystems.sh | apply-subsystem-cap.sh under --include-framework consumes the larger piped report too" {
  run --separate-stderr bash -c 'set -o pipefail; bash "$1" --include-framework "$2" | bash "$3" --cap 8 --out-dir "$4"' \
    _ "$DISCOVER" "$APP" "$CAP" "$OUT"
  [ "$status" -eq 0 ]
  # 11 candidates under --include-framework against the default cap of 8: three drops
  run jq -e '.candidate_count == 11 and .kept_count == 8 and .dropped_count == 3' <<<"$output"
  [ "$status" -eq 0 ]
}

@test "pipeline: the cap's stdin form feeds from the real discoverer and from a file identically (invariant over the two producers)" {
  bash "$DISCOVER" "$APP" </dev/null >"$BATS_TEST_TMPDIR/report.json"
  run --separate-stderr bash "$CAP" --cap 3 --out-dir "$OUT" "$BATS_TEST_TMPDIR/report.json" </dev/null
  local via_file
  via_file="$(jq -S 'del(.rapport)' <<<"$output")"
  run --separate-stderr bash -c 'set -o pipefail; bash "$1" "$2" | bash "$3" --cap 3 --out-dir "$4"' \
    _ "$DISCOVER" "$APP" "$CAP" "$OUT"
  [ "$status" -eq 0 ]
  [ "$(jq -S 'del(.rapport)' <<<"$output")" = "$via_file" ]
}

@test "pipeline: discover | apply-subsystem-cap.sh | write-backfilled-epics.sh writes one epic per kept subsystem" {
  run --separate-stderr bash -c \
    'set -o pipefail; bash "$1" "$2" | bash "$3" --cap 3 --out-dir "$4" | bash "$5"' \
    _ "$DISCOVER" "$APP" "$CAP" "$OUT" "$EPICS"
  [ "$status" -eq 0 ]
  local written
  written="$(find "$SB/project/board/epics" -name 'E[0-9]*_*.md' | wc -l | tr -d ' ')"
  [ "$written" -eq 3 ]
  run jq -e '.epic_count == 3 and .dry_run == false and (.epics | length) == 3' <<<"$output"
  [ "$status" -eq 0 ]
}

@test "pipeline: discover-subsystems.sh | write-scan-record.sh records every discovered candidate" {
  run --separate-stderr bash -c 'set -o pipefail; bash "$1" "$2" | bash "$3" --out-dir "$4"' \
    _ "$DISCOVER" "$APP" "$RECORD" "$OUT"
  [ "$status" -eq 0 ]
  [ -f "$output" ]
  run jq -e '.candidate_count == 6 and (.candidates | length) == 6 and (.candidates | all(has("path") and has("files") and has("lines")))' "$output"
  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------------------------------------------------
# write-scan-record.sh
# ---------------------------------------------------------------------------------------------------------------------

@test "write-scan-record.sh from a file argument writes a committed-shape record whose candidates equal the report's" {
  bash "$DISCOVER" "$APP" </dev/null >"$BATS_TEST_TMPDIR/report.json"
  run --separate-stderr bash "$RECORD" --out-dir "$OUT" "$BATS_TEST_TMPDIR/report.json" </dev/null
  [ "$status" -eq 0 ]
  local record="$output"
  [ -f "$record" ]
  assert_contains "$record" ".scan-record.json"
  run jq -e --slurpfile r "$BATS_TEST_TMPDIR/report.json" \
    '([.candidates[].path] == [$r[0].candidates[].path]) and .candidate_count == ($r[0].candidates | length) and .baseline_commit != null' "$record"
  [ "$status" -eq 0 ]
}

@test "write-scan-record.sh under --json-out also writes the record to that exact path" {
  bash "$DISCOVER" "$APP" </dev/null >"$BATS_TEST_TMPDIR/report.json"
  run --separate-stderr bash "$RECORD" --out-dir "$OUT" --json-out "$BATS_TEST_TMPDIR/latest.json" "$BATS_TEST_TMPDIR/report.json" </dev/null
  [ "$status" -eq 0 ]
  [ "$(jq -S . "$BATS_TEST_TMPDIR/latest.json")" = "$(jq -S . "$output")" ]
}

@test "write-scan-record.sh exit codes: 0 --help, 1 usage, 2 empty stdin or no candidates array, 4 unwritable out-dir" {
  run --separate-stderr bash "$RECORD" --help </dev/null
  [ "$status" -eq 0 ]
  run --separate-stderr bash "$RECORD" --no-such-flag </dev/null
  [ "$status" -eq 1 ]
  run --separate-stderr bash "$RECORD" --out-dir "$OUT" </dev/null
  [ "$status" -eq 2 ]
  run --separate-stderr bash -c 'printf "{}" | bash "$1" --out-dir "$2"' _ "$RECORD" "$OUT"
  [ "$status" -eq 2 ]
  : >"$BATS_TEST_TMPDIR/a-file"
  bash "$DISCOVER" "$APP" </dev/null >"$BATS_TEST_TMPDIR/report.json"
  run --separate-stderr bash "$RECORD" --out-dir "$BATS_TEST_TMPDIR/a-file" "$BATS_TEST_TMPDIR/report.json" </dev/null
  [ "$status" -eq 4 ]
  # no record was left behind by the failures
  run find "$OUT" -type f
  [ -z "$output" ]
}

# ---------------------------------------------------------------------------------------------------------------------
# write-backfilled-epics.sh
# ---------------------------------------------------------------------------------------------------------------------

@test "write-backfilled-epics.sh under --dry-run computes the epics and writes none" {
  bash "$DISCOVER" "$APP" </dev/null | bash "$CAP" --cap 3 --out-dir "$OUT" >"$BATS_TEST_TMPDIR/cap.json" 2>/dev/null
  run --separate-stderr bash "$EPICS" --dry-run "$BATS_TEST_TMPDIR/cap.json" </dev/null
  [ "$status" -eq 0 ]
  run jq -e '.dry_run == true and .epic_count == 3' <<<"$output"
  [ "$status" -eq 0 ]
  run find "$SB/project/board/epics" -name 'E[0-9]*_*.md'
  [ -z "$output" ]
}

@test "write-backfilled-epics.sh from a file writes epic files numbered from the next free id, one per kept entry" {
  bash "$DISCOVER" "$APP" </dev/null | bash "$CAP" --cap 3 --out-dir "$OUT" >"$BATS_TEST_TMPDIR/cap.json" 2>/dev/null
  run --separate-stderr bash "$EPICS" "$BATS_TEST_TMPDIR/cap.json" </dev/null
  [ "$status" -eq 0 ]
  run jq -r '[.epics[].id] | join(",")' <<<"$output"
  [ "$output" = "E01,E02,E03" ]
  local f
  for f in "$SB"/project/board/epics/E0[123]_*.md; do
    [ -f "$f" ]
    assert_contains "$(cat "$f")" "provenance: backfilled"
  done
}

@test "write-backfilled-epics.sh exit 3 when --epics-dir or --json-out resolves outside project/, and writes nothing" {
  bash "$DISCOVER" "$APP" </dev/null | bash "$CAP" --cap 3 --out-dir "$OUT" >"$BATS_TEST_TMPDIR/cap.json" 2>/dev/null
  run --separate-stderr bash "$EPICS" --epics-dir "$BATS_TEST_TMPDIR/outside" "$BATS_TEST_TMPDIR/cap.json" </dev/null
  [ "$status" -eq 3 ]
  [ ! -e "$BATS_TEST_TMPDIR/outside" ]
  run --separate-stderr bash "$EPICS" --json-out "$BATS_TEST_TMPDIR/outside.json" "$BATS_TEST_TMPDIR/cap.json" </dev/null
  [ "$status" -eq 3 ]
  [ ! -e "$BATS_TEST_TMPDIR/outside.json" ]
}

@test "write-backfilled-epics.sh exit codes: 0 for an empty kept array, 1 usage, 2 empty stdin or no kept array" {
  run --separate-stderr bash -c 'printf "{\"kept\": []}" | bash "$1"' _ "$EPICS"
  [ "$status" -eq 0 ]
  run --separate-stderr bash "$EPICS" --no-such-flag </dev/null
  [ "$status" -eq 1 ]
  run --separate-stderr bash "$EPICS" </dev/null
  [ "$status" -eq 2 ]
  run --separate-stderr bash -c 'printf "{}" | bash "$1"' _ "$EPICS"
  [ "$status" -eq 2 ]
}

# ---------------------------------------------------------------------------------------------------------------------
# directory-triage.sh
# ---------------------------------------------------------------------------------------------------------------------

@test "directory-triage.sh from arguments sorts candidates into ignored and remaining, and the counts add up" {
  run --separate-stderr bash "$TRIAGE" "$APP" src/api node_modules src/web ignored_dir </dev/null
  [ "$status" -eq 0 ]
  run jq -e '.candidate_count == 4 and .ignored_count == 2 and .remaining_count == 2
             and (.ignored_count + .remaining_count == .candidate_count)
             and ([.ignored[].path] | sort) == ["ignored_dir", "node_modules"]
             and ([.remaining[].path] | sort) == ["src/api", "src/web"]' <<<"$output"
  [ "$status" -eq 0 ]
}

@test "directory-triage.sh from a stdin list (the discover | triage pipeline form) triages every piped path" {
  run --separate-stderr bash -c \
    'set -o pipefail; bash "$1" "$2" | jq -r ".candidates[].path" | bash "$3" "$2"' _ "$DISCOVER" "$APP" "$TRIAGE"
  [ "$status" -eq 0 ]
  # all 6 piped candidates survived triage: none is gitignored, and none was lost
  run jq -e '.candidate_count == 6 and .remaining_count == 6 and .ignored_count == 0' <<<"$output"
  [ "$status" -eq 0 ]
}

@test "directory-triage.sh exit codes: 1 without a root, 2 for a missing root" {
  run --separate-stderr bash "$TRIAGE" </dev/null
  [ "$status" -eq 1 ]
  run --separate-stderr bash "$TRIAGE" "$BATS_TEST_TMPDIR/no-such-root" src </dev/null
  [ "$status" -eq 2 ]
}
