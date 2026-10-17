#!/usr/bin/env bats
#
# Coverage for skills/j-test/scripts/build-catalog.sh (E72_S02_T02).
#
# The script turns discover-tests.sh's JSON into the deduplicated catalog j.test presents and runs, and renders it as
# the numbered list. This suite checks the catalog contract that E72_S02_T03/T04/T05 and E72_S04 read, and the two
# deduplication rules (identical `command`, and the npm alias for a package.json script body).
#
# How the cases are written
#   - Discovery output comes from committed JSON fixtures under tests/fixtures/j-test/catalog/ and is fed in with
#     --discovery-file, so no case walks the tree and none calls discover-tests.sh against the live repo (a real
#     discovery run takes 25-35 s here). The only exceptions are the cases that prove --root is FORWARDED, which run
#     a copy of the script next to a stub discover-tests.sh.
#   - The catalog is asserted with jq queries, never as a substring of raw JSON. The rendered list is compared as
#     exact text, because its layout is the contract.
#   - dup-command.json is this repo's four-suite discovery output. Run against a root with NO package.json it shows the
#     plain command dedupe; run against npm-alias/ (same suites, plus a package.json whose scripts.test is
#     `bats tests/*.bats`) it shows the npm alias that folds `npm test` into the same entry.
#   - Everything scratch lives under BATS_TEST_TMPDIR. The fixtures themselves are only read.

bats_require_minimum_version 1.5.0

load helpers/assertions

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
BUILD="$REPO_ROOT/skills/j-test/scripts/build-catalog.sh"
FIX="$REPO_ROOT/tests/fixtures/j-test/catalog"
BASH_BIN="$(command -v bash)"

# Every tool the script (and scripts/resolve-root.sh) invokes, minus jq, which is decided per test.
BIN_TOOLS="bash cat dirname basename pwd env git sed awk grep sort head tail tr cut date uname readlink realpath ls mkdir"

setup() {
  EMPTY_ROOT="$BATS_TEST_TMPDIR/empty-root"
  mkdir -p "$EMPTY_ROOT"
}

# --- helpers -------------------------------------------------------------------------------------------------------

# catalog <args...>: run the script; sets $status, $output (stdout) and $stderr.
catalog() {
  run --separate-stderr "$BASH_BIN" "$BUILD" "$@"
}

# catalog_ok <args...>: as catalog, and require exit 0 with empty stderr.
catalog_ok() {
  catalog "$@"
  [ "$status" -eq 0 ]
  [ -z "$stderr" ]
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

# save_catalog <name> <args...>: build a catalog from the arguments and store it as $BATS_TEST_TMPDIR/<name>.json.
save_catalog() {
  local name="$1"
  shift
  "$BASH_BIN" "$BUILD" "$@" > "$BATS_TEST_TMPDIR/$name.json"
}

# write_discovery <file> <suites-json> [warnings-json]: a discovery file with exactly those suites.
write_discovery() {
  jq -cn --argjson s "$2" --argjson w "${3:-[]}" '{suites:$s,warnings:$w}' > "$1"
}

# A script copy with NO discover-tests.sh beside it (and a stub variant), so a case can prove a mode never reaches for
# discovery. The copy resolves REPO_ROOT three levels up, i.e. inside the temp tree, never the real checkout.
make_copy() {
  COPY_DIR="$BATS_TEST_TMPDIR/copy/skills/j-test/scripts"
  mkdir -p "$COPY_DIR"
  cp "$BUILD" "$COPY_DIR/build-catalog.sh"
}

# make_stub <exit-code>: a discover-tests.sh stub that records its arguments (one per line) in $STUB_ARGS and prints one
# runnable suite, or fails with the given exit code.
make_stub() {
  STUB_ARGS="$BATS_TEST_TMPDIR/stub-args.txt"
  cat > "$COPY_DIR/discover-tests.sh" <<EOF
#!/usr/bin/env bash
: > "$STUB_ARGS"
for a in "\$@"; do printf '%s\n' "\$a" >> "$STUB_ARGS"; done
if [ "$1" -ne 0 ]; then
  echo "stub discovery refused" >&2
  exit $1
fi
printf '%s\n' '{"suites":[{"id":"go:.","name":"go test ./...","type":"unit","ecosystem":"go","command":"go test ./..."}],"warnings":[]}'
EOF
}

# make_bin <dir> [with-jq|no-jq]: a PATH directory of symlinks to the real tools.
make_bin() {
  local dir="$1" jq_mode="${2:-with-jq}" tool path
  mkdir -p "$dir"
  for tool in $BIN_TOOLS; do
    path="$(command -v "$tool" 2>/dev/null)" || continue
    case "$path" in /*) ln -s "$path" "$dir/$tool" ;; esac
  done
  if [ "$jq_mode" = "with-jq" ]; then
    ln -s "$(command -v jq)" "$dir/jq"
  fi
}

# ===================================================================================================================
# Deduplication: identical command
# ===================================================================================================================

@test "identical commands fold into one entry: bats:tests survives, config:bats:integration goes into also" {
  catalog_ok --root "$EMPTY_ROOT" --discovery-file "$FIX/dup-command.json"
  json_check '[.runnable[].id] == ["bats:tests","npm:test","shellcheck:all"]'
  json_check '(.runnable[0].also | map(.id)) == ["config:bats:integration"]'
  json_check '.runnable[0].also[0] == {id:"config:bats:integration",name:"bats (integration)",type:"integration"}'
  json_check '[.runnable[] | .command] | map(select(. == "bats tests/*.bats")) | length == 1'
}

@test "survivor rule: with no npm entry the first non-config entry wins over an earlier config entry" {
  # config:pytest:integration sorts before pytest:tests but must not survive.
  write_discovery "$BATS_TEST_TMPDIR/d.json" '[
    {"id":"config:pytest:integration","name":"pytest (integration)","type":"integration","ecosystem":"config","command":"pytest tests"},
    {"id":"pytest:tests","name":"pytest tests","type":"unit","ecosystem":"pytest","command":"pytest tests"}]'
  catalog_ok --root "$EMPTY_ROOT" --discovery-file "$BATS_TEST_TMPDIR/d.json"
  json_check '(.runnable | length) == 1 and .runnable[0].id == "pytest:tests"'
  json_check '(.runnable[0].also | map(.id)) == ["config:pytest:integration"]'
}

@test "survivor rule: a group made only of config entries keeps the first by id" {
  write_discovery "$BATS_TEST_TMPDIR/d.json" '[
    {"id":"config:bats:unit","name":"bats (unit)","type":"unit","ecosystem":"config","command":"bats t/*.bats"},
    {"id":"config:bats:integration","name":"bats (integration)","type":"integration","ecosystem":"config","command":"bats t/*.bats"}]'
  catalog_ok --root "$EMPTY_ROOT" --discovery-file "$BATS_TEST_TMPDIR/d.json"
  json_check '(.runnable | length) == 1 and .runnable[0].id == "config:bats:integration"'
  json_check '(.runnable[0].also | map(.id)) == ["config:bats:unit"]'
}

@test "also is sorted by id when more than one suite is folded" {
  write_discovery "$BATS_TEST_TMPDIR/d.json" '[
    {"id":"z:last","name":"z","type":"unit","ecosystem":"bats","command":"same"},
    {"id":"a:first","name":"a","type":"unit","ecosystem":"bats","command":"same"},
    {"id":"m:middle","name":"m","type":"unit","ecosystem":"bats","command":"same"}]'
  catalog_ok --root "$EMPTY_ROOT" --discovery-file "$BATS_TEST_TMPDIR/d.json"
  json_check '.runnable[0].id == "a:first"'
  json_check '(.runnable[0].also | map(.id)) == ["m:middle","z:last"]'
}

@test "suites with distinct commands are not folded and every also is an empty array, never absent" {
  catalog_ok --discovery-file "$FIX/already-clean.json"
  json_check '(.runnable | length) == 2'
  json_check '.runnable | all(has("also") and (.also | type) == "array" and (.also | length) == 0)'
}

# ===================================================================================================================
# Deduplication: the npm alias
# ===================================================================================================================

@test "npm alias: npm test folds into the bats suite and the catalog has exactly one entry for bats tests/*.bats" {
  catalog_ok --root "$FIX/npm-alias" --discovery-file "$FIX/npm-alias/discovery.json"
  json_check '(.runnable | length) == 2'
  json_check '[.runnable[] | select(.id == "npm:test" or .command == "bats tests/*.bats" or (.also | map(.id) | index("bats:tests")))] | length == 1'
  json_check '.runnable[0].id == "npm:test" and .runnable[0].command == "npm test"'
  json_check '(.runnable[0].also | map(.id)) == ["bats:tests","config:bats:integration"]'
  json_check '.runnable[1].id == "shellcheck:all"'
}

@test "npm alias: the npm entry is the survivor even though bats:tests sorts before npm:test" {
  catalog_ok --root "$FIX/npm-alias" --discovery-file "$FIX/npm-alias/discovery.json"
  json_check '[.runnable[].id] | index("bats:tests") == null'
  json_check '.runnable[0].ecosystem == "npm"'
}

@test "npm alias: the same suites without the package.json alias keep npm test as its own entry" {
  catalog_ok --root "$EMPTY_ROOT" --discovery-file "$FIX/npm-alias/discovery.json"
  json_check '[.runnable[].id] == ["bats:tests","npm:test","shellcheck:all"]'
}

@test "npm alias: npm run <key> folds with the suite whose command equals that script body" {
  mkdir -p "$BATS_TEST_TMPDIR/proj"
  printf '%s' '{"scripts":{"test:unit":"pytest tests","test:e2e":"playwright test"}}' > "$BATS_TEST_TMPDIR/proj/package.json"
  write_discovery "$BATS_TEST_TMPDIR/d.json" '[
    {"id":"npm:test:e2e","name":"npm run test:e2e","type":"e2e","ecosystem":"npm","command":"npm run test:e2e"},
    {"id":"npm:test:unit","name":"npm run test:unit","type":"unit","ecosystem":"npm","command":"npm run test:unit"},
    {"id":"pytest:tests","name":"pytest tests","type":"unit","ecosystem":"pytest","command":"pytest tests"}]'
  catalog_ok --root "$BATS_TEST_TMPDIR/proj" --discovery-file "$BATS_TEST_TMPDIR/d.json"
  json_check '[.runnable[].id] == ["npm:test:e2e","npm:test:unit"]'
  json_check '(.runnable[1].also | map(.id)) == ["pytest:tests"]'
  json_check '.runnable[1].command == "npm run test:unit"'
}

@test "npm alias: two npm scripts with the same body fold, the first by id surviving" {
  mkdir -p "$BATS_TEST_TMPDIR/proj"
  printf '%s' '{"scripts":{"test":"jest","test:ci":"jest"}}' > "$BATS_TEST_TMPDIR/proj/package.json"
  write_discovery "$BATS_TEST_TMPDIR/d.json" '[
    {"id":"npm:test","name":"npm test","type":"unit","ecosystem":"npm","command":"npm test"},
    {"id":"npm:test:ci","name":"npm run test:ci","type":"unknown","ecosystem":"npm","command":"npm run test:ci"}]'
  catalog_ok --root "$BATS_TEST_TMPDIR/proj" --discovery-file "$BATS_TEST_TMPDIR/d.json"
  json_check '(.runnable | length) == 1 and .runnable[0].id == "npm:test"'
  json_check '(.runnable[0].also | map(.id)) == ["npm:test:ci"]'
}

@test "npm alias: a script body is never executed (a body that would write a file leaves no file)" {
  mkdir -p "$BATS_TEST_TMPDIR/proj"
  printf '%s' '{"scripts":{"test":"touch should-not-exist && bats tests/*.bats"}}' > "$BATS_TEST_TMPDIR/proj/package.json"
  write_discovery "$BATS_TEST_TMPDIR/d.json" '[
    {"id":"npm:test","name":"npm test","type":"unit","ecosystem":"npm","command":"npm test"}]'
  cd "$BATS_TEST_TMPDIR/proj"
  catalog_ok --root "$BATS_TEST_TMPDIR/proj" --discovery-file "$BATS_TEST_TMPDIR/d.json"
  [ ! -e "$BATS_TEST_TMPDIR/proj/should-not-exist" ]
  json_check '(.runnable | length) == 1'
}

@test "npm alias: a missing script, a missing package.json and an invalid package.json each mean no alias, not an error" {
  write_discovery "$BATS_TEST_TMPDIR/d.json" '[
    {"id":"bats:tests","name":"bats tests","type":"unit","ecosystem":"bats","command":"bats tests/*.bats"},
    {"id":"npm:test","name":"npm test","type":"unit","ecosystem":"npm","command":"npm test"}]'
  mkdir -p "$BATS_TEST_TMPDIR/p1" "$BATS_TEST_TMPDIR/p2"
  printf '%s' '{"scripts":{"build":"tsc"}}' > "$BATS_TEST_TMPDIR/p1/package.json"
  printf '%s' '{ not json' > "$BATS_TEST_TMPDIR/p2/package.json"
  local root
  for root in "$BATS_TEST_TMPDIR/p1" "$BATS_TEST_TMPDIR/p2" "$EMPTY_ROOT"; do
    catalog_ok --root "$root" --discovery-file "$BATS_TEST_TMPDIR/d.json"
    json_check '[.runnable[].id] == ["bats:tests","npm:test"]'
  done
}

@test "npm alias: without --root, package.json is read from the root scripts/resolve-root.sh resolves" {
  local anchor="$BATS_TEST_TMPDIR/anchor"
  mkdir -p "$anchor/project/configs"
  printf '%s' '{}' > "$anchor/project/configs/workflow.json"
  cp "$FIX/npm-alias/package.json" "$anchor/package.json"
  run --separate-stderr env JENGA_PROJECT_ROOT="$anchor" "$BASH_BIN" "$BUILD" --discovery-file "$FIX/npm-alias/discovery.json"
  [ "$status" -eq 0 ]
  json_check '(.runnable | length) == 2 and .runnable[0].id == "npm:test"'
  json_check '(.runnable[0].also | map(.id)) == ["bats:tests","config:bats:integration"]'
}

# ===================================================================================================================
# Not runnable
# ===================================================================================================================

@test "an empty-command suite is listed under not_runnable with a reason, has no n, and is absent from runnable" {
  catalog_ok --root "$EMPTY_ROOT" --discovery-file "$FIX/empty-command.json"
  json_check '.not_runnable == [{id:"config:semgrep:sast",name:"semgrep (sast)",type:"sast",ecosystem:"config",reason:"no command declared"}]'
  json_check '[.runnable[].id] == ["npm:test","shellcheck:all"]'
  json_check '.not_runnable | all(has("n") | not)'
  json_check '[.runnable[].also[].id] | index("config:semgrep:sast") == null'
}

@test "empty-command suites never join a group, even two with the same empty command" {
  write_discovery "$BATS_TEST_TMPDIR/d.json" '[
    {"id":"config:a:unit","name":"a (unit)","type":"unit","ecosystem":"config","command":""},
    {"id":"config:b:unit","name":"b (unit)","type":"unit","ecosystem":"config","command":""}]'
  catalog_ok --root "$EMPTY_ROOT" --discovery-file "$BATS_TEST_TMPDIR/d.json"
  json_check '.runnable == [] and (.not_runnable | map(.id)) == ["config:a:unit","config:b:unit"]'
}

@test "a suite with an absent command is not runnable" {
  write_discovery "$BATS_TEST_TMPDIR/d.json" '[{"id":"x:y","name":"xy","type":"unit","ecosystem":"bats"}]'
  catalog_ok --root "$EMPTY_ROOT" --discovery-file "$BATS_TEST_TMPDIR/d.json"
  json_check '.runnable == [] and (.not_runnable | map(.id)) == ["x:y"]'
}

# ===================================================================================================================
# Catalog contract
# ===================================================================================================================

@test "contract: top-level and per-entry keys, and their order, are exactly as documented" {
  catalog_ok --root "$EMPTY_ROOT" --discovery-file "$FIX/empty-command.json"
  json_check 'keys_unsorted == ["runnable","not_runnable","warnings"]'
  json_check '.runnable[0] | keys_unsorted == ["n","id","name","type","ecosystem","command","also"]'
  json_check '.not_runnable[0] | keys_unsorted == ["id","name","type","ecosystem","reason"]'
}

@test "contract: stdout is one compact line" {
  catalog_ok --root "$EMPTY_ROOT" --discovery-file "$FIX/dup-command.json"
  [ "${#lines[@]}" -eq 1 ]
}

@test "contract: n is contiguous 1..N on every fixture" {
  local f
  for f in dup-command empty-command zero-suites already-clean npm-alias/discovery; do
    catalog_ok --root "$EMPTY_ROOT" --discovery-file "$FIX/$f.json"
    json_check '[.runnable[].n] == [range(1; (.runnable | length) + 1)]'
  done
}

@test "contract: numbering follows the id order of the surviving entries, not of the folded ones" {
  catalog_ok --root "$FIX/npm-alias" --discovery-file "$FIX/npm-alias/discovery.json"
  json_check '[.runnable[] | [.n, .id]] == [[1,"npm:test"],[2,"shellcheck:all"]]'
}

@test "contract: warnings are passed through from discovery" {
  catalog_ok --root "$EMPTY_ROOT" --discovery-file "$FIX/empty-command.json"
  json_check '.warnings == ["configured tool not detected on disk: semgrep (sast)","detected tool not listed in test-config.json: npm"]'
}

@test "contract: warnings is an empty array, never null, when discovery has none or omits the key" {
  catalog_ok --discovery-file "$FIX/zero-suites.json"
  json_check '.warnings == []'
  printf '%s' '{"suites":[]}' > "$BATS_TEST_TMPDIR/nowarn.json"
  catalog_ok --discovery-file "$BATS_TEST_TMPDIR/nowarn.json"
  json_check '.warnings == []'
}

@test "contract: zero suites gives empty runnable and not_runnable" {
  catalog_ok --discovery-file "$FIX/zero-suites.json"
  json_check '. == {runnable:[],not_runnable:[],warnings:[]}'
}

@test "contract: unknown keys on suites and on the discovery object are tolerated and not carried" {
  write_discovery "$BATS_TEST_TMPDIR/d.json" '[
    {"id":"bats:tests","name":"bats tests","type":"unit","ecosystem":"bats","command":"bats tests/*.bats","paths":["tests/a.bats"],"future":1}]'
  jq '. + {"version":2}' "$BATS_TEST_TMPDIR/d.json" > "$BATS_TEST_TMPDIR/d2.json"
  catalog_ok --root "$EMPTY_ROOT" --discovery-file "$BATS_TEST_TMPDIR/d2.json"
  json_check '.runnable[0] | keys_unsorted == ["n","id","name","type","ecosystem","command","also"]'
  json_check 'keys_unsorted == ["runnable","not_runnable","warnings"]'
}

@test "contract: absent name, type and ecosystem fall back to the id, unknown and empty" {
  write_discovery "$BATS_TEST_TMPDIR/d.json" '[{"id":"bare:one","command":"run it"}]'
  catalog_ok --root "$EMPTY_ROOT" --discovery-file "$BATS_TEST_TMPDIR/d.json"
  json_check '.runnable[0] == {n:1,id:"bare:one",name:"bare:one",type:"unknown",ecosystem:"",command:"run it",also:[]}'
}

@test "contract: input order does not matter, entries are numbered by id" {
  write_discovery "$BATS_TEST_TMPDIR/d.json" '[
    {"id":"b:x","name":"b","type":"unit","ecosystem":"bats","command":"cmd b"},
    {"id":"a:x","name":"a","type":"unit","ecosystem":"bats","command":"cmd a"}]'
  catalog_ok --root "$EMPTY_ROOT" --discovery-file "$BATS_TEST_TMPDIR/d.json"
  json_check '[.runnable[] | [.n,.id]] == [[1,"a:x"],[2,"b:x"]]'
}

@test "determinism: two runs over the same discovery input are byte-identical" {
  "$BASH_BIN" "$BUILD" --root "$FIX/npm-alias" --discovery-file "$FIX/npm-alias/discovery.json" > "$BATS_TEST_TMPDIR/run1.json"
  "$BASH_BIN" "$BUILD" --root "$FIX/npm-alias" --discovery-file "$FIX/npm-alias/discovery.json" > "$BATS_TEST_TMPDIR/run2.json"
  cmp "$BATS_TEST_TMPDIR/run1.json" "$BATS_TEST_TMPDIR/run2.json"
  LC_ALL=en_US.UTF-8 "$BASH_BIN" "$BUILD" --root "$FIX/npm-alias" --discovery-file "$FIX/npm-alias/discovery.json" > "$BATS_TEST_TMPDIR/run3.json"
  cmp "$BATS_TEST_TMPDIR/run1.json" "$BATS_TEST_TMPDIR/run3.json"
}

# ===================================================================================================================
# --render
# ===================================================================================================================

@test "render: folded suites show as [also covers: ...] and the prompt counts the runnable entries" {
  save_catalog alias --root "$FIX/npm-alias" --discovery-file "$FIX/npm-alias/discovery.json"
  catalog_ok --render "$BATS_TEST_TMPDIR/alias.json"
  local expected
  expected="Choose which tests to run:
1. npm test (unit) [also covers: bats tests (unit), bats (integration)]
2. shellcheck (sast)

Notes:
- detected tool not listed in test-config.json: npm

Enter selection (comma-separated, or 'all' for all, or blank for 1 through 2):"
  [ "$output" = "$expected" ]
}

@test "render: not-runnable suites get their own block, are unnumbered, and are excluded from the 1 through N count" {
  save_catalog empty --root "$EMPTY_ROOT" --discovery-file "$FIX/empty-command.json"
  catalog_ok --render "$BATS_TEST_TMPDIR/empty.json"
  local expected
  expected="Choose which tests to run:
1. npm test (unit)
2. shellcheck (sast)

Not runnable (listed only, cannot be selected):
- semgrep (sast): no command declared

Notes:
- configured tool not detected on disk: semgrep (sast)
- detected tool not listed in test-config.json: npm

Enter selection (comma-separated, or 'all' for all, or blank for 1 through 2):"
  [ "$output" = "$expected" ]
}

@test "render: the Not runnable and Notes blocks are omitted when empty" {
  save_catalog clean --discovery-file "$FIX/already-clean.json"
  catalog_ok --render "$BATS_TEST_TMPDIR/clean.json"
  local expected
  expected="Choose which tests to run:
1. go test ./... (unit)
2. pytest tests (unit)

Enter selection (comma-separated, or 'all' for all, or blank for 1 through 2):"
  [ "$output" = "$expected" ]
  assert_output_not_contains "Not runnable"
  assert_output_not_contains "Notes:"
}

@test "render: a single runnable suite reads 1 through 1" {
  write_discovery "$BATS_TEST_TMPDIR/d.json" '[{"id":"go:.","name":"go test ./...","type":"unit","ecosystem":"go","command":"go test ./..."}]'
  save_catalog one --discovery-file "$BATS_TEST_TMPDIR/d.json"
  catalog_ok --render "$BATS_TEST_TMPDIR/one.json"
  assert_output_contains "blank for 1 through 1):"
}

@test "render: zero suites prints No runnable test suites found., no prompt line, and exits 0" {
  save_catalog zero --discovery-file "$FIX/zero-suites.json"
  catalog_ok --render "$BATS_TEST_TMPDIR/zero.json"
  [ "$output" = "No runnable test suites found." ]
  assert_output_not_contains "Enter selection"
}

@test "render: zero runnable suites still shows the not-runnable and notes blocks, still with no prompt" {
  write_discovery "$BATS_TEST_TMPDIR/d.json" '[{"id":"config:semgrep:sast","name":"semgrep (sast)","type":"sast","ecosystem":"config","command":""}]' \
    '["configured tool not detected on disk: semgrep (sast)"]'
  save_catalog onlycfg --discovery-file "$BATS_TEST_TMPDIR/d.json"
  catalog_ok --render "$BATS_TEST_TMPDIR/onlycfg.json"
  local expected
  expected="No runnable test suites found.

Not runnable (listed only, cannot be selected):
- semgrep (sast): no command declared

Notes:
- configured tool not detected on disk: semgrep (sast)"
  [ "$output" = "$expected" ]
  assert_output_not_contains "Enter selection"
}

@test "render: a name that does not already end in its type gets (type) appended, one that does is left alone" {
  write_discovery "$BATS_TEST_TMPDIR/d.json" '[
    {"id":"a:1","name":"plain","type":"unit","ecosystem":"bats","command":"c1"},
    {"id":"b:1","name":"tool (unit)","type":"unit","ecosystem":"bats","command":"c2"}]'
  save_catalog names --discovery-file "$BATS_TEST_TMPDIR/d.json"
  catalog_ok --render "$BATS_TEST_TMPDIR/names.json"
  assert_output_contains "1. plain (unit)"
  assert_output_contains "2. tool (unit)"
  assert_output_not_contains "(unit) (unit)"
}

@test "render: a saved catalog is rendered without running discovery or reading any discovery file" {
  save_catalog alias --root "$FIX/npm-alias" --discovery-file "$FIX/npm-alias/discovery.json"
  make_copy
  run --separate-stderr "$BASH_BIN" "$COPY_DIR/build-catalog.sh" --render "$BATS_TEST_TMPDIR/alias.json"
  [ "$status" -eq 0 ]
  [ -z "$stderr" ]
  assert_output_contains "1. npm test (unit)"
  # No discover-tests.sh exists beside the copy, so reaching for it would have failed.
  [ ! -e "$COPY_DIR/discover-tests.sh" ]
}

# ===================================================================================================================
# Discovery wiring: --discovery-file and --render never discover, the default mode does and forwards --root
# ===================================================================================================================

@test "--discovery-file never invokes discover-tests.sh" {
  make_copy
  make_stub 0
  run --separate-stderr "$BASH_BIN" "$COPY_DIR/build-catalog.sh" --root "$EMPTY_ROOT" --discovery-file "$FIX/zero-suites.json"
  [ "$status" -eq 0 ]
  [ ! -e "$STUB_ARGS" ]
}

@test "--render never invokes discover-tests.sh" {
  save_catalog zero --discovery-file "$FIX/zero-suites.json"
  make_copy
  make_stub 0
  run --separate-stderr "$BASH_BIN" "$COPY_DIR/build-catalog.sh" --render "$BATS_TEST_TMPDIR/zero.json"
  [ "$status" -eq 0 ]
  [ ! -e "$STUB_ARGS" ]
}

@test "default mode runs the discover-tests.sh next to the script and forwards --root unchanged" {
  make_copy
  make_stub 0
  run --separate-stderr "$BASH_BIN" "$COPY_DIR/build-catalog.sh" --root "$EMPTY_ROOT"
  [ "$status" -eq 0 ]
  [ -z "$stderr" ]
  json_check '[.runnable[].id] == ["go:."]'
  [ "$(cat "$STUB_ARGS")" = "$(printf '%s\n%s' "--root" "$EMPTY_ROOT")" ]
}

@test "default mode without --root runs discovery with no arguments" {
  make_copy
  make_stub 0
  run --separate-stderr "$BASH_BIN" "$COPY_DIR/build-catalog.sh"
  [ "$status" -eq 0 ]
  [ ! -s "$STUB_ARGS" ]
}

@test "default mode: a failing discover-tests.sh exits 1 and names the cause on stderr" {
  make_copy
  make_stub 3
  run --separate-stderr "$BASH_BIN" "$COPY_DIR/build-catalog.sh" --root "$EMPTY_ROOT"
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  assert_contains "$stderr" "discover-tests.sh failed (exit 3)"
}

@test "default mode: a missing discover-tests.sh exits 1 and says so" {
  make_copy
  run --separate-stderr "$BASH_BIN" "$COPY_DIR/build-catalog.sh" --root "$EMPTY_ROOT"
  [ "$status" -eq 1 ]
  assert_contains "$stderr" "could not locate discover-tests.sh"
}

# ===================================================================================================================
# Exit codes
# ===================================================================================================================

@test "exit 0: --help prints usage" {
  catalog --help
  [ "$status" -eq 0 ]
  assert_output_contains "Usage: build-catalog.sh"
  assert_output_contains "--discovery-file"
  assert_output_contains "--render"
}

@test "exit 2: an unknown flag" {
  catalog --nope
  [ "$status" -eq 2 ]
  assert_contains "$stderr" "unknown argument: --nope"
}

@test "exit 2: a flag missing its argument (each of --root, --discovery-file, --render)" {
  local flag
  for flag in --root --discovery-file --render; do
    catalog "$flag"
    [ "$status" -eq 2 ]
    assert_contains "$stderr" "$flag requires an argument"
  done
}

@test "exit 2: --root that is not a directory" {
  catalog --root "$BATS_TEST_TMPDIR/does-not-exist" --discovery-file "$FIX/zero-suites.json"
  [ "$status" -eq 2 ]
  assert_contains "$stderr" "--root is not a directory"
}

@test "exit 2: --render combined with --root or --discovery-file" {
  save_catalog zero --discovery-file "$FIX/zero-suites.json"
  catalog --render "$BATS_TEST_TMPDIR/zero.json" --root "$EMPTY_ROOT"
  [ "$status" -eq 2 ]
  catalog --render "$BATS_TEST_TMPDIR/zero.json" --discovery-file "$FIX/zero-suites.json"
  [ "$status" -eq 2 ]
}

@test "exit 1: a missing discovery file, an unreadable-as-JSON one, and one of the wrong shape" {
  catalog --discovery-file "$BATS_TEST_TMPDIR/missing.json"
  [ "$status" -eq 1 ]
  assert_contains "$stderr" "discovery file is not a readable file"

  printf '%s' '{ not json' > "$BATS_TEST_TMPDIR/bad.json"
  catalog --discovery-file "$BATS_TEST_TMPDIR/bad.json"
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  assert_contains "$stderr" "not valid discovery JSON"

  printf '%s' '{"suites":"nope"}' > "$BATS_TEST_TMPDIR/shape.json"
  catalog --discovery-file "$BATS_TEST_TMPDIR/shape.json"
  [ "$status" -eq 1 ]
  assert_contains "$stderr" "not valid discovery JSON"

  : > "$BATS_TEST_TMPDIR/empty.json"
  catalog --discovery-file "$BATS_TEST_TMPDIR/empty.json"
  [ "$status" -eq 1 ]
}

@test "exit 1: --render of a missing file and of invalid catalog JSON" {
  catalog --render "$BATS_TEST_TMPDIR/missing.json"
  [ "$status" -eq 1 ]
  assert_contains "$stderr" "catalog file is not a readable file"

  printf '%s' '{ not json' > "$BATS_TEST_TMPDIR/bad.json"
  catalog --render "$BATS_TEST_TMPDIR/bad.json"
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  assert_contains "$stderr" "not valid catalog JSON"

  printf '%s' '{"runnable":"nope"}' > "$BATS_TEST_TMPDIR/shape.json"
  catalog --render "$BATS_TEST_TMPDIR/shape.json"
  [ "$status" -eq 1 ]
}

@test "exit 1: jq missing from PATH is named on stderr (in both modes)" {
  local nojq="$BATS_TEST_TMPDIR/bin-no-jq"
  make_bin "$nojq" no-jq
  printf '%s' '{"runnable":[],"not_runnable":[],"warnings":[]}' > "$BATS_TEST_TMPDIR/c.json"
  run --separate-stderr env PATH="$nojq" "$BASH_BIN" "$BUILD" --root "$EMPTY_ROOT" --discovery-file "$FIX/zero-suites.json"
  [ "$status" -eq 1 ]
  assert_contains "$stderr" "jq is required"
  run --separate-stderr env PATH="$nojq" "$BASH_BIN" "$BUILD" --render "$BATS_TEST_TMPDIR/c.json"
  [ "$status" -eq 1 ]
  assert_contains "$stderr" "jq is required"
}

@test "exit 0: zero suites is a valid answer in both modes" {
  catalog_ok --discovery-file "$FIX/zero-suites.json"
  save_catalog zero --discovery-file "$FIX/zero-suites.json"
  catalog_ok --render "$BATS_TEST_TMPDIR/zero.json"
}

# ===================================================================================================================
# Static properties
# ===================================================================================================================

@test "the script is executable and has mode 100755 in git" {
  [ -x "$BUILD" ]
  [ "$(git -C "$REPO_ROOT" ls-files -s -- skills/j-test/scripts/build-catalog.sh | cut -c1-6)" = "100755" ]
}

@test "the script passes shellcheck" {
  command -v shellcheck > /dev/null || skip "shellcheck is not installed"
  shellcheck -S warning "$BUILD"
}

@test "the script contains no hardcoded project/ path literal" {
  run grep -n 'project/' "$BUILD"
  [ "$status" -eq 1 ]
}

@test "the script is bash 3.2 clean: no associative arrays, mapfile or case-modification expansions" {
  run grep -n -E 'declare -A|mapfile|readarray|\$\{[A-Za-z_]+(\^\^|,,)\}' "$BUILD"
  [ "$status" -eq 1 ]
}

@test "the script writes nothing: the directories it reads are identical before and after, in both modes" {
  local before after
  before="$(cd "$FIX" && find . -type f -exec cksum {} + | sort)"
  cd "$BATS_TEST_TMPDIR"
  local listing_before listing_after
  listing_before="$(find "$BATS_TEST_TMPDIR" -mindepth 1 -maxdepth 1 | sort)"
  "$BASH_BIN" "$BUILD" --root "$FIX/npm-alias" --discovery-file "$FIX/npm-alias/discovery.json" > /dev/null
  listing_after="$(find "$BATS_TEST_TMPDIR" -mindepth 1 -maxdepth 1 | sort)"
  [ "$listing_before" = "$listing_after" ]
  after="$(cd "$FIX" && find . -type f -exec cksum {} + | sort)"
  [ "$before" = "$after" ]
}

@test "every fixture under tests/fixtures/j-test/catalog is valid JSON" {
  local f
  for f in "$FIX"/*.json "$FIX"/npm-alias/*.json; do
    jq -e . "$f" > /dev/null
  done
}
