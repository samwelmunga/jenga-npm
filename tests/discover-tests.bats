#!/usr/bin/env bats
#
# Coverage for skills/j-test/scripts/discover-tests.sh (E72_S01_T03).
#
# The script is built by E72_S01_T01 (JSON contract, npm/bats/shellcheck) and E72_S01_T02 (pytest/go/cargo and the
# test-config.json overlay). This suite makes its "deterministic, idempotent, graceful" claims checkable by running it
# over purpose-built fixture projects under tests/fixtures/test-discovery/, each carrying a committed expected.json.
#
# How the cases are written
#   - Output is compared as canonicalised JSON (`jq -S .`) against the fixture's expected.json, never as a substring of
#     the raw text, because a substring check passes on malformed output. Where a property matters on its own (an id
#     is absent, a warning is present) a jq query asserts it as well, so a failure points at the claim.
#   - The script runs under a CONTROLLED PATH: a temp bin of symlinks to the tools it needs and nothing else. In
#     particular `shellcheck` is never on it unless a test puts a stand-in there, so `shellcheck:all` cannot make the
#     expected files depend on whether the host has shellcheck installed.
#   - Fixtures are inert trees: no executable bit, no real test construct (no @test, def test_, func Test or live
#     #[test]), npm scripts are echo no-ops. One case enforces that, so a stray runner cannot execute fixture code.
#   - Everything scratch lives under BATS_TEST_TMPDIR. The fixtures themselves are only read.
#
# `empty/` carries a config with an empty tools array on purpose: since E72_S01_T02 an absent test-config.json adds a
# `not found` warning, so `{"suites":[],"warnings":[]}` is only reachable with a valid config present.

bats_require_minimum_version 1.5.0

load helpers/assertions

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
DISCOVER="$REPO_ROOT/skills/j-test/scripts/discover-tests.sh"
FIXTURES="$REPO_ROOT/tests/fixtures/test-discovery"
BASH_BIN="$(command -v bash)"

FIXTURE_NAMES="npm-multi bats-nested pytest-conventions go-and-cargo empty broken-config config-overlay"
NO_CONFIG_WARNING="test-config.json not found; reporting detected suites only"

# Every tool the script (and scripts/resolve-root.sh) invokes, minus jq and shellcheck, which are decided per test.
BIN_TOOLS="bash find sort uniq awk sed grep cat dirname basename head tail tr wc cut mkdir date uname env git readlink realpath xargs ls"

# make_bin <dir> [with-jq|no-jq]: a PATH directory of symlinks to the real tools.
make_bin() {
  local dir="$1" jq_mode="${2:-with-jq}" tool path
  mkdir -p "$dir"
  for tool in $BIN_TOOLS; do
    path="$(command -v "$tool" 2>/dev/null)" || continue
    case "$path" in /*) ln -s "$path" "$dir/$tool" ;; esac
  done
  if [ "$jq_mode" = "with-jq" ]; then
    path="$(command -v jq)"
    ln -s "$path" "$dir/jq"
  fi
}

setup() {
  BIN="$BATS_TEST_TMPDIR/bin"
  make_bin "$BIN"
  LOCKED_DIR=""
}

# An unreadable directory must never outlive a test: bats removes BATS_TEST_TMPDIR afterwards and cannot descend into
# a mode 000 directory.
teardown() {
  if [ -n "${LOCKED_DIR:-}" ] && [ -d "$LOCKED_DIR" ]; then
    chmod u+rwx "$LOCKED_DIR" || true
  fi
}

# --- helpers -------------------------------------------------------------------------------------------------------

# discover <args...>: run the script under the controlled PATH; sets $status, $output (stdout) and $stderr.
discover() {
  run --separate-stderr env PATH="$BIN" "$BASH_BIN" "$DISCOVER" "$@"
}

# discover_to_file <outfile> <args...>: stdout to a file, byte for byte. DISC_LOCALE, when set, becomes LC_ALL.
discover_to_file() {
  local out="$1"
  shift
  env PATH="$BIN" LC_ALL="${DISC_LOCALE:-}" "$BASH_BIN" "$DISCOVER" "$@" > "$out" 2>/dev/null
}

# paths_dialect_check: against $output, every suite has a `paths` array of strings, sorted (byte order) and unique, and
# every entry sticks to the glob dialect: no leading ./ or /, none of [ ] { } \ !, and ** only as a whole segment.
paths_dialect_check() {
  json_check 'all(.suites[];
                  (.paths | type) == "array"
                  and all(.paths[]; type == "string"
                          and (startswith("./") | not) and (startswith("/") | not)
                          and (test("[\\[\\]{}\\\\!]") | not)
                          and all(split("/")[]; (contains("**") | not) or . == "**"))
                  and .paths == (.paths | sort | unique))'
}

# json_check <jq filter> [jq args...]: the filter must be truthy against $output (jq -e).
json_check() {
  local filter="$1"
  shift
  if ! printf '%s' "$output" | jq -e "$@" "$filter" > /dev/null; then
    echo "jq assertion failed: $filter"
    echo "--- output ---"
    echo "$output"
    return 1
  fi
}

# fixture_matches <name>: the script's output over fixtures/<name> equals its expected.json, canonicalised.
fixture_matches() {
  local name="$1" actual expected
  discover --root "$FIXTURES/$name"
  [ "$status" -eq 0 ]
  [ -z "$stderr" ] || { printf 'unexpected stderr: %s\n' "$stderr" >&3; false; }
  actual="$(printf '%s' "$output" | jq -S .)"
  expected="$(jq -S . "$FIXTURES/$name/expected.json")"
  if [ "$actual" != "$expected" ]; then
    echo "output differs from $name/expected.json (< expected, > actual):"
    diff <(printf '%s\n' "$expected") <(printf '%s\n' "$actual") || true
    return 1
  fi
}

# ===================================================================================================================
# Expected output per fixture
# ===================================================================================================================

@test "npm-multi: output matches expected.json" {
  fixture_matches npm-multi
}

@test "bats-nested: output matches expected.json" {
  fixture_matches bats-nested
}

@test "pytest-conventions: output matches expected.json" {
  fixture_matches pytest-conventions
}

@test "go-and-cargo: output matches expected.json" {
  fixture_matches go-and-cargo
}

@test "empty: output matches expected.json" {
  fixture_matches empty
}

@test "broken-config: output matches expected.json" {
  fixture_matches broken-config
}

@test "config-overlay: output matches expected.json" {
  fixture_matches config-overlay
}

@test "every directory under tests/fixtures/test-discovery has an expected.json and a case above" {
  local dir name
  for dir in "$FIXTURES"/*/; do
    name="$(basename "$dir")"
    [ -f "$dir/expected.json" ]
    jq -e . "$dir/expected.json" > /dev/null
    case " $FIXTURE_NAMES " in
      *" $name "*) ;;
      *) echo "fixture $name is not in FIXTURE_NAMES, so the loops below skip it"; return 1 ;;
    esac
  done
  for name in $FIXTURE_NAMES; do
    [ -d "$FIXTURES/$name" ]
  done
}

# ===================================================================================================================
# Per-fixture properties the expected files encode, asserted on their own
# ===================================================================================================================

@test "npm-multi: only test and test[:-]* scripts, mapped to types; unrecognised suffix is unknown" {
  discover --root "$FIXTURES/npm-multi"
  [ "$status" -eq 0 ]
  json_check '[.suites[].id] == ["npm:test","npm:test-integration","npm:test:e2e","npm:test:smoke","npm:test:unit"]'
  json_check '.suites[] | select(.id == "npm:test") | .type == "unit" and .command == "npm test"'
  json_check '.suites[] | select(.id == "npm:test:smoke") | .type == "unknown" and .command == "npm run test:smoke"'
  json_check '.suites[] | select(.id == "npm:test-integration") | .type == "integration"'
  json_check '.suites[] | select(.id == "npm:test:e2e") | .type == "e2e"'
  # pretest and build are scripts but not test scripts.
  json_check '[.suites[].id] | any(. == "npm:pretest" or . == "npm:build") | not'
}

@test "bats-nested: one suite per directory, not per file; config copies the command, no warnings" {
  discover --root "$FIXTURES/bats-nested"
  [ "$status" -eq 0 ]
  # Three files in two directories.
  json_check '[.suites[] | select(.ecosystem == "bats") | .id] == ["bats:integration/deep","bats:unit"]'
  json_check '.suites[] | select(.id == "bats:unit") | .command == "bats unit/*.bats"'
  # The repo's own pattern: bats listed as unit and integration. The integration entry is a config suite carrying the
  # first detected bats command, and it is not a warning.
  json_check '.suites[] | select(.id == "config:bats:integration")
              | .ecosystem == "config" and .type == "integration" and .command == "bats integration/deep/*.bats"'
  json_check '.warnings == []'
}

@test "pytest-conventions: test_*.py and *_test.py suites, marker-only dirs, decoys and venv skipped" {
  discover --root "$FIXTURES/pytest-conventions"
  [ "$status" -eq 0 ]
  json_check '[.suites[].id] == ["pytest:Upper","pytest:markers","pytest:pkg","pytest:tests","pytest:tools"]'
  # tests/test_alpha.py and pkg/beta_test.py: both naming conventions.
  json_check '[.suites[] | select(.id == "pytest:tests" or .id == "pytest:pkg") | .command] == ["pytest pkg","pytest tests"]'
  # The root conftest.py sits above test-file directories, which already cover it: no second suite re-running them.
  json_check '[.suites[].id] | index("pytest:.") == null'
  # Marker-only directories (pytest.ini, a pyproject.toml with the pytest table) are suites; a pyproject without it
  # is not.
  json_check '[.suites[].id] | (index("pytest:markers") != null) and (index("pytest:tools") != null) and (index("pytest:plain") == null)'
  # site-packages is a dependency's tests, not the project's.
  json_check '[.suites[].id] | any(contains("venv")) | not'
}

@test "go-and-cargo: go packages (testdata skipped), cargo unit and per-file integration ids" {
  discover --root "$FIXTURES/go-and-cargo"
  [ "$status" -eq 0 ]
  json_check '[.suites[].id] == ["cargo:integration:api","cargo:unit","go:.","go:pkg/alpha"]'
  json_check '.suites[] | select(.id == "go:.") | .command == "go test ./..."'
  json_check '.suites[] | select(.id == "go:pkg/alpha") | .command == "go test ./pkg/alpha/..."'
  json_check '.suites[] | select(.id == "cargo:unit") | .command == "cargo test --lib" and .type == "unit"'
  json_check '.suites[] | select(.id == "cargo:integration:api")
              | .command == "cargo test --test api" and .type == "integration"'
  # tests/common.rs has no #[test]; pkg/testdata is not a package.
  json_check '[.suites[].id] | any(contains("common") or contains("testdata")) | not'
}

@test "empty: exactly {\"suites\":[],\"warnings\":[]}, exit 0, nothing on stderr" {
  discover --root "$FIXTURES/empty"
  [ "$status" -eq 0 ]
  [ -z "$stderr" ] || { printf 'unexpected stderr: %s\n' "$stderr" >&3; false; }
  [ "$output" = '{"suites":[],"warnings":[]}' ]
}

@test "a directory with no files and no config: no suites, exit 0, the not-found warning only" {
  mkdir -p "$BATS_TEST_TMPDIR/bare"
  discover --root "$BATS_TEST_TMPDIR/bare"
  [ "$status" -eq 0 ]
  [ -z "$stderr" ] || { printf 'unexpected stderr: %s\n' "$stderr" >&3; false; }
  [ "$output" = "{\"suites\":[],\"warnings\":[\"$NO_CONFIG_WARNING\"]}" ]
}

@test "broken-config: exit 0, the npm suite is still detected, the not-valid-JSON warning is present" {
  discover --root "$FIXTURES/broken-config"
  [ "$status" -eq 0 ]
  [ -z "$stderr" ] || { printf 'unexpected stderr: %s\n' "$stderr" >&3; false; }
  json_check '[.suites[].id] == ["npm:test"]'
  json_check '.warnings | any(startswith("test-config.json is not valid JSON"))'
}

@test "no test-config.json: exit 0 and the not-found warning, with detection unaffected" {
  local name
  for name in npm-multi pytest-conventions go-and-cargo; do
    [ ! -e "$FIXTURES/$name/project/configs/test-config.json" ]
    discover --root "$FIXTURES/$name"
    [ "$status" -eq 0 ]
    # shellcheck disable=SC2016 # $w is a jq variable, not a shell expansion
    json_check '.warnings == [$w]' --arg w "$NO_CONFIG_WARNING"
    json_check '.suites | length > 0'
  done
}

@test "config-overlay: a configured tool missing from disk appears as a config suite with a warning" {
  discover --root "$FIXTURES/config-overlay"
  [ "$status" -eq 0 ]
  # Listed, not detected: ecosystem config, nothing known to run (empty command), and a warning naming it.
  json_check '.suites[] | select(.id == "config:playwright:e2e")
              | .ecosystem == "config" and .type == "e2e" and .command == ""'
  json_check '.warnings | index("configured tool not detected on disk: playwright (e2e)") != null'
  # npm is listed as unit and integration and detected: the integration entry borrows the detected command.
  json_check '.suites[] | select(.id == "config:npm:integration") | .ecosystem == "config" and .command == "npm test"'
  # pytest is detected but configured only as integration: the detected suite takes the configured type.
  json_check '.suites[] | select(.id == "pytest:tests") | .type == "integration" and .command == "pytest tests"'
  # The "-" placeholder is silent: no suite, no warning.
  json_check '[.suites[].type] | index("sast") == null'
  json_check '.warnings | any(contains("(sast)")) | not'
  # A tools entry without a string tool_name is counted, not fatal.
  json_check '.warnings | index("test-config.json: ignored 1 tools entries without a string tool_name and type") != null'
}

@test "a detected tool that the config does not list is kept and warned about" {
  local proj="$BATS_TEST_TMPDIR/proj"
  mkdir -p "$proj/project/configs" "$proj/specs"
  printf '{"scripts":{"test":"echo inert"}}\n' > "$proj/package.json"
  printf '# inert\n' > "$proj/specs/a.bats"
  printf '{"tools":[{"tool_name":"npm","type":"unit"}]}\n' > "$proj/project/configs/test-config.json"
  discover --root "$proj"
  [ "$status" -eq 0 ]
  json_check '[.suites[].id] == ["bats:specs","npm:test"]'
  json_check '.warnings == ["detected tool not listed in test-config.json: bats"]'
}

@test "an unreadable directory is skipped with a could-not-read warning, exit 0, nothing on stderr" {
  if [ "$(id -u)" -eq 0 ]; then
    skip "running as root: chmod 000 does not deny access to root, so this case would pass vacuously"
  fi
  local tree="$BATS_TEST_TMPDIR/unreadable"
  mkdir -p "$tree/ok" "$tree/locked"
  printf '# inert\n' > "$tree/ok/a.bats"
  printf '# inert\n' > "$tree/locked/b.bats"
  LOCKED_DIR="$tree/locked"
  chmod 000 "$LOCKED_DIR" || skip "chmod is not permitted here, so no directory can be made unreadable"
  if ls "$LOCKED_DIR" > /dev/null 2>&1; then
    skip "chmod 000 did not deny access on this filesystem, so this case would pass vacuously"
  fi
  discover --root "$tree"
  [ "$status" -eq 0 ]
  [ -z "$stderr" ] || { printf 'unexpected stderr: %s\n' "$stderr" >&3; false; }
  json_check '.warnings | index("could not read locked; skipped") != null'
  # Everything readable is still reported.
  json_check '[.suites[] | select(.ecosystem == "bats") | .id] == ["bats:ok"]'
}

# ===================================================================================================================
# Output shape and the contract's own rules
# ===================================================================================================================

@test "every fixture: one compact JSON line, keys suites then warnings, suite fields in contract order" {
  local name
  for name in $FIXTURE_NAMES; do
    discover --root "$FIXTURES/$name"
    [ "$status" -eq 0 ]
    [ "${#lines[@]}" -eq 1 ]
    assert_starts_with "$output" '{"suites":['
    json_check 'keys_unsorted == ["suites","warnings"]'
    json_check '(.warnings | type) == "array"'
    # E72_S03_T01: `paths` is the sixth and last key; the first five and their order are unchanged.
    json_check 'all(.suites[]; keys_unsorted == ["id","name","type","ecosystem","command","paths"])'
    json_check '[.suites[].id] | (unique | length) == length'
    # shellcheck disable=SC2016 # $t is a jq variable, not a shell expansion
    json_check 'all(.suites[]; .type as $t
                    | ["unit","integration","e2e","sast","vulnerability","performance","coverage","unknown"]
                    | index($t) != null)'
  done
}

@test "ids and warnings are in byte order, whatever the locale" {
  local name ids sorted
  for name in $FIXTURE_NAMES; do
    discover --root "$FIXTURES/$name"
    [ "$status" -eq 0 ]
    ids="$(printf '%s' "$output" | jq -r '.suites[].id')"
    sorted="$(printf '%s\n' "$ids" | LC_ALL=C sort)"
    [ "$ids" = "$sorted" ]
    ids="$(printf '%s' "$output" | jq -r '.warnings[]')"
    sorted="$(printf '%s\n' "$ids" | LC_ALL=C sort)"
    [ "$ids" = "$sorted" ]
  done
  # Fixtures chosen so that a locale-aware sort would reorder them: '-' before ':', and an uppercase directory name.
  discover --root "$FIXTURES/npm-multi"
  json_check '[.suites[].id] | index("npm:test-integration") < index("npm:test:e2e")'
  discover --root "$FIXTURES/pytest-conventions"
  json_check '[.suites[].id] | index("pytest:Upper") < index("pytest:markers")'
}

# ===================================================================================================================
# Determinism
# ===================================================================================================================

@test "determinism: two runs over every fixture are byte-identical" {
  local name
  for name in $FIXTURE_NAMES; do
    discover_to_file "$BATS_TEST_TMPDIR/first.out" --root "$FIXTURES/$name"
    discover_to_file "$BATS_TEST_TMPDIR/second.out" --root "$FIXTURES/$name"
    [ -s "$BATS_TEST_TMPDIR/first.out" ]
    cmp "$BATS_TEST_TMPDIR/first.out" "$BATS_TEST_TMPDIR/second.out"
  done
}

@test "determinism: output is byte-identical under LC_ALL=C and LC_ALL=en_US.UTF-8" {
  local name
  for name in $FIXTURE_NAMES; do
    DISC_LOCALE=C discover_to_file "$BATS_TEST_TMPDIR/c.out" --root "$FIXTURES/$name"
    DISC_LOCALE=en_US.UTF-8 discover_to_file "$BATS_TEST_TMPDIR/en.out" --root "$FIXTURES/$name"
    [ -s "$BATS_TEST_TMPDIR/c.out" ]
    cmp "$BATS_TEST_TMPDIR/c.out" "$BATS_TEST_TMPDIR/en.out"
  done
}

@test "determinism: running discovery leaves the fixture tree unchanged and writes no file" {
  local name before after
  # Every file (with a checksum) and every directory, so a created file or directory shows up as well as an edit.
  before="$(cd "$FIXTURES" && { find . -type d; find . -type f -exec cksum {} +; } | sort)"
  for name in $FIXTURE_NAMES; do
    discover --root "$FIXTURES/$name"
    [ "$status" -eq 0 ]
  done
  after="$(cd "$FIXTURES" && { find . -type d; find . -type f -exec cksum {} +; } | sort)"
  [ -n "$before" ]
  [ "$before" = "$after" ]
}

# ===================================================================================================================
# Detecting shellcheck is deterministic given PATH, and fixtures never depend on the host
# ===================================================================================================================

@test "shellcheck absent from PATH: no shellcheck suite and no warning, on a tree with no shell files" {
  [ ! -e "$BIN/shellcheck" ]
  discover --root "$FIXTURES/empty"
  [ "$status" -eq 0 ]
  [ "$output" = '{"suites":[],"warnings":[]}' ]
}

@test "shellcheck on PATH: shellcheck:all is emitted as a sast suite even with no .sh files" {
  # A stand-in that is only ever located by `command -v`, never run: detection must not execute anything.
  printf '#!/bin/sh\necho "stand-in must not be executed" >&2\nexit 99\n' > "$BIN/shellcheck"
  chmod +x "$BIN/shellcheck"
  discover --root "$FIXTURES/empty"
  [ "$status" -eq 0 ]
  [ -z "$stderr" ] || { printf 'unexpected stderr: %s\n' "$stderr" >&3; false; }
  json_check '[.suites[] | [.id, .type, .ecosystem]] == [["shellcheck:all","sast","shellcheck"]]'
  json_check '.suites[0].command | startswith("find . -type f -name")'
}

# ===================================================================================================================
# Shapes of command and id the contract leaves to the detectors
# ===================================================================================================================

@test "a bats directory at the root is bats:. with command bats ./*.bats" {
  local proj="$BATS_TEST_TMPDIR/rootbats"
  mkdir -p "$proj"
  printf '# inert\n' > "$proj/a.bats"
  discover --root "$proj"
  [ "$status" -eq 0 ]
  json_check '.suites == [{"id":"bats:.","name":"bats .","type":"unit","ecosystem":"bats","command":"bats ./*.bats","paths":["*.bats"]}]'
}

@test "a directory name with a space is shell-quoted in the command, never split" {
  local proj="$BATS_TEST_TMPDIR/spaced"
  mkdir -p "$proj/my dir"
  printf '# inert\n' > "$proj/my dir/b.bats"
  discover --root "$proj"
  [ "$status" -eq 0 ]
  json_check '.suites[0] | .id == "bats:my dir" and .command == "bats my\\ dir/*.bats"'
}

@test "dot-directories and node_modules are not scanned" {
  local proj="$BATS_TEST_TMPDIR/pruned"
  mkdir -p "$proj/.hidden" "$proj/node_modules/dep" "$proj/real"
  printf '# inert\n' > "$proj/.hidden/c.bats"
  printf '# inert\n' > "$proj/node_modules/dep/d.bats"
  printf '# inert\n' > "$proj/real/e.bats"
  discover --root "$proj"
  [ "$status" -eq 0 ]
  json_check '[.suites[].id] == ["bats:real"]'
}

# --- fixture trees are pruned (E72_S02_T01) ------------------------------------------------------------------------
# Directories named `fixtures` or `__fixtures__` hold inert test data, never suites. Every tree below is built under
# BATS_TEST_TMPDIR; nothing is added to the committed fixtures directory.

@test "a bats file under tests/fixtures/ is not a suite; the sibling tests/ one is" {
  local proj="$BATS_TEST_TMPDIR/prune-bats"
  mkdir -p "$proj/tests/fixtures/inner"
  printf '# inert\n' > "$proj/tests/real.bats"
  printf '# inert\n' > "$proj/tests/fixtures/inner/x.bats"
  discover --root "$proj"
  [ "$status" -eq 0 ]
  json_check '[.suites[].id] == ["bats:tests"]'
}

@test "a pytest file under __fixtures__/ is not a suite; the sibling tests/ one is" {
  local proj="$BATS_TEST_TMPDIR/prune-pytest"
  mkdir -p "$proj/__fixtures__" "$proj/tests"
  printf '# inert\n' > "$proj/__fixtures__/test_x.py"
  printf '# inert\n' > "$proj/tests/test_y.py"
  discover --root "$proj"
  [ "$status" -eq 0 ]
  json_check '[.suites[].id] == ["pytest:tests"]'
}

@test "go packages under testdata/ and fixtures/ are skipped, a real sibling package is kept" {
  local proj="$BATS_TEST_TMPDIR/prune-go"
  mkdir -p "$proj/pkg/testdata/a" "$proj/pkg/fixtures/b" "$proj/deep/er/fixtures/c" "$proj/real"
  printf '// inert\n' > "$proj/pkg/testdata/a/a_test.go"
  printf '// inert\n' > "$proj/pkg/fixtures/b/b_test.go"
  printf '// inert\n' > "$proj/deep/er/fixtures/c/c_test.go"
  printf '// inert\n' > "$proj/real/real_test.go"
  discover --root "$proj"
  [ "$status" -eq 0 ]
  json_check '[.suites[].id] == ["go:real"]'
}

@test "a scan root that is itself named fixtures is still scanned; only components below it are pruned" {
  local proj="$BATS_TEST_TMPDIR/fixtures/inner"
  mkdir -p "$proj/tests" "$proj/fixtures/skipped"
  printf '# inert\n' > "$proj/tests/real.bats"
  printf '# inert\n' > "$proj/fixtures/skipped/x.bats"
  discover --root "$proj"
  [ "$status" -eq 0 ]
  json_check '[.suites[].id] == ["bats:tests"]'
}

@test "discovery over this repo lists no suite from a fixtures tree" {
  discover --root "$REPO_ROOT"
  [ "$status" -eq 0 ]
  json_check '[.suites[] | select((.id | contains("/fixtures/")) or (.command | contains("/fixtures/")))] | length == 0'
  json_check '[.suites[].id] | index("bats:tests") != null'
}

# ===================================================================================================================
# Command line
# ===================================================================================================================

@test "--help exits 0 and prints the usage on stdout" {
  discover --help
  [ "$status" -eq 0 ]
  assert_starts_with "$output" "Usage: discover-tests.sh"
  assert_output_contains "--root"
  [ -z "$stderr" ] || { printf 'unexpected stderr: %s\n' "$stderr" >&3; false; }
}

@test "an unknown flag exits 2 with a message on stderr and nothing on stdout" {
  discover --bogus
  [ "$status" -eq 2 ]
  [ -z "$output" ]
  assert_contains "$stderr" "unknown argument: --bogus"
}

@test "--root without a value exits 2" {
  discover --root
  [ "$status" -eq 2 ]
  [ -z "$output" ]
  assert_contains "$stderr" "--root requires a directory argument"
}

@test "--root naming a path that is not a directory exits 2" {
  discover --root "$BATS_TEST_TMPDIR/does-not-exist"
  [ "$status" -eq 2 ]
  [ -z "$output" ]
  assert_contains "$stderr" "--root is not a directory"
}

@test "--root on a fixture path gives that fixture's output, not the surrounding repo's" {
  discover --root "$FIXTURES/go-and-cargo"
  [ "$status" -eq 0 ]
  json_check '[.suites[].ecosystem] | unique == ["cargo","go"]'
  json_check '[.suites[].id] | any(startswith("npm:") or startswith("bats:")) | not'
}

@test "without --root the root comes from JENGA_PROJECT_ROOT, and its own test-config.json applies" {
  local proj="$BATS_TEST_TMPDIR/rooted" actual expected
  mkdir -p "$proj/project/configs"
  printf '{"paths":{"configs":"project/configs"}}\n' > "$proj/project/configs/workflow.json"
  cp "$FIXTURES/npm-multi/package.json" "$proj/package.json"

  run --separate-stderr env PATH="$BIN" JENGA_PROJECT_ROOT="$proj" "$BASH_BIN" "$DISCOVER"
  [ "$status" -eq 0 ]
  actual="$(printf '%s' "$output" | jq -S .)"
  expected="$(jq -S . "$FIXTURES/npm-multi/expected.json")"
  [ "$actual" = "$expected" ]

  printf '{"tools":[{"tool_name":"npm","type":"unit"}]}\n' > "$proj/project/configs/test-config.json"
  run --separate-stderr env PATH="$BIN" JENGA_PROJECT_ROOT="$proj" "$BASH_BIN" "$DISCOVER"
  [ "$status" -eq 0 ]
  json_check '.warnings == []'
  json_check '.suites | length == 5'
}

@test "without jq on PATH it exits 1 and names jq on stderr" {
  local nojq="$BATS_TEST_TMPDIR/bin-no-jq"
  make_bin "$nojq" no-jq
  run --separate-stderr env PATH="$nojq" "$BASH_BIN" "$DISCOVER" --root "$FIXTURES/empty"
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  assert_contains "$stderr" "jq"
}

# ===================================================================================================================
# The fixtures themselves are inert
# ===================================================================================================================

@test "fixture trees contain no executable test: no exec bit, no real test construct, echo-only npm scripts" {
  local manifest
  run find "$FIXTURES" -type f -perm -u+x
  [ -z "$output" ]

  run grep -rnE '^@test' "$FIXTURES"
  [ "$status" -eq 1 ]
  run grep -rnE '^[[:space:]]*(async )?(def test_|func Test)' "$FIXTURES"
  [ "$status" -eq 1 ]
  # #[test] is the marker cargo detection greps for; in a fixture it may only sit after a // comment opener.
  run grep -rnE '^[^/]*#\[test\]' "$FIXTURES"
  [ "$status" -eq 1 ]

  while IFS= read -r manifest; do
    jq -e '[.scripts[]] | all(startswith("echo inert fixture"))' "$manifest" > /dev/null
  done <<EOF
$(find "$FIXTURES" -type f -name package.json)
EOF
}

# ===================================================================================================================
# The `paths` field (E72_S03_T01): which test files a suite runs, as globs in the shared dialect
# ===================================================================================================================

@test "paths: bats suites run <dir>/*.bats, not recursive; a config suite inherits from the suite it copies" {
  discover --root "$FIXTURES/bats-nested"
  [ "$status" -eq 0 ]
  json_check '.suites[] | select(.id == "bats:unit") | .paths == ["unit/*.bats"]'
  json_check '.suites[] | select(.id == "bats:integration/deep") | .paths == ["integration/deep/*.bats"]'
  # config:bats:integration copies the command of the first detected bats suite (lowest id) and so its paths.
  json_check '.suites[] | select(.id == "config:bats:integration") | .paths == ["integration/deep/*.bats"]'
}

@test "paths: pytest suites run <dir>/**/*_test.py and <dir>/**/test_*.py, sorted" {
  discover --root "$FIXTURES/pytest-conventions"
  [ "$status" -eq 0 ]
  json_check '.suites[] | select(.id == "pytest:tests") | .paths == ["tests/**/*_test.py","tests/**/test_*.py"]'
  json_check '.suites[] | select(.id == "pytest:Upper") | .paths == ["Upper/**/*_test.py","Upper/**/test_*.py"]'
  # A marker-only directory is a suite too and gets the same globs for its directory.
  json_check '.suites[] | select(.id == "pytest:markers") | .paths == ["markers/**/*_test.py","markers/**/test_*.py"]'
}

@test "paths: go package, go root (go test ./...), cargo unit and cargo integration" {
  discover --root "$FIXTURES/go-and-cargo"
  [ "$status" -eq 0 ]
  json_check '.suites[] | select(.id == "go:pkg/alpha") | .paths == ["pkg/alpha/*_test.go"]'
  json_check '.suites[] | select(.id == "go:.") | .paths == ["**/*_test.go"]'
  json_check '.suites[] | select(.id == "cargo:unit") | .paths == ["src/**/*.rs"]'
  json_check '.suites[] | select(.id == "cargo:integration:api") | .paths == ["tests/api.rs"]'
}

@test "paths: root-level bats and pytest suites carry no directory prefix" {
  local proj="$BATS_TEST_TMPDIR/rootsuites"
  mkdir -p "$proj"
  printf '# inert\n' > "$proj/a.bats"
  printf '# inert\n' > "$proj/test_a.py"
  discover --root "$proj"
  [ "$status" -eq 0 ]
  json_check '.suites[] | select(.id == "bats:.") | .paths == ["*.bats"]'
  json_check '.suites[] | select(.id == "pytest:.") | .paths == ["**/*_test.py","**/test_*.py"]'
  paths_dialect_check
}

@test "paths: npm suites, shellcheck:all and a config-only suite are []; a retyped detected suite keeps its paths" {
  discover --root "$FIXTURES/npm-multi"
  [ "$status" -eq 0 ]
  json_check 'all(.suites[]; .paths == [])'
  discover --root "$FIXTURES/config-overlay"
  [ "$status" -eq 0 ]
  json_check '.suites[] | select(.id == "config:playwright:e2e") | .command == "" and .paths == []'
  # The configured type is integration, not the detected unit: the suite is retyped and keeps its globs.
  json_check '.suites[] | select(.id == "pytest:tests") | .type == "integration" and .paths == ["tests/**/*_test.py","tests/**/test_*.py"]'
  # config:npm:integration inherits the command of an npm suite whose own paths are [].
  json_check '.suites[] | select(.id == "config:npm:integration") | .command == "npm test" and .paths == []'
  # shellcheck checks sources, not test files; the stand-in is only located, never run.
  printf '#!/bin/sh\nexit 99\n' > "$BIN/shellcheck"
  chmod +x "$BIN/shellcheck"
  discover --root "$FIXTURES/empty"
  [ "$status" -eq 0 ]
  json_check '.suites[] | select(.id == "shellcheck:all") | .paths == []'
}

@test "paths: a directory name holding a glob metacharacter, or !, gets paths [] and a plain sibling keeps its globs" {
  local proj="$BATS_TEST_TMPDIR/meta" d
  mkdir -p "$proj/ok dir"
  printf '# inert\n' > "$proj/ok dir/ok.bats"
  for d in 'a*b' 'q?mark' 'br[ack]ets' 'c{d}' 'we!rd' 'back\slash'; do
    mkdir -p "$proj/$d"
    printf '# inert\n' > "$proj/$d/x.bats"
    printf '# inert\n' > "$proj/$d/test_x.py"
    printf '// inert\n' > "$proj/$d/x_test.go"
  done
  # cargo: an integration test file whose stem holds a metacharacter cannot be expressed either.
  mkdir -p "$proj/tests" "$proj/src"
  printf '[package]\n' > "$proj/Cargo.toml"
  printf '#[test]\n' > "$proj/tests/fine.rs"
  printf '#[test]\n' > "$proj/tests/we*ird.rs"
  discover --root "$proj"
  [ "$status" -eq 0 ]
  json_check '.suites[] | select(.id == "bats:ok dir") | .paths == ["ok dir/*.bats"]'
  json_check '[.suites[] | select(.ecosystem == "bats" or .ecosystem == "pytest" or .ecosystem == "go")
               | select(.id | endswith(":ok dir") | not)] | length == 18'
  json_check '[.suites[] | select(.ecosystem == "bats" or .ecosystem == "pytest" or .ecosystem == "go")
               | select(.id | endswith(":ok dir") | not) | .paths] | all(. == [])'
  json_check '.suites[] | select(.id == "cargo:integration:fine") | .paths == ["tests/fine.rs"]'
  json_check '.suites[] | select(.id == "cargo:integration:we*ird") | .paths == []'
  paths_dialect_check
}

@test "paths: always an array, sorted and unique, and inside the dialect, on every fixture" {
  local name
  for name in $FIXTURE_NAMES; do
    discover --root "$FIXTURES/$name"
    [ "$status" -eq 0 ]
    json_check 'all(.suites[]; has("paths") and (.paths | type) == "array")'
    json_check '[.suites[] | .paths | select(. == null)] | length == 0'
    paths_dialect_check
  done
}

@test "paths: stripping the key from every fixture leaves exactly the pre-E72_S03_T01 contract" {
  local name
  for name in $FIXTURE_NAMES; do
    discover --root "$FIXTURES/$name"
    [ "$status" -eq 0 ]
    json_check 'all(.suites[]; (del(.paths) | keys_unsorted) == ["id","name","type","ecosystem","command"])'
    json_check '(.suites | map(.id)) == (.suites | map(.id) | sort)'
  done
}

@test "paths: computed from the one scan_tree walk, so the tree is walked exactly once" {
  # A `find` stand-in that logs the walks over the scanned tree (recognisable by the pruning of node_modules) and
  # then delegates. Discovery with paths must not add a second walk.
  local real_find log="$BATS_TEST_TMPDIR/find.log"
  real_find="$(command -v find)"
  rm -f "$BIN/find"
  printf '#!/bin/sh\ncase "$*" in *node_modules*) echo walk >> "%s" ;; esac\nexec "%s" "$@"\n' "$log" "$real_find" > "$BIN/find"
  chmod +x "$BIN/find"
  discover --root "$FIXTURES/pytest-conventions"
  [ "$status" -eq 0 ]
  [ -s "$log" ]
  [ "$(wc -l < "$log" | tr -d ' ')" -eq 1 ]
  json_check '.suites[] | select(.id == "pytest:tests") | (.paths | length) == 2'
}
