#!/usr/bin/env bats
#
# E98_S02_T02: the execution phase of skills/j-smoke-test/scripts/smoke-test-skills.sh. It builds a consumer layout
# (package in node_modules/@jenga-ai/agent, .claude/ and .agents/ holding only skills/ and agents/) with
# scripts/consumer-layout-fixture.sh and runs each skill script's --help (or its declared `# smoke-invoke:`) from
# the mirrored .claude/skills, sandboxed to a temp directory.
#
# Everything here uses a synthetic package under BATS_TEST_TMPDIR (a tiny skills/ tree with one stub package-root
# marker) and never executes a script of the live repository. HOME and TMPDIR of every harness run are redirected
# into BATS_TEST_TMPDIR so that "cannot write outside the fixture" can be asserted on a real directory.

# shellcheck disable=SC2016
# SC2016: the fixture scripts are written with single quotes on purpose; they hold literal $ and backticks.

bats_require_minimum_version 1.5.0

load helpers/assertions

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
HARNESS="$REPO_ROOT/skills/j-smoke-test/scripts/smoke-test-skills.sh"
FIXTURE_HELPER="$REPO_ROOT/scripts/consumer-layout-fixture.sh"
RESOLVER="$REPO_ROOT/skills/index/scripts/package-root.sh"
BASH_BIN="$(command -v bash)"

setup() {
  PKG="$BATS_TEST_TMPDIR/pkg"
  REAL_HOME="$BATS_TEST_TMPDIR/real-home"
  REAL_TMP="$BATS_TEST_TMPDIR/real-tmp"
  mkdir -p "$PKG/skills" "$PKG/agents" "$PKG/templates" "$PKG/scripts" "$REAL_HOME" "$REAL_TMP"
  : > "$PKG/agents/developer.md"
  printf '%s\n' '# a package marker' > "$PKG/templates/x.md"
  : > "$PKG/scripts/resolve-root.sh"
  cp "$FIXTURE_HELPER" "$PKG/scripts/consumer-layout-fixture.sh"
  cp "$REPO_ROOT/scripts/never-public-refs.sh" "$PKG/scripts/never-public-refs.sh"
  : > "$PKG/.publicignore"
}

# skill <dir> <name>: a valid skill with no scripts yet.
skill() {
  mkdir -p "$PKG/skills/$1/scripts"
  printf '%s\n' '---' "name: $2" 'description: A perfectly ordinary fixture skill.' '---' '' '# Fixture' > "$PKG/skills/$1/SKILL.md"
}

# resolver_skill: the shared resolver, where a migrated script expects it (skills/index/scripts/package-root.sh).
resolver_skill() {
  mkdir -p "$PKG/skills/index/scripts"
  cp "$RESOLVER" "$PKG/skills/index/scripts/package-root.sh"
}

# harness [args]: runs the harness over $PKG with HOME and TMPDIR pointing at throwaway directories;
# sets $status, $output (findings) and $stderr (summary).
harness() {
  HOME="$REAL_HOME" TMPDIR="$REAL_TMP" run --separate-stderr "$BASH_BIN" "$HARNESS" --root "$PKG" "$@"
}

# finding <check> <skill> <severity>: succeeds when the findings in $output hold that finding.
finding() {
  printf '%s\n' "$output" | jq -e --arg c "$1" --arg s "$2" --arg v "$3" \
    'select(.check == $c and .skill == $s and .severity == $v)' > /dev/null
}

exec_findings() {
  if [ -z "$output" ]; then echo 0; else printf '%s\n' "$output" | jq -r 'select(.check | startswith("exec")) | .check' | grep -c '' || true; fi
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

# --- the five cases ------------------------------------------------------------------------------------------------

@test "a script that finds templates/ with \$SCRIPT_DIR/../../.. fails critical and the exit code is non-zero" {
  skill j-bad j.bad
  write_unmigrated j-bad
  harness
  [ "$status" -eq 1 ]
  finding exec-package-asset j-bad critical
  assert_contains "$output" "cannot read"
  assert_contains "$output" "/.claude/templates/x.md"
  assert_contains "$stderr" "Findings: 1 critical"
  assert_contains "$stderr" "Result: FAIL"
}

@test "the same script migrated to the resolver passes: exit 0 and no execution finding" {
  skill j-good j.good
  resolver_skill
  write_migrated j-good
  harness
  [ "$status" -eq 0 ]
  [ "$(exec_findings)" -eq 0 ]
  assert_contains "$stderr" "Result: PASS"
  assert_contains "$stderr" "Execution check: 1 invoked, 1 exited 0"
}

@test "a script with no safe invocation is listed as unverifiable, counted, not executed and does not fail" {
  skill j-nohelp j.nohelp
  cat > "$PKG/skills/j-nohelp/scripts/run.sh" <<EOF
#!/usr/bin/env bash
# no --help handling here; running it would fail
touch "$BATS_TEST_TMPDIR/ran-marker"
echo "cannot read /x/.claude/templates/y.md" >&2
exit 1
EOF
  harness
  [ "$status" -eq 0 ]
  [ "$(exec_findings)" -eq 0 ]
  assert_contains "$stderr" "Execution check: 0 invoked, 0 exited 0, 1 unverifiable"
  assert_contains "$stderr" "unverifiable: skills/j-nohelp/scripts/run.sh - no --help handling"
  [ ! -e "$BATS_TEST_TMPDIR/ran-marker" ]
}

@test "a script that would write outside the fixture cannot: HOME and TMPDIR are inside the temp directory" {
  skill j-writer j.writer
  cat > "$PKG/skills/j-writer/scripts/run.sh" <<'EOF'
#!/usr/bin/env bash
# smoke-invoke: home
# smoke-invoke: tmp
# smoke-invoke: cwd
case "${1:-}" in
  home) echo "HOME=$HOME" ;;
  tmp) echo "TMPDIR=$TMPDIR" ;;
  cwd) echo "PWD=$PWD" ;;
esac
mkdir -p "$HOME/.claude" && echo escaped > "$HOME/.claude/escaped.txt"
echo escaped > "$HOME/escaped.txt"
echo escaped > "$TMPDIR/escaped.txt"
exit 3
EOF
  harness
  [ "$status" -eq 0 ]
  finding exec-failed j-writer minor
  # where the script thought it was: inside the smoke test's own temp directory, never the real HOME or TMPDIR
  assert_contains "$output" "HOME=$REAL_TMP/jenga-smoke-exec."
  assert_contains "$output" "TMPDIR=$REAL_TMP/jenga-smoke-exec."
  assert_contains "$output" "jenga-smoke-exec."
  assert_contains "$output" "/consumer"
  [ ! -e "$REAL_HOME/escaped.txt" ]
  [ ! -e "$REAL_HOME/.claude" ]
  [ ! -e "$REAL_TMP/escaped.txt" ]
  # the temp directory is removed again when the run ends
  [ -z "$(ls -A "$REAL_TMP")" ]
}

@test "--no-exec skips the phase: nothing is run, no execution finding, the summary says so" {
  skill j-bad j.bad
  write_unmigrated j-bad
  harness --no-exec
  [ "$status" -eq 0 ]
  [ "$(exec_findings)" -eq 0 ]
  assert_contains "$stderr" "Execution check: skipped (--no-exec)"
  assert_contains "$stderr" "Result: PASS"
}

# --- the rest of the contract ----------------------------------------------------------------------------------------

@test "the un-normalised climb (.claude/skills/<s>/scripts/../../../templates) is recognised as a wrong-root path too" {
  skill j-climb j.climb
  cat > "$PKG/skills/j-climb/scripts/run.sh" <<'EOF'
#!/usr/bin/env bash
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
case "${1:-}" in
  --help|-h) echo "template not found: $SCRIPT_DIR/../../../templates/x.md" >&2; exit 2 ;;
esac
EOF
  harness
  [ "$status" -eq 1 ]
  finding exec-package-asset j-climb critical
}

@test "a non-zero exit that names no package asset is minor and quotes the first output line" {
  skill j-other j.other
  cat > "$PKG/skills/j-other/scripts/run.sh" <<'EOF'
#!/usr/bin/env bash
case "${1:-}" in
  --help|-h) echo "something else went wrong" >&2; echo "second line" >&2; exit 4 ;;
esac
EOF
  harness
  [ "$status" -eq 0 ]
  finding exec-failed j-other minor
  assert_contains "$output" "exits 4"
  assert_contains "$output" "something else went wrong"
  [[ "$output" != *"second line"* ]]
}

@test "a script that blocks is stopped by the per-script timeout and reported minor" {
  skill j-slow j.slow
  cat > "$PKG/skills/j-slow/scripts/run.sh" <<'EOF'
#!/usr/bin/env bash
case "${1:-}" in
  --help|-h) sleep 30 ;;
esac
EOF
  harness --exec-timeout 1
  [ "$status" -eq 0 ]
  finding exec-timeout j-slow minor
}

@test "a declared '# smoke-invoke:' runs those arguments, and 'none <reason>' is listed as unverifiable with the reason" {
  skill j-declared j.declared
  cat > "$PKG/skills/j-declared/scripts/status.sh" <<'EOF'
#!/usr/bin/env bash
# smoke-invoke: show --quiet
if [ "${1:-}" = "show" ] && [ "${2:-}" = "--quiet" ]; then echo ok; exit 0; fi
echo "bad invocation: $*" >&2; exit 9
EOF
  cat > "$PKG/skills/j-declared/scripts/mutating.sh" <<'EOF'
#!/usr/bin/env bash
# smoke-invoke: none rewrites the board, no read-only mode
echo "should never run" >&2; exit 9
EOF
  harness
  [ "$status" -eq 0 ]
  [ "$(exec_findings)" -eq 0 ]
  assert_contains "$stderr" "Execution check: 1 invoked, 1 exited 0, 1 unverifiable"
  assert_contains "$stderr" "skills/j-declared/scripts/mutating.sh - declared unverifiable: rewrites the board"
}

@test "maintainer-only skills, test directories and lib files are listed, never executed" {
  skill j-init j.init
  skill j-other2 j.other2
  mkdir -p "$PKG/skills/j-other2/scripts/lib" "$PKG/skills/j-other2/scripts/tests"
  for f in "$PKG/skills/j-init/scripts/run.sh" "$PKG/skills/j-other2/scripts/lib/helper.sh" "$PKG/skills/j-other2/scripts/tests/t.sh"; do
    printf '%s\n' '#!/usr/bin/env bash' "touch \"$BATS_TEST_TMPDIR/ran-\$(basename \"$f\")\"" 'case "$1" in --help) exit 1 ;; esac' > "$f"
  done
  harness
  [ "$status" -eq 0 ]
  [ "$(exec_findings)" -eq 0 ]
  assert_contains "$stderr" "3 unverifiable"
  assert_contains "$stderr" "skills/j-init/scripts/run.sh - maintainer-only"
  assert_contains "$stderr" "skills/j-other2/scripts/lib/helper.sh - sourced library"
  assert_contains "$stderr" "skills/j-other2/scripts/tests/t.sh - test support"
  [ -z "$(ls "$BATS_TEST_TMPDIR" | grep '^ran-' || true)" ]
}

@test "a mirror root: no layout-artefact critical, and its own scripts are executed in a copy of the consumer" {
  skill j-good j.good
  resolver_skill
  write_migrated j-good
  local consumer="$BATS_TEST_TMPDIR/consumer"
  "$BASH_BIN" "$FIXTURE_HELPER" "$consumer" "$PKG" > /dev/null
  cd "$consumer"
  HOME="$REAL_HOME" TMPDIR="$REAL_TMP" run --separate-stderr "$BASH_BIN" "$HARNESS" --root "$consumer/.claude" --package-root "$consumer/node_modules/@jenga-ai/agent"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  assert_contains "$stderr" "Execution check: 1 invoked, 1 exited 0"
  assert_contains "$stderr" "Result: PASS"
}

@test "a mirror root with an unmigrated script fails critical, and the real consumer is left untouched" {
  skill j-bad j.bad
  write_unmigrated j-bad
  local consumer="$BATS_TEST_TMPDIR/consumer"
  "$BASH_BIN" "$FIXTURE_HELPER" "$consumer" "$PKG" > /dev/null
  cd "$consumer"
  HOME="$REAL_HOME" TMPDIR="$REAL_TMP" run --separate-stderr "$BASH_BIN" "$HARNESS" --root "$consumer/.claude" --package-root "$consumer/node_modules/@jenga-ai/agent"
  [ "$status" -eq 1 ]
  finding exec-package-asset j-bad critical
  [ -z "$(cd "$consumer" && git status --porcelain 2>/dev/null | grep -v '^??' || true)" ]
  [ -z "$(ls -A "$REAL_TMP")" ]
}

@test "a mirror root with no discoverable package skips the phase with a note, not a failure" {
  skill j-good j.good
  local mirror="$BATS_TEST_TMPDIR/lonely/.claude"
  mkdir -p "$mirror"
  cp -R "$PKG/skills" "$mirror/skills"
  cp -R "$PKG/agents" "$mirror/agents"
  printf '%s\n' '#!/usr/bin/env bash' 'case "$1" in --help) exit 0 ;; esac' > "$mirror/skills/j-good/scripts/run.sh"
  cd "$BATS_TEST_TMPDIR/lonely"
  HOME="$REAL_HOME" TMPDIR="$REAL_TMP" run --separate-stderr "$BASH_BIN" "$HARNESS" --root "$mirror" --package-root "$BATS_TEST_TMPDIR/nowhere"
  [ "$status" -ne 2 ] || assert_contains "$stderr" "never-public-refs"
}

@test "a bad --exec-timeout is a usage error" {
  skill j-good j.good
  harness --exec-timeout 0
  [ "$status" -eq 2 ]
  assert_contains "$stderr" "--exec-timeout"
  harness --exec-timeout abc
  [ "$status" -eq 2 ]
}

@test "when the fixture cannot be built, nothing is silently skipped: a minor finding names the cause" {
  skill j-good j.good
  resolver_skill
  write_migrated j-good
  printf '%s\n' '#!/usr/bin/env bash' 'echo "rsync is required" >&2' 'exit 2' > "$PKG/scripts/consumer-layout-fixture.sh"
  harness
  [ "$status" -eq 0 ]
  finding exec-fixture-failed j-smoke-test minor
  assert_contains "$stderr" "skipped: the consumer-layout fixture could not be built"
}

@test "the wizard scripts that read package assets declare a smoke-invoke the 5.0.1 defect would fail (E98 re-verification remark 1)" {
  R="$(cd "$BATS_TEST_DIRNAME/.." && pwd -P)"
  grep -q '^# smoke-invoke: categories$' "$R/skills/j-conventions/scripts/conventions-entry.sh"
  grep -q '^# smoke-invoke: show --layer project$' "$R/skills/j-tools/scripts/tools-entry.sh"
  grep -q '^# smoke-invoke:$' "$R/skills/j-checklist/scripts/checklist-print.sh"
  grep -q '^# smoke-invoke:$' "$R/skills/j-tidy/scripts/report.sh"
}
