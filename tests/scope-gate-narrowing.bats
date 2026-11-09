#!/usr/bin/env bats
#
# Coverage for skills/j-test/scripts/narrow-suites.sh (E72_S07_T02) — the piece
# that finally makes a `scoped` gate narrow, and that excludes suites which
# cannot pass while the session is off the level-2 baseline.
#
# What this suite is really protecting. Before E72_S07_T02, scope-test-gate.sh
# filtered the suite LIST to the mapped ids and then ran each survivor's command
# unchanged. This repository has ONE bats suite whose command globs the whole
# tests/ directory, so a filtered list of one still ran all 261 files: `scoped`
# and `full` were operationally identical and any unrelated red assertion failed
# every story's closing gate. The decision record is
# project/documentation/scope-gate-fix-decision.md.
#
# The dangerous failure mode of the fix is the opposite one — a gate that
# silently passes LESS than it should. So the tests below pin, as hard as the
# narrowing itself: that exclusion is never silent, that an emptied selection is
# never runnable, and that the npm twin still folds (otherwise a full run would
# execute the catalog twice).
#
# Every case runs against a FIXTURE ROOT. Nothing here runs a real test suite,
# changes the session's permission level, or touches the real settings files.
#
# Assertions use `[ ]` and tests/helpers/assertions.bash only; a line starting
# with `[[` is banned repo-wide by tests/bats-assertion-convention.bats.

bats_require_minimum_version 1.5.0

load helpers/assertions

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
NARROW="$REPO_ROOT/skills/j-test/scripts/narrow-suites.sh"
CATALOG="$REPO_ROOT/skills/j-test/scripts/build-catalog.sh"
L2="$REPO_ROOT/templates/permission-levels/level-2-guarded.json"
L5="$REPO_ROOT/templates/permission-levels/level-5-unrestricted.json"

setup() {
  FX="$BATS_TEST_TMPDIR/root"
  mkdir -p "$FX/templates/permission-levels" "$FX/.claude" "$FX/.agents" "$FX/tests"
  cp "$L2" "$FX/templates/permission-levels/level-2-guarded.json"
  cp "$L2" "$FX/.claude/settings.json"
  cp "$L2" "$FX/.agents/settings.json"
  printf '{"session_level":2}\n' > "$FX/.jenga-permission-level.json"
  printf '{"scripts":{"test":"bats tests/*.bats"}}\n' > "$FX/package.json"

  plain_test alpha
  plain_test beta
  plain_test gamma

  DISC="$FX/discovery.json"
  cat > "$DISC" <<'EOF'
{"suites":[{"id":"bats:tests","name":"bats tests","type":"unit","ecosystem":"bats","command":"bats tests/*.bats","paths":["tests/*.bats"]},{"id":"npm:test","name":"npm test","type":"unit","ecosystem":"npm","command":"npm test","paths":[]}],"warnings":[]}
EOF
  REPORT="$BATS_TEST_TMPDIR/report.json"
  OUT="$BATS_TEST_TMPDIR/out.json"

  git -C "$FX" init -q
  git -C "$FX" add -A
}

plain_test() {
  printf '#!/usr/bin/env bats\n@test "%s" { true; }\n' "$1" > "$FX/tests/$1.bats"
}

marked_test() {
  printf '#!/usr/bin/env bats\n# jenga:requires-baseline-permissions: %s\n@test "%s" { true; }\n' \
    "$2" "$1" > "$FX/tests/$1.bats"
  git -C "$FX" add -A
}

elevate() {
  cp "$L5" "$FX/.claude/settings.json"
  printf '{"session_level":5}\n' > "$FX/.jenga-permission-level.json"
}

mapped() {
  printf '%s\n' "$1" > "$BATS_TEST_TMPDIR/mapped.json"
  printf '%s' "$BATS_TEST_TMPDIR/mapped.json"
}

run_narrow() {
  run bash "$NARROW" --root "$FX" --suites "$DISC" --report "$REPORT" "$@"
}

cmd_of() { jq -r --arg i "$1" '.suites[] | select(.id == $i) | .command' "$OUT"; }

# scoped narrowing ---------------------------------------------------------------------------------------------------

@test "scoped: the command runs only the mapped test files, not the whole glob" {
  m="$(mapped '{"mapped_tests":{"bats:tests":["tests/alpha.bats","tests/beta.bats"]}}')"
  run bash "$NARROW" --root "$FX" --suites "$DISC" --mapped-tests "$m" --report "$REPORT"
  [ "$status" -eq 0 ]
  printf '%s' "$output" > "$OUT"
  assert_contains "$(cmd_of bats:tests)" "tests/alpha.bats"
  assert_contains "$(cmd_of bats:tests)" "tests/beta.bats"
  assert_not_contains "$(cmd_of bats:tests)" "gamma"
  assert_not_contains "$(cmd_of bats:tests)" "tests/*.bats"
}

@test "scoped: the report records selected out of available" {
  m="$(mapped '{"mapped_tests":{"bats:tests":["tests/alpha.bats"]}}')"
  run bash "$NARROW" --root "$FX" --suites "$DISC" --mapped-tests "$m" --report "$REPORT"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.narrowed[] | select(.id == "bats:tests") | .selected' "$REPORT")" = "1" ]
  [ "$(jq -r '.narrowed[] | select(.id == "bats:tests") | .emptied' "$REPORT")" = "false" ]
}

@test "scoped: a suite the map never named is left completely alone" {
  # Emptying it would disable a suite the map did not speak about.
  m="$(mapped '{"mapped_tests":{"bats:tests":["tests/alpha.bats"]}}')"
  run bash "$NARROW" --root "$FX" --suites "$DISC" --mapped-tests "$m" --report "$REPORT"
  [ "$status" -eq 0 ]
  printf '%s' "$output" > "$OUT"
  [ -n "$(cmd_of npm:test)" ]
}

@test "scoped: a filename containing a space is quoted, never split into two arguments" {
  printf '#!/usr/bin/env bats\n@test "s" { true; }\n' > "$FX/tests/with space.bats"
  git -C "$FX" add -A
  m="$(mapped '{"mapped_tests":{"bats:tests":["tests/with space.bats"]}}')"
  run bash "$NARROW" --root "$FX" --suites "$DISC" --mapped-tests "$m" --report "$REPORT"
  [ "$status" -eq 0 ]
  printf '%s' "$output" > "$OUT"
  assert_contains "$(cmd_of bats:tests)" "'tests/with space.bats'"
}

# the identity property ----------------------------------------------------------------------------------------------

@test "full with the precondition satisfied is a byte-for-byte no-op" {
  # This is what bounds the blast radius: a full gate behaves exactly as it did
  # before this script existed unless a marked file is actually in play.
  run_narrow
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -S -c .)" = "$(jq -S -c . "$DISC")" ]
  [ "$(jq -r '.narrowed | length' "$REPORT")" = "0" ]
  [ "$(jq -r '.excluded | length' "$REPORT")" = "0" ]
}

@test "a marked file changes nothing while the precondition holds" {
  marked_test delta "needs the baseline"
  run_narrow
  [ "$status" -eq 0 ]
  [ "$(jq -r '.precondition' "$REPORT")" = "satisfied" ]
  [ "$(jq -r '.excluded | length' "$REPORT")" = "0" ]
  printf '%s' "$output" > "$OUT"
  assert_contains "$(cmd_of bats:tests)" "tests/*.bats"
}

# exclusion ----------------------------------------------------------------------------------------------------------

@test "full with the precondition unmet drops the marked file and keeps the rest" {
  marked_test delta "needs the baseline"
  elevate
  run_narrow
  [ "$status" -eq 0 ]
  [ "$(jq -r '.precondition' "$REPORT")" = "unsatisfied" ]
  printf '%s' "$output" > "$OUT"
  assert_not_contains "$(cmd_of bats:tests)" "delta"
  assert_contains "$(cmd_of bats:tests)" "tests/alpha.bats"
}

@test "exclusion is never silent: the report names the file, its reason and the cause" {
  marked_test delta "needs a real push at the level-2 baseline"
  elevate
  run_narrow
  [ "$status" -eq 0 ]
  [ "$(jq -r '.excluded[0].file' "$REPORT")" = "tests/delta.bats" ]
  [ "$(jq -r '.excluded[0].reason' "$REPORT")" = "needs a real push at the level-2 baseline" ]
  assert_contains "$(jq -r '.precondition_reason' "$REPORT")" "level-2"
}

@test "the npm twin is excluded too, so the opaque entry point cannot reintroduce the file" {
  # build-catalog.sh folds npm:test onto bats:tests by its package.json script
  # body, and npm:test is the SURVIVOR. Narrowing only the bats suite would let
  # the run execute `npm test` -> `bats tests/*.bats` and run the excluded file.
  marked_test delta "needs the baseline"
  elevate
  run_narrow
  [ "$status" -eq 0 ]
  printf '%s' "$output" > "$OUT"
  assert_not_contains "$(cmd_of npm:test)" "delta"
}

@test "the npm twin keeps the SAME command, so build-catalog still folds them into one entry" {
  # If these ever diverge, a full run executes the whole catalog twice — the
  # hazard build-catalog.sh's own header warns about.
  marked_test delta "needs the baseline"
  elevate
  run_narrow
  [ "$status" -eq 0 ]
  printf '%s' "$output" > "$OUT"
  [ "$(cmd_of npm:test)" = "$(cmd_of bats:tests)" ]
  run bash "$CATALOG" --root "$FX" --discovery-file "$OUT"
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r '.runnable | length')" = "1" ]
}

# the npm fold: both failure variants ---------------------------------------------------------------------------------

@test "variant 1: the narrowed selection is numbered ONCE, not twice" {
  # The npm fold defect as the tester reproduced it, and as this repository is
  # configured today (scripts.test is byte-equal to the discovered bats command).
  # build-catalog.sh keys an npm suite on its package.json script BODY, which
  # narrowing cannot rewrite, so the moment the bats commands moved the group
  # split into TWO entries carrying byte-identical commands. run-suites.sh runs
  # each numbered entry and never compares commands, so a full gate under any
  # exclusion executed the whole narrowed selection twice -- the exact hazard
  # build-catalog.sh's npm rule exists to prevent, reintroduced from the other
  # end. It now folds a SECOND time on the final command (its dedup rule 5).
  # REMOVE THAT PASS AND THIS CASE GOES RED with two identical entries.
  cat > "$DISC" <<'EOF'
{"suites":[{"id":"bats:tests","name":"bats tests","type":"unit","ecosystem":"bats","command":"bats tests/*.bats","paths":["tests/*.bats"]},{"id":"config:bats:integration","name":"bats (integration)","type":"integration","ecosystem":"config","command":"bats tests/*.bats","paths":["tests/*.bats"]},{"id":"npm:test","name":"npm test","type":"unit","ecosystem":"npm","command":"npm test","paths":[]}],"warnings":[]}
EOF
  marked_test delta "needs the baseline"
  elevate
  run_narrow
  [ "$status" -eq 0 ]
  printf '%s' "$output" > "$OUT"
  # Nothing was disabled: the twin rule did rewrite the npm command here, so it
  # is the second fold pass -- not option B -- that removes the duplicate.
  [ "$(jq -r '.disabled | length' "$REPORT")" = "0" ]
  run bash "$CATALOG" --root "$FX" --discovery-file "$OUT"
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r '[.runnable[].id] | join(",")')" = "npm:test" ]
  # The folded members stay visible, so no suite silently disappears from the list.
  [ "$(printf '%s' "$output" | jq -r '[.runnable[0].also[].id] | join(",")')" = "bats:tests,config:bats:integration" ]
}

@test "variant 2: an npm twin that cannot be narrowed is disabled, never left running the glob" {
  # The worse variant, found while investigating the first and with NO coverage
  # anywhere before this case, which is why it went unnoticed.
  # `bats --tap tests/*.bats` is not byte-equal to the discovered
  # `bats tests/*.bats`, so the twin rule declines to rewrite and the entry still
  # runs `npm test` -- which expands to the WHOLE tests/ directory, INCLUDING the
  # file the exclusion just removed, while excluded_test_files states that file
  # was not verified. Not a runtime cost: a file the gate said it skipped gets
  # executed, fails for the baseline reason it was excluded over, and the failure
  # is attributed to a suite the reader was told had been narrowed.
  # REMOVE THE DISABLING RULE AND THIS CASE GOES RED with `npm test` runnable.
  printf '{"scripts":{"test":"bats --tap tests/*.bats"}}\n' > "$FX/package.json"
  marked_test delta "needs the baseline"
  elevate
  run_narrow
  [ "$status" -eq 0 ]
  printf '%s' "$output" > "$OUT"
  [ -z "$(cmd_of npm:test)" ]
  [ "$(jq -r '.disabled[0].id' "$REPORT")" = "npm:test" ]
  assert_contains "$(jq -r '.disabled[0].reason' "$REPORT")" "could run a file this run excluded"
  run bash "$CATALOG" --root "$FX" --discovery-file "$OUT"
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r '[.runnable[].id] | join(",")')" = "bats:tests" ]
  # Never numbered, never executed, never counted as a pass or a fail.
  [ "$(printf '%s' "$output" | jq -r '[.not_runnable[].id] | join(",")')" = "npm:test" ]
  assert_not_contains "$(printf '%s' "$output" | jq -r '[.runnable[].command] | join(" ")')" "delta"
}

@test "nothing is disabled when no exclusion fired: a pure scoped narrowing leaves npm alone" {
  # The disabling rule is keyed on an exclusion having ACTUALLY fired, not on
  # narrowing. An opaque suite that runs more than the narrowed set is wasteful,
  # not wrong: the report makes no claim about files it never excluded. Keying it
  # on narrowing instead would drop the project's own entry point from every
  # scoped run, which is a real loss for no correctness gain.
  printf '{"scripts":{"test":"bats --tap tests/*.bats"}}\n' > "$FX/package.json"
  m="$(mapped '{"mapped_tests":{"bats:tests":["tests/alpha.bats"]}}')"
  run bash "$NARROW" --root "$FX" --suites "$DISC" --mapped-tests "$m" --report "$REPORT"
  [ "$status" -eq 0 ]
  printf '%s' "$output" > "$OUT"
  [ "$(cmd_of bats:tests)" = "bats 'tests/alpha.bats'" ]
  [ "$(cmd_of npm:test)" = "npm test" ]
  [ "$(jq -r '.disabled | length' "$REPORT")" = "0" ]
}

@test "the gate refuses to fall back when the mapped suites leave nothing runnable" {
  # The accepted cost of disabling an opaque suite: a mapped selection made only
  # of such a suite produces an empty catalog. The scoped path must exit 3
  # ("nothing was verified") there, exactly as it does for the all-emptied case,
  # and must NOT fall through to the full catalog, which would run everything the
  # exclusion had just removed.
  #
  # E72_S08_T02 extracted that `die 3` into run_selection() so the bounded default suite set could reuse it, and
  # parameterised the noun through an argument, so the sentence is no longer spelled out in the source even though the
  # RUNTIME message is byte-identical (the scoped call site passes "mapped suites" as that argument). This assertion
  # was the whole of that path's coverage, and it went red on a refactor that changed no behaviour — see
  # project/rapports/problems/E72_S08_T02-stale-source-text-assertion-in-scope-gate-narrowing.md, finding 1.
  #
  # It now pins the two halves that COMPOSE the runtime message — the invariant text and the call site that supplies
  # the noun — rather than the concatenation, so an extraction cannot break it while behaviour holds, and removing
  # either half still does. It also pins that there is nothing left to fall back TO: the escalation string is gone and
  # run_full() has exactly one call site, the `full` policy's own. Still source text: finding 2 of that rapport (this
  # `die 3` has no runtime test anywhere) is pre-existing and is left to the follow-up the rapport recommends.
  local gate_src="$REPO_ROOT/skills/j-test/scripts/scope-test-gate.sh"
  body="$(cat "$gate_src")"
  assert_contains "$body" "produced no runnable catalog entry"
  assert_contains "$body" 'run_selection "$MAP_FILE_OUT" scoped "mapped suite" "mapped suites"'
  assert_contains "$body" "disabled_suites"
  run grep -c "falling back to the full catalog" "$gate_src"
  [ "$output" = "0" ]
  run grep -cE '^[[:space:]]*run_full$' "$gate_src"
  [ "$output" = "1" ]
}

# a skip is never a pass ---------------------------------------------------------------------------------------------

@test "when every candidate is excluded the command is emptied, not left running the glob" {
  rm -f "$FX/tests/alpha.bats" "$FX/tests/beta.bats" "$FX/tests/gamma.bats"
  marked_test delta "needs the baseline"
  elevate
  run_narrow
  [ "$status" -eq 0 ]
  [ "$(jq -r '.narrowed[] | select(.id == "bats:tests") | .emptied' "$REPORT")" = "true" ]
  printf '%s' "$output" > "$OUT"
  [ -z "$(cmd_of bats:tests)" ]
}

@test "an emptied suite is NOT runnable in the catalog, so it can never be counted as passed" {
  rm -f "$FX/tests/alpha.bats" "$FX/tests/beta.bats" "$FX/tests/gamma.bats"
  marked_test delta "needs the baseline"
  elevate
  bash "$NARROW" --root "$FX" --suites "$DISC" --report "$REPORT" > "$OUT"
  run bash "$CATALOG" --root "$FX" --discovery-file "$OUT"
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r '.runnable | length')" = "0" ]
  # An empty runnable catalog is what scope-test-gate.sh turns into exit 3.
  assert_output_contains "not_runnable"
}

# refusing to rewrite ------------------------------------------------------------------------------------------------

@test "a command with shell metacharacters is never rebuilt" {
  cat > "$FX/disc2.json" <<'EOF'
{"suites":[{"id":"shellcheck:all","name":"shellcheck","type":"sast","ecosystem":"shellcheck","command":"find . -name '*.sh' -print0 | xargs -0 shellcheck","paths":[]}],"warnings":[]}
EOF
  run bash "$NARROW" --root "$FX" --suites "$FX/disc2.json" --report "$REPORT"
  [ "$status" -eq 0 ]
  assert_output_contains "xargs -0 shellcheck"
  [ "$(jq -r '.not_narrowable[0]' "$REPORT")" = "shellcheck:all" ]
}

@test "a non-bats runner is reported as not narrowable rather than guessed at" {
  cat > "$FX/disc3.json" <<'EOF'
{"suites":[{"id":"pytest:tests","name":"pytest tests","type":"unit","ecosystem":"pytest","command":"pytest tests","paths":["tests/**/*_test.py"]}],"warnings":[]}
EOF
  m="$(mapped '{"mapped_tests":{"pytest:tests":["tests/a_test.py"]}}')"
  run bash "$NARROW" --root "$FX" --suites "$FX/disc3.json" --mapped-tests "$m" --report "$REPORT"
  [ "$status" -eq 0 ]
  assert_output_contains "pytest tests"
  [ "$(jq -r '.not_narrowable[0]' "$REPORT")" = "pytest:tests" ]
}

# usage --------------------------------------------------------------------------------------------------------------

@test "--help exits 0" {
  run bash "$NARROW" --help
  [ "$status" -eq 0 ]
  assert_output_contains "--mapped-tests"
}

@test "a missing --suites is exit 2" {
  run bash "$NARROW" --root "$FX"
  [ "$status" -eq 2 ]
}

@test "an unreadable --suites and a non-discovery --suites are both exit 2" {
  run bash "$NARROW" --root "$FX" --suites "$FX/nope.json"
  [ "$status" -eq 2 ]
  printf '{"not":"discovery"}\n' > "$FX/bad.json"
  run bash "$NARROW" --root "$FX" --suites "$FX/bad.json"
  [ "$status" -eq 2 ]
}

@test "a non-directory --root is exit 2" {
  run bash "$NARROW" --root "$FX/nope" --suites "$DISC"
  [ "$status" -eq 2 ]
}

# the gate's own contract --------------------------------------------------------------------------------------------

@test "the gate's JSON carries the new keys and keeps the E72_S06 keys" {
  # policy none runs nothing, so this is a safe way to inspect the shape.
  # --separate-stderr: with --json the object is the WHOLE of stdout and the
  # human line goes to stderr, so bats' merged $output is not parseable JSON.
  # tests/scope-test-gate.bats:172 runs the gate the same way for the same reason.
  run --separate-stderr bash "$REPO_ROOT/skills/j-test/scripts/scope-test-gate.sh" \
    --scope task --id E72_S07_T02 --root "$REPO_ROOT" --json
  [ "$status" -eq 0 ]
  for key in scope id mode effective_mode fallback_reason suites_run passed failed suites exit_code \
             test_files_run test_files_available excluded_test_files exclusion_reason \
             disabled_suites map_excluded_test_files map_exclusion_conflicts \
             map_exclusions_superseded refusal; do
    [ "$(printf '%s' "$output" | jq --arg k "$key" 'has($k)')" = "true" ]
  done
}

@test "test_files_run is null rather than 0 when a run was not narrowed at all" {
  # 0 would mean "nothing was selected", which is a different and much worse
  # statement than "narrowing did not apply here".
  # --separate-stderr for the same reason as the case above.
  run --separate-stderr bash "$REPO_ROOT/skills/j-test/scripts/scope-test-gate.sh" \
    --scope task --id E72_S07_T02 --root "$REPO_ROOT" --json
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r '.test_files_run')" = "null" ]
}

@test "the gate names narrow-suites.sh and documents that a skip is never a pass" {
  body="$(cat "$REPO_ROOT/skills/j-test/scripts/scope-test-gate.sh")"
  assert_contains "$body" "narrow-suites.sh"
  assert_contains "$body" "A SKIP IS NEVER A PASS"
  assert_contains "$body" "nothing was verified, so this is not a pass"
}

@test "the shared glob dialect is the single definition both scripts read" {
  [ -f "$REPO_ROOT/skills/j-test/scripts/lib/glob-defs.jq" ]
  assert_contains "$(cat "$REPO_ROOT/skills/j-test/scripts/map-scope.sh")" "lib/glob-defs.jq"
  assert_contains "$(cat "$NARROW")" "lib/glob-defs.jq"
}
