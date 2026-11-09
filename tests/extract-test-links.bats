#!/usr/bin/env bats
# Coverage for scripts/extract-test-links.sh (E83_S02_T03): the annotation extractor that derives
# project/knowledge-graph/test-links.json from `arch-node:` lines inside test files. The grammar, the scan set, the exit codes
# and the output shape are documented in the script's own header; the decisions behind them are D1/D2/D6 of
# project/documentation/test-architecture-linking-spike.md, and the record schema is owned by scripts/validate-test-links.sh.
#
# Fixture-tree convention (the same one tests/populate-knowledge-graph.bats follows): every case builds its OWN synthetic
# project tree under $BATS_TEST_TMPDIR (setup() below) and drives the extractor at it with --root. Nothing here reads or
# writes this repository's own tests/, project/knowledge-graph/graph.json or test-links.json.
#
# Cases (numbers follow the task's description):
#   1. links for a bats file and a Node script are extracted with the right node, type, name, file and line
#   2. the output passes scripts/validate-test-links.sh (also with --graph)
#   3. two runs are byte-identical (and the --stdout form equals the written file)
#   4. generated_from carries the graph hash and one hash per linked file, and the hashes change with the graph / a file
#   5. a link to a node id that is not in graph.json is warned about on stderr and still written
#   6. a malformed entry is skipped with a file:line message and exit 3, while valid links are still written
#   7. --stdout creates no file
#   8. a missing graph.json yields graph_sha256 "absent" rather than a failure
#   9. the test files and graph in the fixture are unmodified after the run
# Extras: file-level binding, usage errors, --out, and the atomic write leaving no temporary file behind.
#
# The extractor is committed mode 644 and is always called as `bash scripts/extract-test-links.sh`.

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
SCRIPT="$REPO_ROOT/scripts/extract-test-links.sh"
VALIDATOR="$REPO_ROOT/scripts/validate-test-links.sh"

setup() {
  FIX="$BATS_TEST_TMPDIR/proj"
  KG="$FIX/project/knowledge-graph"
  LINKS="$KG/test-links.json"
  OUT_F="$BATS_TEST_TMPDIR/stdout"
  ERR_F="$BATS_TEST_TMPDIR/stderr"
  mkdir -p "$KG" "$FIX/tests" "$FIX/lib"

  printf '%s\n' '{"nodes":[{"id":"N_ONE","type":"story"},{"id":"N_TWO","type":"story"}],"edges":[]}' > "$KG/graph.json"

  # tests/sample.bats: ONE annotation with two ids above a test declaration (test-level, line 3).
  printf '%s\n' \
    '#!/usr/bin/env bats' \
    '# arch-node: N_ONE,N_TWO type=integration' \
    '@test "first case" {' \
    '  true' \
    '}' > "$FIX/tests/sample.bats"

  # lib/a.test.js: a Node test-level link (test declaration on line 2).
  printf '%s\n' \
    '// arch-node: N_ONE type=unit' \
    "test('does the thing', () => {" \
    '});' > "$FIX/lib/a.test.js"

  # tests/nolink.bats: a scanned file with no annotation, so it must never be hashed or linked.
  printf '%s\n' \
    '#!/usr/bin/env bats' \
    '@test "unlinked" {' \
    '  true' \
    '}' > "$FIX/tests/nolink.bats"
}

# extract <args...>: run the extractor; stdout -> $OUT_F, stderr -> $ERR_F, exit status -> $rc (never fails the test itself).
extract() {
  rc=0
  bash "$SCRIPT" "$@" >"$OUT_F" 2>"$ERR_F" || rc=$?
}

# sha <path>: SHA-256 hex of a file, whichever tool exists.
sha() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  else
    sha256sum "$1" | awk '{print $1}'
  fi
}

# snapshot: "<sha> <path>" for every fixture file except the generated links file, sorted.
snapshot() {
  (
    cd "$FIX" || exit 1
    find . -type f ! -name test-links.json | LC_ALL=C sort | while IFS= read -r f; do
      printf '%s %s\n' "$(sha "$f")" "$f"
    done
  )
}

# --- 1. extraction ---------------------------------------------------------------------------------------------------

@test "bats and Node links are extracted with the right node, type, name, file and line" {
  extract --root "$FIX"
  [ "$rc" -eq 0 ]
  [ -f "$LINKS" ]
  run jq -e '.schema_version == 1' "$LINKS"
  [ "$status" -eq 0 ]
  run jq -c '[.links[] | [.node_id, .type, .name, .file, .line, .test_id]]' "$LINKS"
  [ "$status" -eq 0 ]
  [ "$output" = '[["N_ONE","unit","does the thing","lib/a.test.js",2,"lib/a.test.js::does the thing"],["N_ONE","integration","first case","tests/sample.bats",3,"tests/sample.bats::first case"],["N_TWO","integration","first case","tests/sample.bats",3,"tests/sample.bats::first case"]]' ]
}

@test "the summary line on stderr counts the links and the linked files, and stdout stays empty" {
  extract --root "$FIX"
  [ "$rc" -eq 0 ]
  [ ! -s "$OUT_F" ]
  grep -q '3 link(s) from 2 test file(s)' "$ERR_F"
}

# --- 2. validator ---------------------------------------------------------------------------------------------------

@test "the output passes validate-test-links.sh, with and without --graph" {
  extract --root "$FIX"
  [ "$rc" -eq 0 ]
  run bash "$VALIDATOR" "$LINKS"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  run bash "$VALIDATOR" --graph "$KG/graph.json" "$LINKS"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# --- 3. determinism -------------------------------------------------------------------------------------------------

@test "two runs on unchanged input are byte-identical" {
  extract --root "$FIX"
  [ "$rc" -eq 0 ]
  cp "$LINKS" "$BATS_TEST_TMPDIR/first.json"
  extract --root "$FIX"
  [ "$rc" -eq 0 ]
  cmp "$BATS_TEST_TMPDIR/first.json" "$LINKS"
  # the file ends with a newline and carries no timestamp
  [ "$(tail -c 1 "$LINKS" | od -An -c | tr -d ' ')" = '\n' ]
  run grep -i -E 'time|date|generated_at' "$LINKS"
  [ "$status" -ne 0 ]
}

@test "the --stdout output is byte-identical to the file a normal run writes" {
  extract --root "$FIX"
  [ "$rc" -eq 0 ]
  extract --root "$FIX" --stdout
  [ "$rc" -eq 0 ]
  cmp "$OUT_F" "$LINKS"
}

@test "links are sorted by node id then file, and the hash keys are sorted" {
  # a second bats file whose name sorts before sample.bats and whose node id sorts after N_TWO
  printf '%s\n' \
    '# arch-node: N_TWO type=unit' \
    '@test "a later node" {' \
    '}' > "$FIX/tests/aaa.bats"
  extract --root "$FIX"
  [ "$rc" -eq 0 ]
  run jq -c '[.links[] | [.node_id, .file]]' "$LINKS"
  [ "$output" = '[["N_ONE","lib/a.test.js"],["N_ONE","tests/sample.bats"],["N_TWO","tests/aaa.bats"],["N_TWO","tests/sample.bats"]]' ]
  run jq -c '.generated_from.tests | keys' "$LINKS"
  [ "$output" = '["lib/a.test.js","tests/aaa.bats","tests/sample.bats"]' ]
}

# --- 4. generated_from hashes ---------------------------------------------------------------------------------------

@test "generated_from holds the graph hash and exactly one hash per linked file" {
  extract --root "$FIX"
  [ "$rc" -eq 0 ]
  run jq -r '.generated_from.graph_sha256' "$LINKS"
  [ "$output" = "$(sha "$FIX/project/knowledge-graph/graph.json")" ]
  run jq -c '.generated_from.tests | keys' "$LINKS"
  [ "$output" = '["lib/a.test.js","tests/sample.bats"]' ]
  run jq -r '.generated_from.tests["tests/sample.bats"]' "$LINKS"
  [ "$output" = "$(sha "$FIX/tests/sample.bats")" ]
  run jq -r '.generated_from.tests["lib/a.test.js"]' "$LINKS"
  [ "$output" = "$(sha "$FIX/lib/a.test.js")" ]
}

@test "the graph hash changes when the graph changes, and a file hash changes when that file changes" {
  extract --root "$FIX"
  [ "$rc" -eq 0 ]
  g0="$(jq -r '.generated_from.graph_sha256' "$LINKS")"
  s0="$(jq -r '.generated_from.tests["tests/sample.bats"]' "$LINKS")"
  j0="$(jq -r '.generated_from.tests["lib/a.test.js"]' "$LINKS")"

  # change the graph only (an extra node)
  printf '%s\n' '{"nodes":[{"id":"N_ONE"},{"id":"N_TWO"},{"id":"N_THREE"}],"edges":[]}' > "$KG/graph.json"
  extract --root "$FIX"
  [ "$rc" -eq 0 ]
  g1="$(jq -r '.generated_from.graph_sha256' "$LINKS")"
  [ "$g1" != "$g0" ]
  [ "$g1" = "$(sha "$KG/graph.json")" ]
  [ "$(jq -r '.generated_from.tests["tests/sample.bats"]' "$LINKS")" = "$s0" ]
  [ "$(jq -r '.generated_from.tests["lib/a.test.js"]' "$LINKS")" = "$j0" ]

  # change one linked file only (a trailing comment; the link itself does not move)
  printf '%s\n' '# touched' >> "$FIX/tests/sample.bats"
  extract --root "$FIX"
  [ "$rc" -eq 0 ]
  [ "$(jq -r '.generated_from.graph_sha256' "$LINKS")" = "$g1" ]
  s1="$(jq -r '.generated_from.tests["tests/sample.bats"]' "$LINKS")"
  [ "$s1" != "$s0" ]
  [ "$s1" = "$(sha "$FIX/tests/sample.bats")" ]
  [ "$(jq -r '.generated_from.tests["lib/a.test.js"]' "$LINKS")" = "$j0" ]
}

# --- 5. node id missing from the graph ------------------------------------------------------------------------------

@test "a link to a node id that is not in graph.json is warned about on stderr and still written" {
  printf '%s\n' \
    '# arch-node: N_GHOST type=unit' \
    '@test "ghost link" {' \
    '}' > "$FIX/tests/ghost.bats"
  extract --root "$FIX"
  [ "$rc" -eq 0 ]
  grep -q 'warning: tests/ghost.bats:2: node id N_GHOST is not in graph.json' "$ERR_F"
  # the known ids produce no warning
  run grep -c 'is not in graph.json' "$ERR_F"
  [ "$output" = "1" ]
  run jq -c '[.links[] | select(.node_id == "N_GHOST") | [.file, .line, .name]]' "$LINKS"
  [ "$output" = '[["tests/ghost.bats",2,"ghost link"]]' ]
  # the validator accepts the file as such, and only --graph flags the dangling id
  run bash "$VALIDATOR" "$LINKS"
  [ "$status" -eq 0 ]
  run bash "$VALIDATOR" --graph "$KG/graph.json" "$LINKS"
  [ "$status" -eq 1 ]
  [[ "$output" == *"dangling-node"* ]]
}

# --- 6. malformed entries -------------------------------------------------------------------------------------------

@test "a malformed entry is skipped with a file:line message and exit 3 while valid links are still written" {
  printf '%s\n' \
    '#!/usr/bin/env bats' \
    '# arch-node: N_ONE' \
    '@test "no type" {' \
    '  true' \
    '}' \
    '# arch-node: N_TWO type=unit' \
    '@test "ok one" {' \
    '}' > "$FIX/tests/bad.bats"
  extract --root "$FIX"
  [ "$rc" -eq 3 ]
  # the message names the file and the annotation's own line, and says what is wrong
  grep -q 'tests/bad.bats:2: malformed arch-node annotation: missing type= token' "$ERR_F"
  grep -q '1 malformed entry skipped' "$ERR_F"
  # the file was still written and validates; the skipped one is absent, the valid one present
  [ -f "$LINKS" ]
  run bash "$VALIDATOR" "$LINKS"
  [ "$status" -eq 0 ]
  run jq -c '[.links[] | select(.file == "tests/bad.bats") | [.node_id, .name, .line]]' "$LINKS"
  [ "$output" = '[["N_TWO","ok one",7]]' ]
  # links from the well-formed files are untouched
  run jq '[.links[] | select(.file != "tests/bad.bats")] | length' "$LINKS"
  [ "$output" = "3" ]
}

@test "an unknown type, an unknown token and a non-literal title are each reported at the annotation line" {
  printf '%s\n' \
    '# arch-node: N_ONE type=bogus' \
    '@test "unknown type" {' \
    '}' \
    '# arch-node: N_ONE type=unit extra=1' \
    '@test "extra token" {' \
    '}' \
    '# arch-node: N_ONE type=unit' \
    '@test "has \$dollar" {' \
    '}' > "$FIX/tests/bad2.bats"
  extract --root "$FIX"
  [ "$rc" -eq 3 ]
  grep -q 'tests/bad2.bats:1: .*unknown type "bogus"' "$ERR_F"
  grep -q 'tests/bad2.bats:4: .*unknown token "extra=1"' "$ERR_F"
  grep -q 'tests/bad2.bats:7: .*not a plain string literal' "$ERR_F"
  run jq '[.links[] | select(.file == "tests/bad2.bats")] | length' "$LINKS"
  [ "$output" = "0" ]
  run jq -e '.generated_from.tests | has("tests/bad2.bats") | not' "$LINKS"
  [ "$status" -eq 0 ]
}

@test "a duplicate (node id, test) pair in one file is reported and the first one is kept" {
  printf '%s\n' \
    '# arch-node: N_ONE type=unit' \
    '# arch-node: N_ONE type=integration' \
    '@test "twice" {' \
    '}' > "$FIX/tests/dup.bats"
  extract --root "$FIX"
  [ "$rc" -eq 3 ]
  grep -q 'tests/dup.bats:2: duplicate link' "$ERR_F"
  run jq -c '[.links[] | select(.file == "tests/dup.bats") | .type]' "$LINKS"
  [ "$output" = '["unit"]' ]
}

# --- 7. --stdout ----------------------------------------------------------------------------------------------------

@test "--stdout prints valid JSON and creates no file" {
  extract --root "$FIX" --stdout
  [ "$rc" -eq 0 ]
  [ ! -e "$LINKS" ]
  # the knowledge-graph directory still holds only the graph, with no temporary or lock leftovers
  [ "$(ls -A "$KG")" = "graph.json" ]
  run jq -e '.schema_version == 1 and (.links | length) == 3' "$OUT_F"
  [ "$status" -eq 0 ]
  run bash "$VALIDATOR" "$OUT_F"
  [ "$status" -eq 0 ]
}

# --- 8. missing graph -----------------------------------------------------------------------------------------------

@test "a missing graph.json yields graph_sha256 absent, not a failure" {
  rm "$KG/graph.json"
  extract --root "$FIX"
  [ "$rc" -eq 0 ]
  [ -f "$LINKS" ]
  run jq -r '.generated_from.graph_sha256' "$LINKS"
  [ "$output" = "absent" ]
  # with no graph there is nothing to check node ids against, so no warning either
  run grep -c 'is not in graph.json' "$ERR_F"
  [ "$output" = "0" ]
  run jq '.links | length' "$LINKS"
  [ "$output" = "3" ]
  run bash "$VALIDATOR" "$LINKS"
  [ "$status" -eq 0 ]
}

# --- 9. read-only on the fixture ------------------------------------------------------------------------------------

@test "the test files and the graph are unmodified after a run" {
  before="$(snapshot)"
  extract --root "$FIX"
  [ "$rc" -eq 0 ]
  [ "$before" = "$(snapshot)" ]
  # a --stdout run and a run with annotations that fail are read-only as well
  printf '%s\n' '# arch-node: N_ONE' '@test "bad" {' '}' > "$FIX/tests/bad.bats"
  before="$(snapshot)"
  extract --root "$FIX"
  [ "$rc" -eq 3 ]
  extract --root "$FIX" --stdout
  [ "$rc" -eq 3 ]
  [ "$before" = "$(snapshot)" ]
  # the only thing written is the links file
  [ "$(ls -A "$KG")" = "$(printf 'graph.json\ntest-links.json')" ]
}

# --- extras ---------------------------------------------------------------------------------------------------------

@test "an annotation not followed by a test declaration is a file-level link" {
  printf '%s\n' \
    '# arch-node: N_TWO type=e2e' \
    '' \
    'echo header' \
    '@test "later" {' \
    '}' > "$FIX/tests/header.bats"
  extract --root "$FIX"
  [ "$rc" -eq 0 ]
  run jq -c '.links[] | select(.file == "tests/header.bats") | [.node_id, .type, .name, .line, .test_id]' "$LINKS"
  [ "$output" = '["N_TWO","e2e","tests/header.bats",1,"tests/header.bats"]' ]
}

@test "files under node_modules, fixtures and dot-directories are not scanned" {
  mkdir -p "$FIX/node_modules/pkg" "$FIX/lib/fixtures" "$FIX/.hidden"
  for d in node_modules/pkg lib/fixtures .hidden; do
    printf '%s\n' '// arch-node: N_ONE type=unit' "test('skipped', () => {" '});' > "$FIX/$d/x.test.js"
  done
  extract --root "$FIX"
  [ "$rc" -eq 0 ]
  run jq -c '[.links[].file] | unique' "$LINKS"
  [ "$output" = '["lib/a.test.js","tests/sample.bats"]' ]
}

@test "--out writes to the given file and not to the default location" {
  extract --root "$FIX" --out "$BATS_TEST_TMPDIR/custom/out.json"
  [ "$rc" -eq 0 ]
  [ -f "$BATS_TEST_TMPDIR/custom/out.json" ]
  [ ! -e "$LINKS" ]
  run bash "$VALIDATOR" "$BATS_TEST_TMPDIR/custom/out.json"
  [ "$status" -eq 0 ]
}

@test "the write is atomic: a stale output is replaced whole and no temporary or lock file is left behind" {
  printf '%s\n' 'stale, not even JSON' > "$LINKS"
  extract --root "$FIX"
  [ "$rc" -eq 0 ]
  run jq -e '.schema_version == 1' "$LINKS"
  [ "$status" -eq 0 ]
  run grep -q stale "$LINKS"
  [ "$status" -ne 0 ]
  [ "$(ls -A "$KG")" = "$(printf 'graph.json\ntest-links.json')" ]
}

@test "usage errors exit 2 and write no file" {
  extract --root "$FIX" --bogus
  [ "$rc" -eq 2 ]
  extract --root "$FIX" --stdout --out "$BATS_TEST_TMPDIR/o.json"
  [ "$rc" -eq 2 ]
  [ ! -e "$BATS_TEST_TMPDIR/o.json" ]
  extract --root
  [ "$rc" -eq 2 ]
  extract --root "$BATS_TEST_TMPDIR/does-not-exist"
  [ "$rc" -eq 2 ]
  [ ! -e "$LINKS" ]
}

@test "--help prints usage on stdout and exits 0" {
  extract --help
  [ "$rc" -eq 0 ]
  grep -q '^usage: extract-test-links.sh' "$OUT_F"
}
