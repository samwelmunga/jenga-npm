#!/usr/bin/env bats
# Coverage for scripts/check-test-links.sh (E83_S04_T02): the read-only freshness check of the derived links file
# project/knowledge-graph/test-links.json. The verdicts, reasons, exit codes and JSON shape are documented in the script's
# own header; the record schema is owned by scripts/validate-test-links.sh and the file is written only by
# scripts/extract-test-links.sh.
#
# Fixture-tree convention (the same one tests/extract-test-links.bats follows): every case builds its OWN synthetic project
# tree under $BATS_TEST_TMPDIR (setup() below), produces the links file with `extract-test-links.sh --root <fixture>`, and
# drives the checker at it with --root. Nothing here reads or writes this repository's own tests/, graph.json or
# test-links.json; the repository root is derived from $BATS_TEST_FILENAME, never from the working directory.
#
# Cases:
#   1. a fresh fixture is `fresh`, exit 0, in the human and the --json form (also with --links pointing elsewhere)
#   2. one case per staleness reason, each exit 1 with the reason in both the human and the --json output:
#      graph-changed, test-changed, test-removed, node-missing, node-superseded (with superseded_by named, and null when the
#      graph omits it), no-links-file; plus the documented ordering of several reasons at once
#   3. an invalid links file (bad JSON, wrong shape, a violated rule) exits 2 with the validator's message and no verdict
#   4. unlinked-new-test is informational: it appears, never changes a fresh verdict, skips annotated files, and is capped
#   5. --json is one object that parses with jq, with the documented keys
#   6. every fixture file, the graph and the links file are byte-identical after every run
# Extras: usage errors and --help.
#
# The checker is committed mode 644 and is always called as `bash scripts/check-test-links.sh`.

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
SCRIPT="$REPO_ROOT/scripts/check-test-links.sh"
EXTRACT="$REPO_ROOT/scripts/extract-test-links.sh"
VALIDATOR="$REPO_ROOT/scripts/validate-test-links.sh"

setup() {
  if ! command -v jq >/dev/null 2>&1; then
    skip "jq is not installed (check-test-links.sh needs it)"
  fi
  if [ ! -f "$SCRIPT" ]; then
    skip "scripts/check-test-links.sh is absent"
  fi
  if [ ! -f "$EXTRACT" ] || [ ! -f "$VALIDATOR" ]; then
    skip "scripts/extract-test-links.sh or scripts/validate-test-links.sh is absent"
  fi

  FIX="$BATS_TEST_TMPDIR/proj"
  KG="$FIX/project/knowledge-graph"
  GRAPH="$KG/graph.json"
  LINKS="$KG/test-links.json"
  HUM_OUT="$BATS_TEST_TMPDIR/human.out"
  HUM_ERR="$BATS_TEST_TMPDIR/human.err"
  JSON_OUT="$BATS_TEST_TMPDIR/json.out"
  JSON_ERR="$BATS_TEST_TMPDIR/json.err"
  mkdir -p "$KG" "$FIX/tests" "$FIX/lib"

  printf '%s\n' '{"nodes":[{"id":"N_ONE","type":"story"},{"id":"N_TWO","type":"story"}],"edges":[]}' > "$GRAPH"

  # tests/sample.bats: one annotation with two ids above a test declaration.
  printf '%s\n' \
    '#!/usr/bin/env bats' \
    '# arch-node: N_ONE,N_TWO type=integration' \
    '@test "first case" {' \
    '  true' \
    '}' > "$FIX/tests/sample.bats"

  # lib/a.test.js: a Node test-level link.
  printf '%s\n' \
    '// arch-node: N_ONE type=unit' \
    "test('does the thing', () => {" \
    '});' > "$FIX/lib/a.test.js"

  # The links file is produced by the real extractor, so the fixture is fresh by construction.
  run bash "$EXTRACT" --root "$FIX"
  [ "$status" -eq 0 ]
  [ -f "$LINKS" ]
}

# sha <path>: SHA-256 hex of a file, whichever tool exists.
sha() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  else
    sha256sum "$1" | awk '{print $1}'
  fi
}

# snapshot: "<sha> <path>" for EVERY file under the fixture root (graph and links file included), sorted.
snapshot() {
  (
    cd "$FIX" || exit 1
    find . -type f | LC_ALL=C sort | while IFS= read -r f; do
      printf '%s %s\n' "$(sha "$f")" "$f"
    done
  )
}

# reextract: regenerate the links file from the fixture as it is now (so the links match the changed graph/tests).
reextract() {
  run bash "$EXTRACT" --root "$FIX"
  [ "$status" -eq 0 ]
}

# check_both <extra args...>: run the checker twice against $FIX, once for the human form and once with --json, so a case
# can assert the verdict in both. Sets human_rc, json_rc and the four capture files, and brackets both runs with
# fixture snapshots (SNAP_BEFORE / SNAP_AFTER) for assert_untouched.
check_both() {
  SNAP_BEFORE="$(snapshot)"
  human_rc=0
  bash "$SCRIPT" --root "$FIX" "$@" >"$HUM_OUT" 2>"$HUM_ERR" || human_rc=$?
  json_rc=0
  bash "$SCRIPT" --root "$FIX" --json "$@" >"$JSON_OUT" 2>"$JSON_ERR" || json_rc=$?
  SNAP_AFTER="$(snapshot)"
}

# assert_untouched: the checker modified, created or removed nothing under the fixture.
assert_untouched() {
  [ -n "$SNAP_BEFORE" ]
  [ "$SNAP_BEFORE" = "$SNAP_AFTER" ]
}

# jq_json <filter>: evaluate a jq filter over the --json output into $output (compact).
jq_json() {
  run jq -c "$1" "$JSON_OUT"
  [ "$status" -eq 0 ]
}

# --- 1. fresh -------------------------------------------------------------------------------------------------------

@test "a fresh fixture is fresh with exit 0 in the human and the JSON form" {
  check_both
  [ "$human_rc" -eq 0 ]
  [ "$json_rc" -eq 0 ]
  [ "$(cat "$HUM_OUT")" = "fresh: 3 link(s) from 2 test file(s) match the graph and the tests" ]
  [ ! -s "$HUM_ERR" ]
  [ ! -s "$JSON_ERR" ]
  jq_json '[.status, .reasons, .informational]'
  [ "$output" = '["fresh",[],[]]' ]
  assert_untouched
}

@test "a links file given with --links is checked in place of the default one" {
  cp "$LINKS" "$BATS_TEST_TMPDIR/elsewhere.json"
  rm -f "$LINKS"
  check_both --links "$BATS_TEST_TMPDIR/elsewhere.json"
  [ "$human_rc" -eq 0 ]
  [ "$json_rc" -eq 0 ]
  jq_json '.status'
  [ "$output" = '"fresh"' ]
  [ ! -e "$LINKS" ]
  assert_untouched
}

# --- 2. one case per reason ------------------------------------------------------------------------------------------

@test "graph-changed: a changed graph.json is stale with the recorded and the current hash" {
  recorded="$(sha "$GRAPH")"
  printf '%s\n' '{"nodes":[{"id":"N_ONE"},{"id":"N_TWO"},{"id":"N_THREE"}],"edges":[]}' > "$GRAPH"
  current="$(sha "$GRAPH")"
  [ "$recorded" != "$current" ]
  check_both
  [ "$human_rc" -eq 1 ]
  [ "$json_rc" -eq 1 ]
  grep -q '^stale: 1 reason(s)$' "$HUM_OUT"
  grep -q 'graph-changed' "$HUM_OUT"
  jq_json '.status'
  [ "$output" = '"stale"' ]
  jq_json '[.reasons[] | .type]'
  [ "$output" = '["graph-changed"]' ]
  jq_json '.reasons[0] | [.recorded, .current]'
  [ "$output" = "[\"$recorded\",\"$current\"]" ]
  assert_untouched
}

@test "graph-changed: a deleted graph.json reports the current hash as absent" {
  rm -f "$GRAPH"
  check_both
  [ "$human_rc" -eq 1 ]
  [ "$json_rc" -eq 1 ]
  grep -q 'graph-changed' "$HUM_OUT"
  jq_json '.reasons[] | select(.type == "graph-changed") | .current'
  [ "$output" = '"absent"' ]
  # with no graph every link's node is gone too: one node-missing reason per link
  jq_json '[.reasons[] | select(.type == "node-missing")] | length'
  [ "$output" = "3" ]
  assert_untouched
}

@test "test-changed: an edited linked test file is stale and names the file" {
  recorded="$(sha "$FIX/lib/a.test.js")"
  printf '%s\n' '// an extra line' >> "$FIX/lib/a.test.js"
  current="$(sha "$FIX/lib/a.test.js")"
  check_both
  [ "$human_rc" -eq 1 ]
  [ "$json_rc" -eq 1 ]
  grep -q 'test-changed: lib/a.test.js' "$HUM_OUT"
  jq_json '[.reasons[] | .type]'
  [ "$output" = '["test-changed"]' ]
  jq_json '.reasons[0] | [.file, .recorded, .current]'
  [ "$output" = "[\"lib/a.test.js\",\"$recorded\",\"$current\"]" ]
  assert_untouched
}

@test "test-removed: a deleted linked test file is stale and names the file" {
  recorded="$(sha "$FIX/lib/a.test.js")"
  rm -f "$FIX/lib/a.test.js"
  check_both
  [ "$human_rc" -eq 1 ]
  [ "$json_rc" -eq 1 ]
  grep -q 'test-removed: lib/a.test.js' "$HUM_OUT"
  jq_json '[.reasons[] | .type]'
  [ "$output" = '["test-removed"]' ]
  jq_json '.reasons[0] | [.file, .recorded]'
  [ "$output" = "[\"lib/a.test.js\",\"$recorded\"]" ]
  assert_untouched
}

@test "node-missing: a link whose node left the graph is stale, one reason per link" {
  printf '%s\n' '{"nodes":[{"id":"N_ONE"}],"edges":[]}' > "$GRAPH"
  reextract
  check_both
  [ "$human_rc" -eq 1 ]
  [ "$json_rc" -eq 1 ]
  grep -q 'node-missing: N_TWO (tests/sample.bats::first case)' "$HUM_OUT"
  jq_json '[.reasons[] | .type]'
  [ "$output" = '["node-missing"]' ]
  jq_json '.reasons[0] | [.node_id, .test_id, .file]'
  [ "$output" = '["N_TWO","tests/sample.bats::first case","tests/sample.bats"]' ]
  assert_untouched
}

@test "node-superseded: a superseded node is stale and superseded_by names its replacement" {
  printf '%s\n' '{"nodes":[{"id":"N_ONE"},{"id":"N_TWO","status":"superseded","superseded_by":"N_ONE"}],"edges":[]}' > "$GRAPH"
  reextract
  check_both
  [ "$human_rc" -eq 1 ]
  [ "$json_rc" -eq 1 ]
  grep -q 'node-superseded: N_TWO superseded by N_ONE (tests/sample.bats::first case)' "$HUM_OUT"
  jq_json '[.reasons[] | .type]'
  [ "$output" = '["node-superseded"]' ]
  jq_json '.reasons[0] | [.node_id, .superseded_by, .test_id, .file]'
  [ "$output" = '["N_TWO","N_ONE","tests/sample.bats::first case","tests/sample.bats"]' ]
  assert_untouched
}

@test "node-superseded: a superseded node without superseded_by reports null (and unknown in the human form)" {
  printf '%s\n' '{"nodes":[{"id":"N_ONE"},{"id":"N_TWO","status":"superseded"}],"edges":[]}' > "$GRAPH"
  reextract
  check_both
  [ "$human_rc" -eq 1 ]
  [ "$json_rc" -eq 1 ]
  grep -q 'node-superseded: N_TWO superseded by unknown' "$HUM_OUT"
  jq_json '.reasons[0] | [.type, .superseded_by]'
  [ "$output" = '["node-superseded",null]' ]
  assert_untouched
}

@test "no-links-file: a missing links file is stale with exit 1 and the path, not an error" {
  rm -f "$LINKS"
  # the checker reports the path under the root as `cd <root> && pwd` spells it
  expected_links="$(cd "$FIX" && pwd)/project/knowledge-graph/test-links.json"
  check_both
  [ "$human_rc" -eq 1 ]
  [ "$json_rc" -eq 1 ]
  grep -F -q "no-links-file: $expected_links" "$HUM_OUT"
  jq_json '[.status, [.reasons[] | .type], .informational]'
  [ "$output" = '["stale",["no-links-file"],[]]' ]
  jq_json '.reasons[0].links'
  [ "$output" = "\"$expected_links\"" ]
  [ ! -e "$LINKS" ]
  assert_untouched
}

@test "several reasons at once are reported in the documented order and each makes the verdict stale" {
  # graph without N_TWO (graph-changed + node-missing), an edited a.test.js (test-changed), a removed sample.bats
  # (test-removed): order is graph-changed, then test-changed / test-removed by file path, then the node reasons.
  printf '%s\n' '{"nodes":[{"id":"N_ONE"}],"edges":[]}' > "$GRAPH"
  printf '%s\n' '// an extra line' >> "$FIX/lib/a.test.js"
  rm -f "$FIX/tests/sample.bats"
  check_both
  [ "$human_rc" -eq 1 ]
  [ "$json_rc" -eq 1 ]
  grep -q '^stale: 4 reason(s)$' "$HUM_OUT"
  jq_json '[.reasons[] | .type]'
  [ "$output" = '["graph-changed","test-changed","test-removed","node-missing"]' ]
  jq_json '[.reasons[] | .file // empty]'
  [ "$output" = '["lib/a.test.js","tests/sample.bats","tests/sample.bats"]' ]
  assert_untouched
}

# --- 3. invalid links file ------------------------------------------------------------------------------------------

@test "a links file that is not JSON exits 2 with the validator's message and prints no verdict" {
  printf '%s\n' 'this is not json' > "$LINKS"
  check_both
  [ "$human_rc" -eq 2 ]
  [ "$json_rc" -eq 2 ]
  [ ! -s "$HUM_OUT" ]
  [ ! -s "$JSON_OUT" ]
  grep -q 'rejected by validate-test-links.sh' "$HUM_ERR"
  grep -q 'rejected by validate-test-links.sh' "$JSON_ERR"
  assert_untouched
}

@test "a links file with the wrong shape or a violated rule exits 2 and names the rule" {
  printf '%s\n' '{"schema_version":2,"generated_from":{"graph_sha256":"absent","tests":{}},"links":[]}' > "$LINKS"
  check_both
  [ "$human_rc" -eq 2 ]
  [ "$json_rc" -eq 2 ]
  [ ! -s "$HUM_OUT" ]
  [ ! -s "$JSON_OUT" ]
  grep -q 'rule schema_version' "$HUM_ERR"
  assert_untouched

  printf '%s\n' '[]' > "$LINKS"
  check_both
  [ "$human_rc" -eq 2 ]
  [ "$json_rc" -eq 2 ]
  [ ! -s "$HUM_OUT" ]
  assert_untouched
}

@test "a links path that is a directory exits 2" {
  rm -f "$LINKS"
  mkdir -p "$LINKS"
  check_both
  [ "$human_rc" -eq 2 ]
  [ "$json_rc" -eq 2 ]
  [ ! -s "$HUM_OUT" ]
  grep -q 'not a readable regular file' "$HUM_ERR"
  rmdir "$LINKS"
}

# --- 4. unlinked-new-test is informational --------------------------------------------------------------------------

@test "an unannotated new test file is listed as informational and leaves a fresh fixture fresh" {
  printf '%s\n' '#!/usr/bin/env bats' '@test "new" {' '  true' '}' > "$FIX/tests/new.bats"
  printf '%s\n' "test('new js', () => {});" > "$FIX/lib/new.test.js"
  check_both
  [ "$human_rc" -eq 0 ]
  [ "$json_rc" -eq 0 ]
  grep -q '^fresh: ' "$HUM_OUT"
  grep -q '^informational:$' "$HUM_OUT"
  grep -q '  unlinked-new-test: tests/new.bats' "$HUM_OUT"
  grep -q '  unlinked-new-test: lib/new.test.js' "$HUM_OUT"
  jq_json '.status'
  [ "$output" = '"fresh"' ]
  jq_json '.reasons'
  [ "$output" = '[]' ]
  jq_json '[.informational[] | [.type, .file]]'
  [ "$output" = '[["unlinked-new-test","lib/new.test.js"],["unlinked-new-test","tests/new.bats"]]' ]
  assert_untouched
}

@test "unlinked-new-test skips annotated files, fixtures directories, dot-directories and node_modules" {
  # an annotated file that is simply not in the links yet is the links source's business, not an unlinked file
  printf '%s\n' '# arch-node: N_ONE type=unit' '@test "annotated" {' '}' > "$FIX/tests/annotated.bats"
  mkdir -p "$FIX/fixtures" "$FIX/.hidden" "$FIX/node_modules/pkg"
  printf '%s\n' "test('x', () => {});" > "$FIX/fixtures/f.test.js"
  printf '%s\n' "test('x', () => {});" > "$FIX/.hidden/h.test.js"
  printf '%s\n' "test('x', () => {});" > "$FIX/node_modules/pkg/p.test.js"
  check_both
  [ "$human_rc" -eq 0 ]
  [ "$json_rc" -eq 0 ]
  jq_json '.informational'
  [ "$output" = '[]' ]
  run grep -c 'informational' "$HUM_OUT"
  [ "$output" = "0" ]
  assert_untouched
}

@test "unlinked-new-test is capped at 20 names and a final entry counts the omitted ones" {
  n=0
  while [ "$n" -lt 22 ]; do
    printf '%s\n' '@test "t" {' '}' > "$FIX/tests/extra$(printf '%02d' "$n").bats"
    n=$((n + 1))
  done
  check_both
  [ "$human_rc" -eq 0 ]
  [ "$json_rc" -eq 0 ]
  jq_json '[.informational[] | select(.type == "unlinked-new-test")] | length'
  [ "$output" = "20" ]
  jq_json '.informational[-1]'
  [ "$output" = '{"type":"unlinked-new-test-omitted","count":2}' ]
  grep -q '(and 2 more unlinked test file(s) not listed)' "$HUM_OUT"
  assert_untouched
}

@test "unlinked-new-test accompanies a stale verdict without changing it" {
  printf '%s\n' '@test "new" {' '}' > "$FIX/tests/new.bats"
  rm -f "$FIX/lib/a.test.js"
  check_both
  [ "$human_rc" -eq 1 ]
  [ "$json_rc" -eq 1 ]
  jq_json '[.reasons[] | .type]'
  [ "$output" = '["test-removed"]' ]
  jq_json '[.informational[] | .file]'
  [ "$output" = '["tests/new.bats"]' ]
  assert_untouched
}

@test "no unlinked-new-test is reported when the links file is missing" {
  rm -f "$LINKS"
  printf '%s\n' '@test "new" {' '}' > "$FIX/tests/new.bats"
  check_both
  [ "$human_rc" -eq 1 ]
  jq_json '.informational'
  [ "$output" = '[]' ]
  assert_untouched
}

# --- 5. JSON form ---------------------------------------------------------------------------------------------------

@test "--json prints exactly one object with status, reasons and informational that parses with jq" {
  rm -f "$FIX/lib/a.test.js"
  check_both
  [ "$json_rc" -eq 1 ]
  [ "$(wc -l < "$JSON_OUT" | tr -d ' ')" = "1" ]
  run jq -e 'type == "object" and (keys | sort) == ["informational","reasons","status"] and (.reasons | type) == "array" and (.informational | type) == "array" and (.reasons | all(has("type")))' "$JSON_OUT"
  [ "$status" -eq 0 ]
  # the verdict and the exit status are the same in both forms
  head -1 "$HUM_OUT" | grep -q '^stale: '
  [ "$human_rc" = "$json_rc" ]
}

# --- 6. read-only ---------------------------------------------------------------------------------------------------

@test "the checker leaves the graph, the test files and the links file byte-identical, whatever the verdict" {
  graph_sum="$(sha "$GRAPH")"
  links_sum="$(sha "$LINKS")"
  sample_sum="$(sha "$FIX/tests/sample.bats")"

  check_both
  [ "$human_rc" -eq 0 ]
  assert_untouched

  printf '%s\n' '// an extra line' >> "$FIX/lib/a.test.js"
  check_both
  [ "$human_rc" -eq 1 ]
  assert_untouched

  [ "$(sha "$GRAPH")" = "$graph_sum" ]
  [ "$(sha "$LINKS")" = "$links_sum" ]
  [ "$(sha "$FIX/tests/sample.bats")" = "$sample_sum" ]
  # and no temporary file or lock was left beside them
  [ "$(find "$FIX" -type f | wc -l | tr -d ' ')" = "4" ]
  [ -z "$(find "$FIX" -type d -name '*.lock*')" ]
}

# --- extras: usage --------------------------------------------------------------------------------------------------

@test "--help prints the usage on stdout and exits 0" {
  run bash "$SCRIPT" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"usage: check-test-links.sh [--root <dir>] [--links <file>] [--json]"* ]]
}

@test "an unknown flag, a positional argument and a flag without a value exit 2" {
  run bash "$SCRIPT" --root "$FIX" --bogus
  [ "$status" -eq 2 ]
  run bash "$SCRIPT" --root "$FIX" stray-argument
  [ "$status" -eq 2 ]
  run bash "$SCRIPT" --root
  [ "$status" -eq 2 ]
  run bash "$SCRIPT" --root "$FIX" --links
  [ "$status" -eq 2 ]
}

@test "a root that does not exist exits 2" {
  run bash "$SCRIPT" --root "$BATS_TEST_TMPDIR/no-such-root"
  [ "$status" -eq 2 ]
  [[ "$output" == *"root is not a readable directory"* ]]
}
