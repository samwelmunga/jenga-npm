#!/usr/bin/env bats
#
# E98_S02_T03: step 7 of project/.workflows/scripts/st-test-run.sh runs the skill smoke test twice and reports two
# separate checks, so a failure names the layout it happened in:
#   skill smoke test (package root)             structural, over node_modules/<pkg>
#   skill smoke test (consumer .claude/skills)  over the consumer's own mirror, with the execution check
#
# No real npm, no network and no install: `npm` is a stub on PATH that only fakes `stage download`, and the "staged
# package" is a tiny synthetic package built under BATS_TEST_TMPDIR. The consumer is built from it with
# scripts/consumer-layout-fixture.sh, i.e. node_modules/@jenga-ai/agent plus a postinstall-shaped .claude/skills.
# The steps around step 7 (shasum, .jenga-version, the node tests) FAIL in this fixture and are not what is asserted.

# shellcheck disable=SC2016
# SC2016: the fixture scripts are written with single quotes on purpose; they hold literal $ and backticks.

bats_require_minimum_version 1.5.0

load helpers/assertions

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
ST_RUN="$REPO_ROOT/project/.workflows/scripts/st-test-run.sh"
BASH_BIN="$(command -v bash)"

setup() {
  PKG="$BATS_TEST_TMPDIR/pkg"
  CONSUMER="$BATS_TEST_TMPDIR/consumer"
  WORK="$BATS_TEST_TMPDIR/work"
  mkdir -p "$PKG/skills/j-smoke-test/scripts" "$PKG/skills/index/scripts" "$PKG/agents" "$PKG/templates" "$PKG/scripts" \
           "$WORK" "$BATS_TEST_TMPDIR/bin" "$BATS_TEST_TMPDIR/tmp"
  : > "$PKG/agents/developer.md"
  printf '%s\n' '# a package marker' > "$PKG/templates/x.md"
  : > "$PKG/scripts/resolve-root.sh"
  : > "$PKG/.publicignore"
  cp "$REPO_ROOT/scripts/consumer-layout-fixture.sh" "$REPO_ROOT/scripts/never-public-refs.sh" "$PKG/scripts/"
  cp "$REPO_ROOT/skills/index/scripts/package-root.sh" "$PKG/skills/index/scripts/"
  cp "$REPO_ROOT/skills/j-smoke-test/scripts/smoke-test-skills.sh" "$PKG/skills/j-smoke-test/scripts/"
  printf '%s\n' '---' 'name: j.smoke-test' 'description: Fixture copy of the smoke test skill.' '---' > "$PKG/skills/j-smoke-test/SKILL.md"

  # a git work tree with the package manifest the script reads its name and version from
  git -C "$WORK" init -q
  printf '%s\n' '{ "name": "@jenga-ai/agent", "version": "1.0.0" }' > "$WORK/package.json"

  # npm stub: only `npm stage download <id>` has to produce something (the tarball the later steps never open)
  cat > "$BATS_TEST_TMPDIR/bin/npm" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-}" = "stage" ] && [ "${2:-}" = "download" ]; then : > "$PWD/pkg-1.0.0.tgz"; fi
exit 0
EOF
  chmod +x "$BATS_TEST_TMPDIR/bin/npm"
}

# skill <dir> <name>: a valid skill in the synthetic package.
skill() {
  mkdir -p "$PKG/skills/$1/scripts"
  printf '%s\n' '---' "name: $2" 'description: A perfectly ordinary fixture skill.' '---' '' '# Fixture' > "$PKG/skills/$1/SKILL.md"
}

# A script that locates the package the way a pre-E98 script did: three levels above itself.
write_unmigrated() {
  cat > "$PKG/skills/$1/scripts/run.sh" <<'EOF'
#!/usr/bin/env bash
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
case "${1:-}" in
  --help|-h)
    [ -f "$ROOT/templates/x.md" ] || { echo "cannot read $ROOT/templates/x.md" >&2; exit 1; }
    echo "usage: run.sh"; exit 0 ;;
esac
EOF
}

# The same script, migrated to the shared resolver.
write_migrated() {
  cat > "$PKG/skills/$1/scripts/run.sh" <<'EOF'
#!/usr/bin/env bash
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SCRIPT_DIR/../../index/scripts/package-root.sh"
ROOT="$(jenga_package_root "$SCRIPT_DIR")" || { echo "no package found" >&2; exit 1; }
case "${1:-}" in
  --help|-h)
    [ -f "$ROOT/templates/x.md" ] || { echo "cannot read $ROOT/templates/x.md" >&2; exit 1; }
    echo "usage: run.sh"; exit 0 ;;
esac
EOF
}

# build_consumer: the stage consumer, as `npm install` plus postinstall leaves it.
build_consumer() {
  "$BASH_BIN" "$PKG/scripts/consumer-layout-fixture.sh" "$CONSUMER" "$PKG" > /dev/null
  printf '%s\n' '{ "name": "st-test", "version": "0.0.0", "private": true }' > "$CONSUMER/package.json"
}

# st_run: run the script from inside the git work tree, with the stubbed npm first on PATH and TMPDIR private.
st_run() {
  cd "$WORK"
  PATH="$BATS_TEST_TMPDIR/bin:$PATH" TMPDIR="$BATS_TEST_TMPDIR/tmp" run --separate-stderr "$BASH_BIN" "$ST_RUN" "$CONSUMER" "stage-fixture"
}

# line_of <label>: the report line for a check (stdout is the report).
line_of() {
  printf '%s\n' "$output" | grep -F -- "$1" | head -n 1
}

@test "good consumer: the smoke test is reported twice, both PASS, each naming its layout" {
  skill j-good j.good
  write_migrated j-good
  build_consumer
  st_run
  [ "$status" -eq 0 ]
  [[ "$(line_of 'skill smoke test (package root)')" == PASS* ]]
  [[ "$(line_of 'skill smoke test (consumer .claude/skills)')" == PASS* ]]
  assert_contains "$(line_of 'skill smoke test (consumer .claude/skills)')" "Execution check: 2 invoked, 2 exited 0"
  # the old single, unlabelled line is gone
  [ -z "$(printf '%s\n' "$output" | grep -E '^(PASS|FAIL|SKIP) +skill smoke test( -|$)' || true)" ]
}

@test "bad consumer: a script that resolves templates/ against .claude fails the consumer check, and only that one" {
  skill j-bad j.bad
  write_unmigrated j-bad
  build_consumer
  st_run
  [ "$status" -eq 0 ]
  [[ "$(line_of 'skill smoke test (package root)')" == PASS* ]]
  local bad
  bad="$(line_of 'skill smoke test (consumer .claude/skills)')"
  [[ "$bad" == FAIL* ]]
  assert_contains "$bad" "names a package asset under the mirror"
  assert_contains "$bad" "/.claude/templates/x.md"
  assert_contains "$output" "VERDICT: fail"
}

@test "a structural defect in the package fails the package-root check by name" {
  skill j-ghost j.ghost
  printf '%s\n' '---' 'name: j.ghost' 'description: Delegates to a missing agent.' 'metadata:' '  prefered_agent: nobody' '---' > "$PKG/skills/j-ghost/SKILL.md"
  build_consumer
  st_run
  [ "$status" -eq 0 ]
  [[ "$(line_of 'skill smoke test (package root)')" == FAIL* ]]
  [[ "$(line_of 'skill smoke test (consumer .claude/skills)')" == FAIL* ]]
}

@test "an installed smoke test without the execution check cannot judge the consumer layout and says so" {
  skill j-good j.good
  write_migrated j-good
  build_consumer
  printf '%s\n' '#!/usr/bin/env bash' 'echo "an older smoke test" >&2' 'exit 0' > "$CONSUMER/node_modules/@jenga-ai/agent/skills/j-smoke-test/scripts/smoke-test-skills.sh"
  st_run
  [ "$status" -eq 0 ]
  [[ "$(line_of 'skill smoke test (package root)')" == PASS* ]]
  local old
  old="$(line_of 'skill smoke test (consumer .claude/skills)')"
  [[ "$old" == FAIL* ]]
  assert_contains "$old" "no execution check"
}

@test "a consumer whose postinstall mirrored nothing fails the consumer check, not the package check" {
  skill j-good j.good
  write_migrated j-good
  build_consumer
  rm -rf "$CONSUMER/.claude/skills"
  st_run
  [ "$status" -eq 0 ]
  [[ "$(line_of 'skill smoke test (package root)')" == PASS* ]]
  local c
  c="$(line_of 'skill smoke test (consumer .claude/skills)')"
  [[ "$c" == FAIL* ]]
  assert_contains "$c" "did not mirror the skills"
}

@test "the step needs neither a new argument nor the network: the usage line is unchanged" {
  run grep -n '^# Usage: st-test-run.sh <st-test-path> <stage-id> \[<package-name>\]$' "$ST_RUN"
  [ "$status" -eq 0 ]
  run "$BASH_BIN" -n "$ST_RUN"
  [ "$status" -eq 0 ]
  [ -x /bin/bash ] && run /bin/bash -n "$ST_RUN"
  [ "$status" -eq 0 ]
}
