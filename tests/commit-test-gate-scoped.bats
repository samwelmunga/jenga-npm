#!/usr/bin/env bats
#
# Coverage for skills/j-commit/scripts/test-gate-scoped.sh (E72_S04_T02).
#
# The script is option 1 of j.commit's test gate ("test covering committed scope"): it joins map-scope.sh,
# discover-tests.sh and build-catalog.sh into a plan (status, selection, suites, a derived catalog) that E72_S04_T03's
# runner executes through run-suites.sh. It runs no suite itself. Contract under test: the script's header and the task
# text, not the implementation.
#
# How the cases are written
#   - The script locates the j-test scripts through BASH_SOURCE, so every case runs a COPY of it inside a throwaway
#     package tree ($PKG: the script, the real j-test scripts, scripts/resolve-root.sh, the shipped scope map). Only
#     $PKG's discover-tests.sh is replaced, by a stub that counts its calls and prints a fixture, so "discovery runs at
#     most once" is asserted by a call counter and no real discovery of any repository (25-35 s here) ever happens.
#   - Every repository is built by seed_repo inside BATS_TEST_TMPDIR with git isolated from the host. Discovery
#     documents are inline JSON fixtures; a hand-written scope map ($MAP) keeps the mapping independent of the shipped
#     template. Nothing here runs this repository's `npm test`, `bats tests/*.bats` or discovery.
#   - Suite commands are never executed by the script. Where a case does run a plan, it hands the derived catalog to the
#     real run-suites.sh, and the commands are served by exported shell functions (`bats`, `npm`) that only append the
#     arguments they received to $RUN_MARK; the suite needs no executable stub and no chmod.
#   - TMPDIR points at a private directory, so "nothing is written outside --out-dir and ${TMPDIR:-/tmp}" is checked by
#     listing both after the run.
#   - Every script invocation goes through `bash <script>`, so the executable bit is not relied on.
#   - No line below begins with `[[`.

# shellcheck disable=SC2016,SC2030,SC2031,SC2317
# SC2016: jq programs and fixture JSON are single-quoted on purpose. SC2030/SC2031: bats runs each @test in its own
# subshell, so reading $status/$output after `run` is correct. SC2317: the exported stub functions are reached through
# `bash -c` in run-suites.sh, not through a call shellcheck can see.

bats_require_minimum_version 1.5.0

load helpers/assertions

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd -P)"
BASH_BIN="$(command -v bash)"

# Discovery as a typical project would report it. npm has empty paths (a JS test file reaches it by extension). The
# paths on the linter suite are a fixture device (real discovery gives it none) so that a non-test ecosystem can be
# mapped and shown to run whole. config:bats:integration shares bats:tests's command and paths, as it does on this repo.
STD_DISC='{"suites":[
  {"id":"bats:tests","name":"bats tests","type":"unit","ecosystem":"bats","command":"bats tests/*.bats","paths":["tests/*.bats"]},
  {"id":"cargo:integration:it","name":"cargo it","type":"integration","ecosystem":"cargo","command":"cargo test --test it","paths":["tests/it.rs"]},
  {"id":"config:bats:integration","name":"bats (integration)","type":"integration","ecosystem":"config","command":"bats tests/*.bats","paths":["tests/*.bats"]},
  {"id":"go:test","name":"go test","type":"unit","ecosystem":"go","command":"go test ./...","paths":["**/*_test.go"]},
  {"id":"npm:test","name":"npm test","type":"unit","ecosystem":"npm","command":"npm test","paths":[]},
  {"id":"pytest:tests","name":"pytest tests","type":"unit","ecosystem":"pytest","command":"pytest tests","paths":["tests/**/test_*.py"]},
  {"id":"shellcheck:all","name":"shellcheck","type":"sast","ecosystem":"shellcheck","command":"shellcheck -x scripts/*.sh","paths":["scripts/*.sh"]}],
  "warnings":[]}'

# One rule, so that mapping rests on "a changed test file runs itself" plus this single source rule.
STD_MAP='{"map_version":1,"rules":[{"source":"src/*.js","tests":["test/*.test.js"]}]}'

setup() {
  export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null GIT_CONFIG_NOSYSTEM=1
  unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE
  export LC_ALL=C
  # The script's scratch directory goes under TMPDIR: a private one, inspected by the no-leftovers case.
  export TMPDIR="$BATS_TEST_TMPDIR/tmp"
  mkdir -p "$TMPDIR"

  DISC_COUNT="$BATS_TEST_TMPDIR/discovery-calls"
  DISC="$BATS_TEST_TMPDIR/discovery.json"
  MAP="$BATS_TEST_TMPDIR/map.json"
  OUT="$BATS_TEST_TMPDIR/out"
  RUN_MARK="$BATS_TEST_TMPDIR/run-mark"
  export DISC_COUNT RUN_MARK
  export DISC_STUB_JSON="$DISC"
  mkdir -p "$OUT"
  printf '%s' "$STD_DISC" > "$DISC"
  printf '%s' "$STD_MAP" > "$MAP"

  build_pkg
  REPO=""
}

# ---- fixture helpers ---------------------------------------------------------------------------------------------

# build_pkg: the throwaway package tree. discover-tests.sh is the counting stub; everything else is the real script.
build_pkg() {
  PKG="$BATS_TEST_TMPDIR/pkg"
  GATE="$PKG/skills/j-commit/scripts/test-gate-scoped.sh"
  mkdir -p "$PKG/skills/j-commit/scripts" "$PKG/skills/j-test/scripts" "$PKG/scripts" "$PKG/templates"
  cp "$REPO_ROOT/skills/j-commit/scripts/test-gate-scoped.sh" "$GATE"
  cp "$REPO_ROOT"/skills/j-test/scripts/*.sh "$PKG/skills/j-test/scripts/"
  cp "$REPO_ROOT/scripts/resolve-root.sh" "$PKG/scripts/"
  cp "$REPO_ROOT/templates/test-scope-map.json" "$PKG/templates/"
  cat > "$PKG/skills/j-test/scripts/discover-tests.sh" <<'EOF'
#!/usr/bin/env bash
# Stub: counts its calls, then prints the fixture (or fails on request).
printf 'run\n' >> "$DISC_COUNT"
if [ -n "${DISC_STUB_EXIT:-}" ]; then
  echo "stub discovery refused (exit $DISC_STUB_EXIT) at $PWD/discover.err" >&2
  exit "$DISC_STUB_EXIT"
fi
cat "$DISC_STUB_JSON"
EOF
}

# stub_catalog <json>: replace build-catalog.sh with a script printing this catalog (for catalogs the real script
# cannot be made to produce from a consistent discovery document).
stub_catalog() {
  CAT_STUB_JSON="$BATS_TEST_TMPDIR/catalog-stub.json"
  export CAT_STUB_JSON
  printf '%s' "$1" > "$CAT_STUB_JSON"
  printf '#!/usr/bin/env bash\ncat "$CAT_STUB_JSON"\n' > "$PKG/skills/j-test/scripts/build-catalog.sh"
}

make_repo() {
  REPO="$BATS_TEST_TMPDIR/${1:-repo}"
  mkdir -p "$REPO"
  git -C "$REPO" init -q
  git -C "$REPO" config user.name "Fixture"
  git -C "$REPO" config user.email "fixture@example.invalid"
  git -C "$REPO" config commit.gpgsign false
}

# put <relpath> [content]: write a file (creating directories) in REPO.
put() {
  mkdir -p "$(dirname "$REPO/$1")"
  printf '%s\n' "${2:-content of $1}" > "$REPO/$1"
}

# edit <relpath>: modify a tracked file.
edit() { printf 'changed\n' >> "$REPO/$1"; }

commit_all() {
  git -C "$REPO" add -A
  git -C "$REPO" commit -q -m "$1"
}

# seed_repo [fold|unfold]: a repository whose single commit holds a test file for every ecosystem in STD_DISC, names
# with a space and a single quote, a README, and a package.json. In `fold` mode (the default) its `test` script IS the
# bats command, so build-catalog.sh folds bats:tests and config:bats:integration into the npm:test entry (numbers:
# cargo 1, go 2, npm:test 3, pytest 4, shellcheck 5). In `unfold` mode the script is something else, so bats:tests is
# an entry of its own (bats 1, cargo 2, go 3, npm 4, pytest 5, shellcheck 6).
seed_repo() {
  local f body
  if [ "${1:-fold}" = "unfold" ]; then
    body='{"scripts":{"test":"jest"}}'
  else
    body='{"scripts":{"test":"bats tests/*.bats"}}'
  fi
  make_repo repo
  for f in tests/a.bats tests/b.bats "tests/with space.bats" "tests/it's.bats" tests/test_a.py tests/sub/test_b.py \
           pkg/a_test.go tests/it.rs test/a.test.js src/a.js README.md scripts/x.sh; do
    put "$f"
  done
  put package.json "$body"
  commit_all "seed"
}

# ---- running and reading -----------------------------------------------------------------------------------------

# gate <args...>: run the script with --out-dir; sets $status, $output (stdout) and $stderr.
gate() { run --separate-stderr "$BASH_BIN" "$GATE" --out-dir "$OUT" "$@"; }

# gate_std <args...>: the usual arguments (fixture root, discovery file, scope map) plus any extra ones.
gate_std() { gate --root "$REPO" --discovery-file "$DISC" --map "$MAP" "$@"; }

# pj <jq filter>: a field of the printed plan, raw.
pj() { printf '%s' "$output" | jq -r "$1"; }

# pj_ok <jq expression>: the expression must be true of the printed plan.
pj_ok() {
  if ! printf '%s' "$output" | jq -e "$1" > /dev/null; then
    printf 'plan check failed: %s\n--- plan ---\n%s\n------------\n' "$1" "$output"
    return 1
  fi
}

# plan_ok: exit 0, exactly one line, valid JSON, and the same text in plan.json.
plan_ok() {
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | wc -l | tr -d ' ')" -eq 1 ]
  printf '%s' "$output" | jq -e 'type == "object"' > /dev/null
  [ "$output" = "$(cat "$OUT/plan.json")" ]
}

# ================================================================================================================
# Script text and usage
# ================================================================================================================

@test "the header documents usage, the plan JSON, the narrowing rule, the derived catalog and the exit codes" {
  local f="$REPO_ROOT/skills/j-commit/scripts/test-gate-scoped.sh" head_text
  head_text="$(sed -n '1,/^set -euo pipefail/p' "$f")"
  assert_contains "$head_text" "Usage:"
  assert_contains "$head_text" "--out-dir"
  assert_contains "$head_text" "--source"
  assert_contains "$head_text" "--discovery-file"
  assert_contains "$head_text" "PLAN JSON"
  assert_contains "$head_text" "NARROWING"
  assert_contains "$head_text" "DERIVED CATALOG"
  assert_contains "$head_text" "EXIT CODES"
  assert_contains "$head_text" "bash 3.2"
}

@test "the script uses no bash 4 feature (macOS bash 3.2 compatible)" {
  local f="$REPO_ROOT/skills/j-commit/scripts/test-gate-scoped.sh"
  # Comment lines are skipped; the patterns are the bash 4+ features named in the repo's other scripts.
  if grep -v '^[[:space:]]*#' "$f" | grep -E 'mapfile|readarray|declare -A|local -A|\$\{[A-Za-z_]+(,,|\^\^)\}|&>>|\|&' > /dev/null; then
    printf 'a bash 4+ construct is used in %s\n' "$f"
    return 1
  fi
}

@test "it runs unchanged under /bin/bash (3.2 on macOS) and prints the same plan" {
  [ -x /bin/bash ] || skip "no /bin/bash"
  seed_repo
  edit tests/a.bats
  gate_std
  plan_ok
  local expected="$output"
  run --separate-stderr /bin/bash "$GATE" --out-dir "$OUT" --root "$REPO" --discovery-file "$DISC" --map "$MAP"
  [ "$status" -eq 0 ]
  [ "$output" = "$expected" ]
}

@test "--help prints usage and exits 0 without writing anything" {
  run --separate-stderr "$BASH_BIN" "$GATE" --help
  [ "$status" -eq 0 ]
  assert_output_contains "Usage: test-gate-scoped.sh --out-dir"
  [ ! -e "$DISC_COUNT" ]
}

@test "usage errors exit 2 with the cause on stderr and no plan on stdout" {
  run --separate-stderr "$BASH_BIN" "$GATE" --out-dir "$OUT" --bogus
  [ "$status" -eq 2 ]
  [ -z "$output" ]
  assert_contains "$stderr" "unknown argument: --bogus"

  run --separate-stderr "$BASH_BIN" "$GATE"
  [ "$status" -eq 2 ]
  [ -z "$output" ]
  assert_contains "$stderr" "--out-dir is required"

  run --separate-stderr "$BASH_BIN" "$GATE" --out-dir "$BATS_TEST_TMPDIR/does-not-exist"
  [ "$status" -eq 2 ]
  assert_contains "$stderr" "not an existing directory"

  local plain_file="$BATS_TEST_TMPDIR/a-file"
  : > "$plain_file"
  run --separate-stderr "$BASH_BIN" "$GATE" --out-dir "$plain_file"
  [ "$status" -eq 2 ]
  assert_contains "$stderr" "not an existing directory"

  run --separate-stderr "$BASH_BIN" "$GATE" --out-dir "$OUT" --source sideways
  [ "$status" -eq 2 ]
  assert_contains "$stderr" "--source must be auto, staged or working"

  run --separate-stderr "$BASH_BIN" "$GATE" --out-dir "$OUT" --root "$BATS_TEST_TMPDIR/nowhere"
  [ "$status" -eq 2 ]
  assert_contains "$stderr" "--root is not a directory"

  run --separate-stderr "$BASH_BIN" "$GATE" --out-dir
  [ "$status" -eq 2 ]
  assert_contains "$stderr" "needs a directory argument"

  # Nothing ran, nothing was written, discovery never started.
  [ ! -e "$DISC_COUNT" ]
  [ -z "$(ls -A "$OUT")" ]
}

@test "a missing jq or git exits 1 and names the tool" {
  local tool bindir real
  for tool in jq git; do
    bindir="$BATS_TEST_TMPDIR/bin-without-$tool"
    mkdir -p "$bindir"
    # Only what the script needs before it reaches the tool check; the named tool is left out.
    ln -s "$(command -v dirname)" "$bindir/dirname"
    for real in jq git; do
      if [ "$real" != "$tool" ]; then
        ln -s "$(command -v "$real")" "$bindir/$real"
      fi
    done
    run --separate-stderr env PATH="$bindir" "$BASH_BIN" "$GATE" --out-dir "$OUT"
    [ "$status" -eq 1 ]
    [ -z "$output" ]
    assert_contains "$stderr" "$tool is required"
  done
}

# ================================================================================================================
# One discovery run, or none
# ================================================================================================================

@test "with --discovery-file the discovery script is never run" {
  seed_repo
  edit tests/a.bats
  gate_std
  plan_ok
  [ "$(pj .status)" = "mapped" ]
  [ ! -e "$DISC_COUNT" ]
  [ ! -e "$OUT/discovery.json" ]
}

@test "without --discovery-file discovery runs exactly once and its file feeds the mapper and the catalog" {
  seed_repo
  edit tests/a.bats
  edit "tests/with space.bats"
  gate --root "$REPO" --map "$MAP"
  plan_ok
  # One call in total, although map-scope.sh and build-catalog.sh both could have run discovery themselves.
  [ "$(wc -l < "$DISC_COUNT" | tr -d ' ')" -eq 1 ]
  [ "$(cat "$OUT/discovery.json")" = "$(cat "$DISC")" ]
  [ "$(pj .status)" = "mapped" ]
  # The plan is built from the stub's document: its entry came through the catalog built from the same file.
  [ "$(pj '.suites[0].id')" = "npm:test" ]
  pj_ok '.suites[0].tests == ["tests/a.bats","tests/with space.bats"]'
}

@test "a failing discovery gives status error, exit 0 and no suite run" {
  seed_repo
  edit tests/a.bats
  export DISC_STUB_EXIT=7
  gate --root "$REPO" --map "$MAP"
  plan_ok
  [ "$(pj .status)" = "error" ]
  [ "$(wc -l < "$DISC_COUNT" | tr -d ' ')" -eq 1 ]
  pj_ok '.selection == [] and .suites == [] and .catalog_file == null'
  assert_starts_with "$(pj .message)" "test discovery failed (exit 7)"
  # The message names no temp path.
  assert_not_contains "$(pj .message)" "$BATS_TEST_TMPDIR"
  [ ! -e "$OUT/discovery.json" ]
  [ ! -e "$OUT/catalog.json" ]
}

# ================================================================================================================
# The change source
# ================================================================================================================

@test "--source auto picks staged when the index has content, and maps only the staged files" {
  seed_repo
  edit tests/a.bats
  git -C "$REPO" add tests/a.bats
  edit tests/b.bats
  gate_std
  plan_ok
  [ "$(pj .source)" = "staged" ]
  pj_ok '.changed_count == 1'
  pj_ok '.suites[0].tests == ["tests/a.bats"]'
}

@test "--source auto picks working when the index is empty, and maps every uncommitted file" {
  seed_repo
  edit tests/a.bats
  edit tests/b.bats
  gate_std
  plan_ok
  [ "$(pj .source)" = "working" ]
  pj_ok '.changed_count == 2'
  pj_ok '.suites[0].tests == ["tests/a.bats","tests/b.bats"]'
}

@test "--source working maps staged, unstaged and untracked files; --source staged only the index" {
  seed_repo
  edit tests/a.bats
  git -C "$REPO" add tests/a.bats
  edit tests/b.bats
  put "tests/new.bats"

  gate_std --source working
  plan_ok
  [ "$(pj .source)" = "working" ]
  pj_ok '.changed_count == 3'
  pj_ok '.suites[0].tests == ["tests/a.bats","tests/b.bats","tests/new.bats"]'

  gate_std --source staged
  plan_ok
  [ "$(pj .source)" = "staged" ]
  pj_ok '.changed_count == 1'
  pj_ok '.suites[0].tests == ["tests/a.bats"]'
}

@test "--source staged with an empty index is zero with the No changed files warning" {
  seed_repo
  edit tests/a.bats
  gate_std --source staged
  plan_ok
  [ "$(pj .status)" = "zero" ]
  [ "$(pj .source)" = "staged" ]
  pj_ok '.changed_count == 0 and .selection == [] and .suites == []'
  pj_ok '.warnings | index("No changed files") != null'
}

@test "a repository with no commit yet maps its staged and its working files" {
  make_repo fresh
  put tests/a.bats
  git -C "$REPO" add tests/a.bats
  put tests/b.bats
  put package.json '{"scripts":{"test":"jest"}}'

  gate_std
  plan_ok
  [ "$(pj .source)" = "staged" ]
  pj_ok '.suites[0].tests == ["tests/a.bats"]'

  gate_std --source working
  plan_ok
  pj_ok '.changed_count == 3'
  pj_ok '.suites[0].tests == ["tests/a.bats","tests/b.bats"]'
}

# ================================================================================================================
# Narrowing
# ================================================================================================================

@test "a mapped bats suite is narrowed to the mapped files: union, sorted, single-quoted (space and quote safe)" {
  seed_repo unfold
  edit tests/b.bats
  edit "tests/with space.bats"
  edit "tests/it's.bats"
  edit tests/a.bats
  edit README.md
  gate_std
  plan_ok
  [ "$(pj .status)" = "mapped" ]
  [ "$(pj '.suites | length')" -eq 1 ]
  [ "$(pj '.suites[0].id')" = "bats:tests" ]
  [ "$(pj '.suites[0].narrowed')" = "true" ]
  local expected="bats 'tests/a.bats' 'tests/b.bats' 'tests/it'\\''s.bats' 'tests/with space.bats'"
  [ "$(pj '.suites[0].command')" = "$expected" ]
  pj_ok '.suites[0].tests == ["tests/a.bats","tests/b.bats","tests/it'"'"'s.bats","tests/with space.bats"]'
  pj_ok '.unmapped_files == ["README.md"]'
  pj_ok '.changed_count == 5'
  # The same command is what the derived catalog will run.
  [ "$(jq -r '.runnable[0].command' "$OUT/catalog.json")" = "$expected" ]
}

@test "narrowing adds no file the mapper did not map" {
  seed_repo unfold
  edit tests/a.bats
  gate_std
  plan_ok
  [ "$(pj '.suites[0].command')" = "bats 'tests/a.bats'" ]
  pj_ok '.suites[0].tests == ["tests/a.bats"]'
}

@test "a file name starting with a dash is written ./name in the command so it cannot read as an option" {
  seed_repo unfold
  put "-odd.bats"
  printf '%s' '{"suites":[{"id":"bats:root","name":"bats root","type":"unit","ecosystem":"bats","command":"bats *.bats","paths":["*.bats"]}]}' \
    > "$BATS_TEST_TMPDIR/root-bats.json"
  # A later --discovery-file replaces the one gate_std passes first.
  gate_std --source working --discovery-file "$BATS_TEST_TMPDIR/root-bats.json"
  plan_ok
  [ "$(pj .status)" = "mapped" ]
  [ "$(pj '.suites[0].command')" = "bats './-odd.bats'" ]
  pj_ok '.suites[0].tests == ["-odd.bats"]'
}

@test "a mapped pytest suite is narrowed to the mapped files, sorted" {
  seed_repo
  edit tests/test_a.py
  edit tests/sub/test_b.py
  gate_std
  plan_ok
  [ "$(pj '.suites | length')" -eq 1 ]
  [ "$(pj '.suites[0].id')" = "pytest:tests" ]
  [ "$(pj '.suites[0].narrowed')" = "true" ]
  [ "$(pj '.suites[0].command')" = "pytest 'tests/sub/test_b.py' 'tests/test_a.py'" ]
  pj_ok '.suites[0].tests == ["tests/sub/test_b.py","tests/test_a.py"]'
}

@test "an npm suite runs whole: narrowed is false, the command is the entry's own, tests still listed" {
  seed_repo
  edit test/a.test.js
  gate_std
  plan_ok
  [ "$(pj '.suites[0].id')" = "npm:test" ]
  [ "$(pj '.suites[0].narrowed')" = "false" ]
  [ "$(pj '.suites[0].command')" = "npm test" ]
  pj_ok '.suites[0].tests == ["test/a.test.js"]'
}

@test "a go suite runs whole" {
  seed_repo
  edit pkg/a_test.go
  gate_std
  plan_ok
  [ "$(pj '.suites | length')" -eq 1 ]
  [ "$(pj '.suites[0].id')" = "go:test" ]
  [ "$(pj '.suites[0].narrowed')" = "false" ]
  [ "$(pj '.suites[0].command')" = "go test ./..." ]
  pj_ok '.suites[0].tests == ["pkg/a_test.go"]'
}

@test "a cargo suite runs whole" {
  seed_repo
  edit tests/it.rs
  gate_std
  plan_ok
  [ "$(pj '.suites | length')" -eq 1 ]
  [ "$(pj '.suites[0].id')" = "cargo:integration:it" ]
  [ "$(pj '.suites[0].narrowed')" = "false" ]
  [ "$(pj '.suites[0].command')" = "cargo test --test it" ]
}

@test "a shellcheck suite runs whole" {
  seed_repo
  edit scripts/x.sh
  gate_std
  plan_ok
  [ "$(pj '.suites | length')" -eq 1 ]
  [ "$(pj '.suites[0].id')" = "shellcheck:all" ]
  [ "$(pj '.suites[0].narrowed')" = "false" ]
  [ "$(pj '.suites[0].command')" = "shellcheck -x scripts/*.sh" ]
}

@test "a mixed group (bats and npm folded into one entry) runs whole as one plan suite with the tests unioned" {
  seed_repo
  edit tests/a.bats
  edit test/a.test.js
  gate_std
  plan_ok
  [ "$(pj .status)" = "mapped" ]
  # Both mapped ids land on the npm:test entry: one plan suite, not two.
  [ "$(pj '.suites | length')" -eq 1 ]
  [ "$(pj '.suites[0].id')" = "npm:test" ]
  [ "$(pj '.suites[0].narrowed')" = "false" ]
  [ "$(pj '.suites[0].command')" = "npm test" ]
  pj_ok '.suites[0].tests == ["test/a.test.js","tests/a.bats"]'
  pj_ok '.selection == [3]'
}

@test "a file name holding a control character is not narrowed: the whole suite runs, with a warning" {
  seed_repo unfold
  put "tests/tab"$'\t'"x.bats"
  gate_std
  plan_ok
  [ "$(pj '.suites[0].id')" = "bats:tests" ]
  [ "$(pj '.suites[0].narrowed')" = "false" ]
  [ "$(pj '.suites[0].command')" = "bats tests/*.bats" ]
  pj_ok '.suites[0].tests | length == 1'
  pj_ok '.warnings | index("suite bats:tests: a test file name contains a control character; the whole suite runs") != null'
}

# ================================================================================================================
# Mapping a mapped id to a catalog entry
# ================================================================================================================

@test "a mapped id folded into another entry's also resolves to that entry and keeps the survivor's n" {
  seed_repo
  edit tests/a.bats
  gate_std
  plan_ok
  # bats:tests is folded into npm:test (the script body is the bats command): the entry's own id and number.
  [ "$(pj '.suites[0].id')" = "npm:test" ]
  [ "$(pj '.suites[0].n')" -eq 3 ]
  pj_ok '.selection == [3]'
  [ "$(pj '.suites[0].narrowed')" = "true" ]
  [ "$(pj '.suites[0].command')" = "bats 'tests/a.bats'" ]
  # The folded ids stay visible in the derived catalog's entry.
  pj_ok '.suites | length == 1'
  [ "$(jq -r '.runnable[0].also | map(.id) | join(",")' "$OUT/catalog.json")" = "bats:tests,config:bats:integration" ]
}

@test "the same bats edit on an unfolded project resolves to the bats entry itself with its own n" {
  seed_repo unfold
  edit tests/a.bats
  gate_std
  plan_ok
  [ "$(pj '.suites[0].id')" = "bats:tests" ]
  [ "$(pj '.suites[0].n')" -eq 1 ]
  pj_ok '.selection == [1]'
}

@test "a mapped id with no runnable catalog entry is dropped with a warning while the others still run" {
  seed_repo
  edit tests/a.bats
  edit test/a.test.js
  stub_catalog '{"runnable":[{"n":7,"id":"npm:test","name":"npm test","type":"unit","ecosystem":"npm","command":"npm test","also":[]}],"not_runnable":[],"warnings":[]}'
  gate_std
  plan_ok
  [ "$(pj .status)" = "mapped" ]
  pj_ok '.selection == [7]'
  pj_ok '.suites | map(.id) == ["npm:test"]'
  pj_ok '.warnings | index("suite bats:tests has no runnable catalog entry; skipped") != null'
}

# ================================================================================================================
# Zero: never a vacuous green
# ================================================================================================================

@test "a change no test covers is zero with an empty selection, a plain message and the mapper's warning" {
  seed_repo
  edit README.md
  gate_std
  plan_ok
  [ "$(pj .status)" = "zero" ]
  pj_ok '.selection == [] and .suites == []'
  pj_ok '.unmapped_files == ["README.md"]'
  pj_ok '.warnings | index("No tests found for the changed files") != null'
  assert_starts_with "$(pj .message)" "No test covers the changed files"
  assert_contains "$(pj .message)" "README.md"
  # A catalog is still written, with nothing runnable in it.
  [ "$(pj .catalog_file)" = "$(cd "$OUT" && pwd)/catalog.json" ]
  [ "$(jq '.runnable | length' "$OUT/catalog.json")" -eq 0 ]
}

@test "the zero message lists at most five unmapped files" {
  seed_repo
  local i
  for i in 1 2 3 4 5 6 7; do
    put "docs/$i.md"
  done
  gate_std
  plan_ok
  [ "$(pj .status)" = "zero" ]
  [ "$(pj .message)" = "No test covers the changed files: docs/1.md, docs/2.md, docs/3.md, docs/4.md, docs/5.md and 2 more" ]
  pj_ok '.unmapped_files | length == 7'
}

@test "an empty change set is zero with the No changed files warning" {
  seed_repo
  gate_std
  plan_ok
  [ "$(pj .status)" = "zero" ]
  pj_ok '.changed_count == 0 and .selection == [] and .suites == [] and .unmapped_files == []'
  pj_ok '.warnings | index("No changed files") != null'
  assert_contains "$(pj .message)" "No test covers the changed files"
}

@test "mapped suites that are all non-runnable yield zero, naming them, with no selection" {
  seed_repo
  edit tests/a.bats
  stub_catalog '{"runnable":[],"not_runnable":[{"id":"bats:tests","name":"bats tests","type":"unit","ecosystem":"bats","reason":"no command declared"}],"warnings":["catalog note"]}'
  gate_std
  plan_ok
  [ "$(pj .status)" = "zero" ]
  pj_ok '.selection == [] and .suites == []'
  assert_starts_with "$(pj .message)" "No test covers the changed files"
  assert_contains "$(pj .message)" "bats:tests"
  pj_ok '.warnings | index("suite bats:tests has no runnable catalog entry; skipped") != null'
  # not_runnable and the catalog's warnings are carried as they are.
  [ "$(jq -c '.not_runnable | map(.id)' "$OUT/catalog.json")" = '["bats:tests"]' ]
  [ "$(jq -c '.warnings' "$OUT/catalog.json")" = '["catalog note"]' ]
  [ "$(jq '.runnable | length' "$OUT/catalog.json")" -eq 0 ]
}

# ================================================================================================================
# Error: map-scope.sh fails
# ================================================================================================================

@test "a configured but missing map file is status error with map_scope_exit 3, exit 0 and no suite run" {
  seed_repo
  edit tests/a.bats
  gate --root "$REPO" --discovery-file "$DISC" --map "$BATS_TEST_TMPDIR/maps/missing.json"
  plan_ok
  [ "$(pj .status)" = "error" ]
  [ "$(pj .map_scope_exit)" -eq 3 ]
  pj_ok '.selection == [] and .suites == [] and .catalog_file == null and .warnings == []'
  assert_starts_with "$(pj .message)" "map-scope.sh failed (exit 3)"
  assert_contains "$(pj .message)" "missing.json"
  # No absolute temp path in the message.
  assert_not_contains "$(pj .message)" "$BATS_TEST_TMPDIR"
  assert_not_contains "$(pj .message)" "/maps/"
  [ ! -e "$OUT/catalog.json" ]
  [ ! -e "$RUN_MARK" ]
}

@test "a commit_scope_map_file in test-config.json that points nowhere is also exit 3" {
  seed_repo
  put project/configs/test-config.json '{"commit_scope_map_file":"maps/nowhere.json"}'
  edit tests/a.bats
  gate --root "$REPO" --discovery-file "$DISC"
  plan_ok
  [ "$(pj .status)" = "error" ]
  [ "$(pj .map_scope_exit)" -eq 3 ]
  assert_contains "$(pj .message)" "nowhere.json"
  assert_not_contains "$(pj .message)" "$BATS_TEST_TMPDIR"
}

@test "without --map the mapper resolves its own default and the plan is built" {
  seed_repo
  edit tests/a.bats
  gate --root "$REPO" --discovery-file "$DISC"
  plan_ok
  [ "$(pj .status)" = "mapped" ]
  pj_ok '.suites[0].tests == ["tests/a.bats"]'
}

@test "a directory that is not a git repository is status error with map_scope_exit 4" {
  mkdir -p "$BATS_TEST_TMPDIR/plain"
  gate --root "$BATS_TEST_TMPDIR/plain" --discovery-file "$DISC" --map "$MAP"
  plan_ok
  [ "$(pj .status)" = "error" ]
  [ "$(pj .map_scope_exit)" -eq 4 ]
  pj_ok '.selection == [] and .suites == [] and .catalog_file == null'
  assert_starts_with "$(pj .message)" "map-scope.sh failed (exit 4)"
  assert_not_contains "$(pj .message)" "$BATS_TEST_TMPDIR"
  [ ! -e "$RUN_MARK" ]
}

@test "an error plan does not leave an earlier run's catalog behind" {
  seed_repo
  edit tests/a.bats
  gate_std
  plan_ok
  [ -f "$OUT/catalog.json" ]
  gate --root "$REPO" --discovery-file "$DISC" --map "$BATS_TEST_TMPDIR/maps/missing.json"
  plan_ok
  [ "$(pj .status)" = "error" ]
  [ ! -e "$OUT/catalog.json" ]
}

# ================================================================================================================
# The plan's shape, and the derived catalog against the real runner
# ================================================================================================================

@test "the plan keys are in the documented order, for mapped and for error plans" {
  seed_repo unfold
  edit tests/a.bats
  gate_std
  plan_ok
  [ "$(pj 'keys_unsorted | join(",")')" = "status,source,changed_count,selection,suites,unmapped_files,warnings,message,catalog_file" ]
  [ "$(pj '.suites[0] | keys_unsorted | join(",")')" = "n,id,name,command,narrowed,tests" ]
  [ "$(pj .catalog_file)" = "$(cd "$OUT" && pwd)/catalog.json" ]
  pj_ok '.warnings | type == "array"'

  gate --root "$REPO" --discovery-file "$DISC" --map "$BATS_TEST_TMPDIR/maps/missing.json"
  plan_ok
  [ "$(pj 'keys_unsorted | join(",")')" = "status,source,changed_count,selection,suites,unmapped_files,warnings,map_scope_exit,message,catalog_file" ]
}

@test "identical input gives byte-identical plans and catalogs, and warnings are sorted and unique" {
  seed_repo
  edit tests/a.bats
  edit README.md
  gate_std
  plan_ok
  local first="$output" first_catalog
  first_catalog="$(cat "$OUT/catalog.json")"
  gate_std
  plan_ok
  [ "$output" = "$first" ]
  [ "$(cat "$OUT/catalog.json")" = "$first_catalog" ]
  pj_ok '.warnings == (.warnings | unique)'
}

@test "catalog.json holds only the selected entries with their original n; run-suites.sh accepts the selection unchanged" {
  seed_repo
  edit tests/a.bats
  edit "tests/with space.bats"
  edit "tests/it's.bats"
  gate_std
  plan_ok
  [ "$(pj .status)" = "mapped" ]
  jq -e . "$OUT/catalog.json" > /dev/null
  # The full catalog has five runnable entries; the derived one keeps only the selected one, still numbered 3.
  jq -e '(.runnable | length) == 1 and .runnable[0].n == 3 and .runnable[0].id == "npm:test"' "$OUT/catalog.json" > /dev/null

  # Exported functions stand in for the suite commands; run-suites.sh runs each command with `bash -c`.
  bats() { { printf 'bats'; local a; for a in "$@"; do printf ' <%s>' "$a"; done; printf '\n'; } >> "$RUN_MARK"; }
  export -f bats

  local sel
  sel="$(pj '.selection | map(tostring) | join(" ")')"
  [ "$sel" = "3" ]
  # shellcheck disable=SC2086
  run --separate-stderr "$BASH_BIN" "$PKG/skills/j-test/scripts/run-suites.sh" --catalog "$OUT/catalog.json" --root "$REPO" $sel
  [ "$status" -eq 0 ]
  assert_output_contains "1 passed, 0 failed. Exit code: 0"
  # The narrowed command reached the runner with each file as one argument, quoting intact.
  [ "$(cat "$RUN_MARK")" = "bats <tests/a.bats> <tests/it's.bats> <tests/with space.bats>" ]

  # A renumbered selection (1) would be refused: the original number is the only one that validates.
  rm -f "$RUN_MARK"
  run --separate-stderr "$BASH_BIN" "$PKG/skills/j-test/scripts/run-suites.sh" --catalog "$OUT/catalog.json" --root "$REPO" 1
  [ "$status" -eq 2 ]
  [ ! -e "$RUN_MARK" ]
}

@test "a whole-suite plan is validated by run-suites.sh as well, and runs the entry's own command" {
  seed_repo
  edit test/a.test.js
  gate_std
  plan_ok
  npm() { { printf 'npm'; local a; for a in "$@"; do printf ' <%s>' "$a"; done; printf '\n'; } >> "$RUN_MARK"; }
  export -f npm
  run --separate-stderr "$BASH_BIN" "$PKG/skills/j-test/scripts/run-suites.sh" --catalog "$OUT/catalog.json" --root "$REPO" "$(pj '.selection[0]')"
  [ "$status" -eq 0 ]
  [ "$(cat "$RUN_MARK")" = "npm <test>" ]
}

# ================================================================================================================
# The repository is untouched
# ================================================================================================================

# out_files: the file names directly inside --out-dir, sorted, space separated (trailing space included).
out_files() { find "$OUT" -type f | sed 's#.*/##' | sort | tr '\n' ' '; }

# snap: a checksum of every file under the repository, .git included, plus the directory list.
snap() {
  (
    cd "$REPO" || return 1
    find . -type d | sort
    find . -type f -exec cksum {} + | sort
  )
}

@test "the repository is byte-identical afterwards, .git/index included, even with stale stat data" {
  seed_repo
  edit tests/a.bats
  edit README.md
  put tests/new.bats
  # Stale stat data: content unchanged, recorded mtime wrong. A plain `git diff` against the working tree would
  # refresh and rewrite .git/index on such a repository, and that is what must never happen here.
  touch -t 200001010000 "$REPO/src/a.js"
  touch -t 200001010000 "$REPO/test/a.test.js"

  # The premise holds on a copy: a plain working-tree diff does rewrite the index of this fixture.
  cp -R "$REPO" "$BATS_TEST_TMPDIR/premise"
  cp -p "$BATS_TEST_TMPDIR/premise/.git/index" "$BATS_TEST_TMPDIR/premise-index.before"
  git -C "$BATS_TEST_TMPDIR/premise" diff --name-only HEAD > /dev/null
  if cmp -s "$BATS_TEST_TMPDIR/premise-index.before" "$BATS_TEST_TMPDIR/premise/.git/index"; then
    skip "this git does not refresh the index on a plain diff, so the fixture proves nothing here"
  fi

  local before after src
  before="$(snap)"
  cp -p "$REPO/.git/index" "$BATS_TEST_TMPDIR/index.before"
  for src in auto staged working; do
    gate_std --source "$src"
    plan_ok
    after="$(snap)"
    [ "$after" = "$before" ]
    cmp "$BATS_TEST_TMPDIR/index.before" "$REPO/.git/index"
  done
  [ ! -e "$REPO/.git/index.lock" ]
}

@test "nothing is written outside --out-dir and TMPDIR, and TMPDIR is left empty" {
  seed_repo
  edit tests/a.bats
  local before_tree after_tree
  before_tree="$(cd "$BATS_TEST_TMPDIR" && find . -path ./out -prune -o -path ./tmp -prune -o -name 'separate-stderr-*' -prune -o -print | sort)"
  gate_std
  plan_ok
  after_tree="$(cd "$BATS_TEST_TMPDIR" && find . -path ./out -prune -o -path ./tmp -prune -o -name 'separate-stderr-*' -prune -o -print | sort)"
  [ "$after_tree" = "$before_tree" ]
  # The script's scratch directory is gone, and --out-dir holds exactly the plan and the catalog.
  [ -z "$(ls -A "$TMPDIR")" ]
  [ "$(out_files)" = "catalog.json plan.json " ]

  # Running discovery adds discovery.json to --out-dir and nothing else anywhere.
  rm -f "$OUT"/*
  before_tree="$(cd "$BATS_TEST_TMPDIR" && find . -path ./out -prune -o -path ./tmp -prune -o -name 'separate-stderr-*' -prune -o -print | sort)"
  gate --root "$REPO" --map "$MAP"
  plan_ok
  after_tree="$(cd "$BATS_TEST_TMPDIR" && find . -path ./out -prune -o -path ./tmp -prune -o -name 'separate-stderr-*' -prune -o -print | sort)"
  # Only the stub's own call counter appears (it is the test's fixture, written by the stub, not by the script).
  [ "$after_tree" = "$(printf '%s\n%s\n' "$before_tree" "./discovery-calls" | sort)" ]
  [ -z "$(ls -A "$TMPDIR")" ]
  [ "$(out_files)" = "catalog.json discovery.json plan.json " ]
}

@test "error exits leave TMPDIR clean" {
  seed_repo
  edit tests/a.bats
  gate --root "$REPO" --discovery-file "$DISC" --map "$BATS_TEST_TMPDIR/maps/missing.json"
  plan_ok
  [ -z "$(ls -A "$TMPDIR")" ]
  export DISC_STUB_EXIT=3
  gate --root "$REPO" --map "$MAP"
  plan_ok
  [ -z "$(ls -A "$TMPDIR")" ]
}
