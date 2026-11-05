#!/usr/bin/env bats
#
# Consumer-install testbed scenarios (E54_S03). Each test installs the packed tarball into a throwaway
# consumer project (helpers/consumer-testbed.bash) and runs framework commands from that consumer's root,
# the way a real `npm install @jenga-ai/agent` user does. Where a skill prescribes a command, the test
# extracts that exact line from SKILL.md and runs it, so a wrong or unreachable path in the instructions
# fails here too.
#
# Why: this monorepo's bare root scripts/ and skills/ mask every defect where a packaged script finds a
# helper relative to the consumer's git toplevel instead of the package (E46; mark-deployed.sh in 4.3.0).
#
# Optional local-only run against a disposable copy of a real consumer: see the last group (TESTBED_ST_TEST).

load helpers/assertions
load helpers/consumer-testbed

bats_require_minimum_version 1.5.0

setup_file() {
  testbed_pack
}

# --- install ------------------------------------------------------------------------------------

@test "install: postinstall mirrors skills/agents and records .jenga-version matching the package" {
  testbed_consumer "$BATS_TEST_TMPDIR/c" clean
  local want
  want="$(node -p "require('$TESTBED_REPO_ROOT/package.json').version")"
  [ "$(tr -d '[:space:]' < "$BATS_TEST_TMPDIR/c/.jenga-version")" = "$want" ]
  [ -f "$BATS_TEST_TMPDIR/c/.claude/skills/j-status/SKILL.md" ]
  [ -f "$BATS_TEST_TMPDIR/c/.agents/skills/j-status/SKILL.md" ]
  # scripts/ is never mirrored, so a consumer has no root scripts/ at all.
  [ ! -e "$BATS_TEST_TMPDIR/c/scripts" ]
}

# --- j.status step 6.5: the command the skill tells the agent to run -----------------------------------

@test "j.status step 6.5: the prescribed command resolves from node_modules and exits 0" {
  local shape
  for shape in clean jobo decoy; do
    testbed_consumer "$BATS_TEST_TMPDIR/$shape" "$shape"
    local cmd
    cmd="$(testbed_skill_command j-status mark-deployed.sh)"
    [ -n "$cmd" ]
    cd "$BATS_TEST_TMPDIR/$shape"
    run -0 bash -c "$cmd"
    [[ "$output" != *"expected script not found"* ]]
    [[ "$output" != *DECOY* ]]
  done
}

@test "j.status step 6.5: promotes Publicized tasks using the package's helpers, not the consumer's" {
  local shape
  for shape in clean jobo decoy; do
    local c="$BATS_TEST_TMPDIR/$shape"
    testbed_consumer "$c" "$shape"
    testbed_add_task "$c" E99_S01_T01 Publicized
    printf 'prod\t1.0.0\tv1.0.0\t%s\n' "$(git -C "$c" rev-parse HEAD)" > "$c/tags.tsv"
    local cmd
    cmd="$(testbed_skill_command j-status mark-deployed.sh)"
    cd "$c"
    run -0 bash -c "$cmd --diff-file tags.tsv"
    [[ "$output" != *DECOY* ]]
    grep -q '^status: Deployed to Prod$' "$c/project/board/tasks/E99_S01_T01_fixture.md"
    grep -q '^date_deployed_prod: ' "$c/project/board/tasks/E99_S01_T01_fixture.md"
  done
}

# --- j.close-story: check-privatized.sh ---------------------------------------------------------------

@test "j.close-story: check-privatized.sh finds its helpers in the package from a consumer" {
  local shape
  for shape in clean decoy; do
    local c="$BATS_TEST_TMPDIR/$shape"
    testbed_consumer "$c" "$shape"
    printf 'project/board/\n' > "$c/.publicignore"
    git -C "$c" add .publicignore && git -C "$c" commit -q -m "chore: publicignore"
    testbed_add_task "$c" E99_S01_T01 Done
    local cmd
    cmd="$(testbed_skill_command j-close-story check-privatized.sh)"
    [ -n "$cmd" ]
    cd "$c"
    run -0 bash -c "$cmd E99_S01_T01 project/board/tasks/E99_S01_T01_fixture.md"
    [[ "$output" == *PRIVATIZED* ]]
    [[ "$output" != *DECOY* ]]
    grep -q '^status: Privatized$' "$c/project/board/tasks/E99_S01_T01_fixture.md"
  done
}

# --- the documented staged-release verification (README "Verifying a Staged Release...") --------------------

@test "staged-release procedure: skill smoke test against the package root exits 0" {
  testbed_consumer "$BATS_TEST_TMPDIR/c" clean
  cd "$BATS_TEST_TMPDIR/c"
  run -0 bash node_modules/@jenga-ai/agent/skills/j-smoke-test/scripts/smoke-test-skills.sh --root node_modules/@jenga-ai/agent
}

@test "staged-release procedure: the package's own populate-knowledge-graph tests pass from a consumer" {
  testbed_consumer "$BATS_TEST_TMPDIR/c" clean
  cd "$BATS_TEST_TMPDIR/c"
  local t
  for t in node_modules/@jenga-ai/agent/scripts/populate-knowledge-graph.*.test.js; do
    [ -f "$t" ] || continue
    run -0 node "$t"
  done
}

# --- every node_modules/@jenga-ai/agent/... path the instructions name must ship ----------------------------

@test "instructions: every node_modules/@jenga-ai/agent/<path> named in a skill or agent exists in the package" {
  testbed_consumer "$BATS_TEST_TMPDIR/c" clean
  local pkg="$BATS_TEST_TMPDIR/c/node_modules/@jenga-ai/agent" missing="" ref
  while IFS= read -r ref; do
    case "$ref" in *-|*_) continue ;; esac   # a prefix cut off at a <placeholder>, not a path
    [ -e "$pkg/$ref" ] || missing="$missing $ref"
  done < <(grep -rhoE 'node_modules/@jenga-ai/agent/[A-Za-z0-9_./-]+' "$pkg/skills" "$pkg/agents" \
             | sed -E 's#^node_modules/@jenga-ai/agent/##; s#[.,)]+$##' | sort -u)
  [ -z "$missing" ] || { echo "named in instructions but not shipped:$missing" >&2; return 1; }
}

# --- static sweep: no shipped script may locate a packaged helper from the consumer's repo root -------------

@test "sweep: no shipped script derives a packaged-file path from the consumer's repo root without a fallback" {
  testbed_consumer "$BATS_TEST_TMPDIR/c" clean
  run testbed_sweep_package_root_paths "$BATS_TEST_TMPDIR/c/node_modules/@jenga-ai/agent" \
    "$TESTBED_REPO_ROOT/tests/fixtures/package-root-derived-paths.allowlist"
  if [ "$status" -ne 0 ]; then
    echo "shipped scripts that build a package-file path from \$REPO_ROOT (resolve from the script's own directory," >&2
    echo "add a node_modules/@jenga-ai/agent fallback, or allowlist with a reason in tests/fixtures/package-root-derived-paths.allowlist):" >&2
    printf '%s\n' "$output" | sed 's/\t/  ->  /' >&2
    return 1
  fi
}

# --- optional, local-only: a disposable copy of a real consumer project ---------------------------------------
#
# Set TESTBED_ST_TEST to a consumer project directory (e.g. ../ST-Test) to run the same scenarios against a
# copy of it. The project itself is only read; the copy lives under $BATS_TEST_TMPDIR. Skipped when unset, so
# CI and the mirror gate (which have no such directory) are unaffected.

@test "real consumer copy: j.status step 6.5 and the skill smoke test pass from a copy of TESTBED_ST_TEST" {
  [ -n "${TESTBED_ST_TEST:-}" ] || skip "TESTBED_ST_TEST not set"
  [ -d "$TESTBED_ST_TEST" ] || skip "TESTBED_ST_TEST is not a directory: $TESTBED_ST_TEST"
  local c="$BATS_TEST_TMPDIR/real"
  testbed_consumer_from "$TESTBED_ST_TEST" "$c"
  cd "$c"
  local cmd
  cmd="$(testbed_skill_command j-status mark-deployed.sh)"
  run -0 bash -c "$cmd"
  [[ "$output" != *"expected script not found"* ]]
  run -0 bash node_modules/@jenga-ai/agent/skills/j-smoke-test/scripts/smoke-test-skills.sh --root node_modules/@jenga-ai/agent
  run testbed_sweep_package_root_paths "$c/node_modules/@jenga-ai/agent" \
    "$TESTBED_REPO_ROOT/tests/fixtures/package-root-derived-paths.allowlist"
  [ "$status" -eq 0 ]
}
