#!/usr/bin/env bats
# Coverage for scripts/validate-test-links.sh (E83_S02_T01): the validator and schema source of truth for the derived
# test-to-architecture links file (project/knowledge-graph/test-links.json). The rules and their order are documented in the
# script's own header comment; the decisions behind them are D2/D4/D6 of project/documentation/test-architecture-linking-spike.md.
#
# Every fixture is built under $BATS_TEST_TMPDIR. Nothing here reads this repository's real graph or links file.
#
# Cases: a valid file; one case per rule (schema_version, hash-block, links, field-missing, field-type, type, file-path,
# unhashed-file, duplicate, orphan-hash, dangling-node); rule order; --graph passing and failing; exit 2 for unparseable JSON,
# a missing file, a non-object top level, bad usage and a bad graph; the resolved default path; no file written; header docs.

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
SCRIPT="$REPO_ROOT/scripts/validate-test-links.sh"

HASH_A="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
HASH_B="bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"

setup() {
  FIX="$BATS_TEST_TMPDIR/fix"
  mkdir -p "$FIX"
  cat > "$FIX/ok.json" <<EOF
{
  "schema_version": 1,
  "generated_from": {
    "graph_sha256": "$HASH_A",
    "tests": {
      "project/app/api/parsers/y.test.js": "$HASH_B",
      "tests/x.bats": "$HASH_A"
    }
  },
  "links": [
    {"node_id": "E08_S05", "test_id": "project/app/api/parsers/y.test.js", "type": "unit",
     "name": "project/app/api/parsers/y.test.js", "file": "project/app/api/parsers/y.test.js", "line": 1},
    {"node_id": "E20", "test_id": "tests/x.bats::first title", "type": "integration",
     "name": "first title", "file": "tests/x.bats", "line": 10},
    {"node_id": "E20_S09", "test_id": "tests/x.bats::first title", "type": "unit",
     "name": "first title", "file": "tests/x.bats", "line": 10}
  ]
}
EOF
  cat > "$FIX/graph.json" <<'EOF'
{"nodes": [{"id": "E08_S05", "type": "story"}, {"id": "E20", "type": "epic"}, {"id": "E20_S09", "type": "story"}], "edges": []}
EOF
}

# mutate <jq filter>: write $FIX/m.json as ok.json with the filter applied.
mutate() {
  jq -c "$1" "$FIX/ok.json" > "$FIX/m.json"
}

# --- conforming files ----------------------------------------------------------------------------------------------

@test "a valid file exits 0 and prints nothing" {
  run bash "$SCRIPT" "$FIX/ok.json"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "an empty links array with an empty hash map is valid" {
  mutate '.links = [] | .generated_from.tests = {}'
  run bash "$SCRIPT" "$FIX/m.json"
  [ "$status" -eq 0 ]
}

@test "graph_sha256 may be the literal absent" {
  mutate '.generated_from.graph_sha256 = "absent"'
  run bash "$SCRIPT" "$FIX/m.json"
  [ "$status" -eq 0 ]
}

@test "unknown extra keys are tolerated" {
  mutate '.extra = 1 | .links[0].note = "x" | .generated_from.more = true'
  run bash "$SCRIPT" "$FIX/m.json"
  [ "$status" -eq 0 ]
}

# --- one case per rule (exit 1, one line, the rule named) ----------------------------------------------------------

@test "schema_version missing is rule schema_version" {
  mutate 'del(.schema_version)'
  run bash "$SCRIPT" "$FIX/m.json"
  [ "$status" -eq 1 ]
  [ "${#lines[@]}" -eq 1 ]
  [[ "$output" == *"(rule schema_version)"* ]]
}

@test "schema_version 2 is rule schema_version" {
  mutate '.schema_version = 2'
  run bash "$SCRIPT" "$FIX/m.json"
  [ "$status" -eq 1 ]
  [[ "$output" == *"(rule schema_version)"* ]]
}

@test "schema_version as a string is rule schema_version" {
  mutate '.schema_version = "1"'
  run bash "$SCRIPT" "$FIX/m.json"
  [ "$status" -eq 1 ]
  [[ "$output" == *"(rule schema_version)"* ]]
}

@test "generated_from missing is rule hash-block" {
  mutate 'del(.generated_from)'
  run bash "$SCRIPT" "$FIX/m.json"
  [ "$status" -eq 1 ]
  [[ "$output" == *"generated_from"* ]]
  [[ "$output" == *"(rule hash-block)"* ]]
}

@test "an empty graph_sha256 is rule hash-block" {
  mutate '.generated_from.graph_sha256 = ""'
  run bash "$SCRIPT" "$FIX/m.json"
  [ "$status" -eq 1 ]
  [[ "$output" == *"graph_sha256"* ]]
  [[ "$output" == *"(rule hash-block)"* ]]
}

@test "an uppercase graph_sha256 is rule hash-block" {
  mutate '.generated_from.graph_sha256 = ("A" * 64)'
  run bash "$SCRIPT" "$FIX/m.json"
  [ "$status" -eq 1 ]
  [[ "$output" == *"(rule hash-block)"* ]]
}

@test "a missing graph_sha256 is rule hash-block" {
  mutate 'del(.generated_from.graph_sha256)'
  run bash "$SCRIPT" "$FIX/m.json"
  [ "$status" -eq 1 ]
  [[ "$output" == *"(rule hash-block)"* ]]
}

@test "a short test hash is rule hash-block and names the file" {
  mutate '.generated_from.tests["tests/x.bats"] = "abc123"'
  run bash "$SCRIPT" "$FIX/m.json"
  [ "$status" -eq 1 ]
  [[ "$output" == *"tests/x.bats"* ]]
  [[ "$output" == *"(rule hash-block)"* ]]
}

@test "generated_from.tests that is not an object is rule hash-block" {
  mutate '.generated_from.tests = ["tests/x.bats"]'
  run bash "$SCRIPT" "$FIX/m.json"
  [ "$status" -eq 1 ]
  [[ "$output" == *"(rule hash-block)"* ]]
}

@test "links that is not an array is rule links" {
  mutate '.links = {"a": 1}'
  run bash "$SCRIPT" "$FIX/m.json"
  [ "$status" -eq 1 ]
  [[ "$output" == *"(rule links)"* ]]
}

@test "a missing node_id names the link index and the field" {
  mutate 'del(.links[1].node_id)'
  run bash "$SCRIPT" "$FIX/m.json"
  [ "$status" -eq 1 ]
  [ "$output" = "links[1].node_id missing (rule field-missing)" ]
}

@test "each required link field is checked for presence" {
  local f
  for f in node_id test_id type name file line; do
    mutate "del(.links[2].$f)"
    run bash "$SCRIPT" "$FIX/m.json"
    [ "$status" -eq 1 ]
    [[ "$output" == "links[2].$f missing (rule field-missing)" ]]
  done
}

@test "an empty node_id is rule field-type" {
  mutate '.links[0].node_id = ""'
  run bash "$SCRIPT" "$FIX/m.json"
  [ "$status" -eq 1 ]
  [[ "$output" == *"links[0].node_id"* ]]
  [[ "$output" == *"(rule field-type)"* ]]
}

@test "a numeric node_id is rule field-type" {
  mutate '.links[0].node_id = 5'
  run bash "$SCRIPT" "$FIX/m.json"
  [ "$status" -eq 1 ]
  [[ "$output" == *"(rule field-type)"* ]]
}

@test "a non-string name is rule field-type" {
  mutate '.links[0].name = 7'
  run bash "$SCRIPT" "$FIX/m.json"
  [ "$status" -eq 1 ]
  [[ "$output" == *"links[0].name"* ]]
  [[ "$output" == *"(rule field-type)"* ]]
}

@test "a line of 0 is rule field-type" {
  mutate '.links[0].line = 0'
  run bash "$SCRIPT" "$FIX/m.json"
  [ "$status" -eq 1 ]
  [[ "$output" == *"links[0].line"* ]]
  [[ "$output" == *"(rule field-type)"* ]]
}

@test "a fractional line is rule field-type" {
  mutate '.links[0].line = 1.5'
  run bash "$SCRIPT" "$FIX/m.json"
  [ "$status" -eq 1 ]
  [[ "$output" == *"(rule field-type)"* ]]
}

@test "a string line is rule field-type" {
  mutate '.links[0].line = "3"'
  run bash "$SCRIPT" "$FIX/m.json"
  [ "$status" -eq 1 ]
  [[ "$output" == *"(rule field-type)"* ]]
}

@test "a link that is not an object is rule field-type" {
  mutate '.links[1] = "oops"'
  run bash "$SCRIPT" "$FIX/m.json"
  [ "$status" -eq 1 ]
  [[ "$output" == *"links[1]"* ]]
  [[ "$output" == *"(rule field-type)"* ]]
}

@test "a type outside the vocabulary is rule type" {
  mutate '.links[0].type = "smoke"'
  run bash "$SCRIPT" "$FIX/m.json"
  [ "$status" -eq 1 ]
  [[ "$output" == *"links[0].type"* ]]
  [[ "$output" == *"(rule type)"* ]]
}

@test "every vocabulary value is accepted as a type" {
  local t
  for t in unit integration e2e sast vulnerability performance coverage unknown; do
    mutate ".links[0].type = \"$t\""
    run bash "$SCRIPT" "$FIX/m.json"
    [ "$status" -eq 0 ]
  done
}

@test "a non-string type is rule field-type" {
  mutate '.links[0].type = 3'
  run bash "$SCRIPT" "$FIX/m.json"
  [ "$status" -eq 1 ]
  [[ "$output" == *"(rule field-type)"* ]]
}

@test "a file with a leading ./ is rule file-path" {
  mutate '.links[1].file = "./tests/x.bats"'
  run bash "$SCRIPT" "$FIX/m.json"
  [ "$status" -eq 1 ]
  [[ "$output" == *"links[1].file"* ]]
  [[ "$output" == *"(rule file-path)"* ]]
}

@test "an absolute file is rule file-path" {
  mutate '.links[1].file = "/tests/x.bats"'
  run bash "$SCRIPT" "$FIX/m.json"
  [ "$status" -eq 1 ]
  [[ "$output" == *"(rule file-path)"* ]]
}

@test "a file with a .. segment is rule file-path" {
  mutate '.links[1].file = "tests/../x.bats"'
  run bash "$SCRIPT" "$FIX/m.json"
  [ "$status" -eq 1 ]
  [[ "$output" == *"(rule file-path)"* ]]
}

@test "a file with a backslash is rule file-path" {
  mutate '.links[1].file = "tests\\x.bats"'
  run bash "$SCRIPT" "$FIX/m.json"
  [ "$status" -eq 1 ]
  [[ "$output" == *"(rule file-path)"* ]]
}

@test "a file with an empty segment is rule file-path" {
  mutate '.links[1].file = "tests//x.bats"'
  run bash "$SCRIPT" "$FIX/m.json"
  [ "$status" -eq 1 ]
  [[ "$output" == *"(rule file-path)"* ]]
}

@test "a link file that is not a key of generated_from.tests is rule unhashed-file" {
  mutate '.links[1].file = "tests/other.bats"'
  run bash "$SCRIPT" "$FIX/m.json"
  [ "$status" -eq 1 ]
  [[ "$output" == *"tests/other.bats"* ]]
  [[ "$output" == *"(rule unhashed-file)"* ]]
}

@test "two links with the same node_id and test_id are rule duplicate" {
  mutate '.links += [.links[1]]'
  run bash "$SCRIPT" "$FIX/m.json"
  [ "$status" -eq 1 ]
  [ "${#lines[@]}" -eq 1 ]
  [[ "$output" == "links[3] duplicates links[1]"* ]]
  [[ "$output" == *"(rule duplicate)"* ]]
}

@test "the same test_id under a different node_id is not a duplicate" {
  # ok.json already holds E20 and E20_S09 on one test_id.
  run bash "$SCRIPT" "$FIX/ok.json"
  [ "$status" -eq 0 ]
}

@test "the same node_id with a different test_id is not a duplicate" {
  mutate '.links += [(.links[1] | .test_id = "tests/x.bats::second title" | .name = "second title" | .line = 20)]'
  run bash "$SCRIPT" "$FIX/m.json"
  [ "$status" -eq 0 ]
}

@test "a hashed file that no link uses is rule orphan-hash" {
  mutate '.generated_from.tests["tests/unused.bats"] = "'"$HASH_A"'"'
  run bash "$SCRIPT" "$FIX/m.json"
  [ "$status" -eq 1 ]
  [[ "$output" == *"tests/unused.bats"* ]]
  [[ "$output" == *"(rule orphan-hash)"* ]]
}

# --- rule order ----------------------------------------------------------------------------------------------------

@test "schema_version is reported before a later violation" {
  mutate '.schema_version = 9 | del(.links[0].node_id)'
  run bash "$SCRIPT" "$FIX/m.json"
  [ "$status" -eq 1 ]
  [[ "$output" == *"(rule schema_version)"* ]]
}

@test "the lowest-index link violation is reported first" {
  mutate 'del(.links[2].node_id) | .links[0].line = 0'
  run bash "$SCRIPT" "$FIX/m.json"
  [ "$status" -eq 1 ]
  [[ "$output" == *"links[0].line"* ]]
}

@test "a field violation is reported before a duplicate" {
  mutate '.links += [.links[1]] | .links[0].type = "smoke"'
  run bash "$SCRIPT" "$FIX/m.json"
  [ "$status" -eq 1 ]
  [[ "$output" == *"(rule type)"* ]]
}

@test "a duplicate is reported before an orphan hash" {
  mutate '.links += [.links[1]] | .generated_from.tests["tests/unused.bats"] = "'"$HASH_A"'"'
  run bash "$SCRIPT" "$FIX/m.json"
  [ "$status" -eq 1 ]
  [[ "$output" == *"(rule duplicate)"* ]]
}

# --- --graph -------------------------------------------------------------------------------------------------------

@test "--graph passes when every node id exists" {
  run bash "$SCRIPT" --graph "$FIX/graph.json" "$FIX/ok.json"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "--graph=<file> is accepted and the links file may come first" {
  run bash "$SCRIPT" "$FIX/ok.json" --graph="$FIX/graph.json"
  [ "$status" -eq 0 ]
}

@test "--graph fails with rule dangling-node when a node id is absent" {
  jq -c '.nodes |= map(select(.id != "E20"))' "$FIX/graph.json" > "$FIX/graph-missing.json"
  run bash "$SCRIPT" --graph "$FIX/graph-missing.json" "$FIX/ok.json"
  [ "$status" -eq 1 ]
  [ "${#lines[@]}" -eq 1 ]
  [[ "$output" == *"links[1].node_id \"E20\""* ]]
  [[ "$output" == *"(rule dangling-node; 1 dangling link(s))"* ]]
}

@test "--graph reports the first dangling link and the total count" {
  echo '{"nodes":[{"id":"E08_S05"}]}' > "$FIX/graph-one.json"
  run bash "$SCRIPT" --graph "$FIX/graph-one.json" "$FIX/ok.json"
  [ "$status" -eq 1 ]
  [[ "$output" == *"links[1].node_id"* ]]
  [[ "$output" == *"2 dangling link(s)"* ]]
}

@test "without --graph node ids are not checked" {
  mutate '.links[0].node_id = "no-such-node"'
  run bash "$SCRIPT" "$FIX/m.json"
  [ "$status" -eq 0 ]
}

@test "--graph does not mask an earlier rule violation" {
  mutate '.links[0].line = 0'
  run bash "$SCRIPT" --graph "$FIX/graph.json" "$FIX/m.json"
  [ "$status" -eq 1 ]
  [[ "$output" == *"(rule field-type)"* ]]
}

@test "a graph with nodes of any source counts: ids are matched regardless of source" {
  echo '{"nodes":[{"id":"E08_S05","source":"board"},{"id":"E20","source":"human"},{"id":"E20_S09","source":"ast"}]}' > "$FIX/graph-src.json"
  run bash "$SCRIPT" --graph "$FIX/graph-src.json" "$FIX/ok.json"
  [ "$status" -eq 0 ]
}

@test "an unreadable --graph file is exit 2" {
  run bash "$SCRIPT" --graph "$FIX/no-such-graph.json" "$FIX/ok.json"
  [ "$status" -eq 2 ]
}

@test "a --graph file that is not JSON is exit 2" {
  echo '{not json' > "$FIX/graph-bad.json"
  run bash "$SCRIPT" --graph "$FIX/graph-bad.json" "$FIX/ok.json"
  [ "$status" -eq 2 ]
}

@test "a --graph file with no nodes array is exit 2" {
  echo '{"edges":[]}' > "$FIX/graph-nonodes.json"
  run bash "$SCRIPT" --graph "$FIX/graph-nonodes.json" "$FIX/ok.json"
  [ "$status" -eq 2 ]
}

# --- exit 2: usage and unreadable or unparseable input -------------------------------------------------------------

@test "unparseable JSON is exit 2" {
  echo '{"schema_version": 1,' > "$FIX/bad.json"
  run bash "$SCRIPT" "$FIX/bad.json"
  [ "$status" -eq 2 ]
}

@test "a missing links file is exit 2" {
  run bash "$SCRIPT" "$FIX/does-not-exist.json"
  [ "$status" -eq 2 ]
}

@test "a top level that is not an object is exit 2" {
  echo '[]' > "$FIX/array.json"
  run bash "$SCRIPT" "$FIX/array.json"
  [ "$status" -eq 2 ]
}

@test "an empty file is exit 2 (not valid JSON, not an object)" {
  : > "$FIX/empty.json"
  run bash "$SCRIPT" "$FIX/empty.json"
  [ "$status" -eq 2 ]
}

@test "an unknown option is a usage error, exit 2" {
  run bash "$SCRIPT" --bogus "$FIX/ok.json"
  [ "$status" -eq 2 ]
}

@test "--graph without a value is a usage error, exit 2" {
  run bash "$SCRIPT" "$FIX/ok.json" --graph
  [ "$status" -eq 2 ]
}

@test "two links files is a usage error, exit 2" {
  run bash "$SCRIPT" "$FIX/ok.json" "$FIX/ok.json"
  [ "$status" -eq 2 ]
}

# --- the resolved default links file -------------------------------------------------------------------------------

@test "with no argument the default links file under the resolved root is checked" {
  local root="$BATS_TEST_TMPDIR/root"
  mkdir -p "$root/project/configs" "$root/project/knowledge-graph"
  echo '{}' > "$root/project/configs/workflow.json"
  cp "$FIX/ok.json" "$root/project/knowledge-graph/test-links.json"
  JENGA_PROJECT_ROOT="$root" run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  jq '.schema_version = 5' "$FIX/ok.json" > "$root/project/knowledge-graph/test-links.json"
  JENGA_PROJECT_ROOT="$root" run bash "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"(rule schema_version)"* ]]
}

@test "with no argument and no default file the script exits 2" {
  local root="$BATS_TEST_TMPDIR/root-empty"
  mkdir -p "$root/project/configs"
  echo '{}' > "$root/project/configs/workflow.json"
  JENGA_PROJECT_ROOT="$root" run bash "$SCRIPT"
  [ "$status" -eq 2 ]
}

# --- writes nothing ------------------------------------------------------------------------------------------------

@test "the script creates no file in the fixture directory on success, violation or error" {
  mutate 'del(.links[0].node_id)'
  local before after
  before="$(cd "$FIX" && find . -print | LC_ALL=C sort)"
  cd "$FIX"
  run bash "$SCRIPT" ok.json
  run bash "$SCRIPT" --graph graph.json ok.json
  run bash "$SCRIPT" m.json
  run bash "$SCRIPT" missing.json
  run bash "$SCRIPT" --bogus
  after="$(cd "$FIX" && find . -print | LC_ALL=C sort)"
  [ "$before" = "$after" ]
}

@test "the script leaves its inputs byte-identical" {
  local before after
  before="$(cat "$FIX/ok.json" "$FIX/graph.json" | shasum -a 256)"
  run bash "$SCRIPT" --graph "$FIX/graph.json" "$FIX/ok.json"
  after="$(cat "$FIX/ok.json" "$FIX/graph.json" | shasum -a 256)"
  [ "$before" = "$after" ]
}

# --- the header is the schema's source of truth --------------------------------------------------------------------

@test "the header documents every exit code" {
  local c
  for c in 0 1 2; do
    grep -qE "^#   $c   " "$SCRIPT"
  done
}

@test "the header documents every rule, one line per rule" {
  local r
  for r in schema_version hash-block links field-missing field-type type file-path unhashed-file duplicate orphan-hash dangling-node; do
    grep -qE "^#   $r +" "$SCRIPT"
  done
}

@test "the header type vocabulary matches the discover-tests.sh vocabulary" {
  local vocab="unit | integration | e2e | sast | vulnerability | performance | coverage | unknown" flat
  grep -qF "$vocab" "$SCRIPT"
  # discover-tests.sh wraps the list over two header lines; flatten the header before comparing.
  flat="$(head -n 40 "$REPO_ROOT/skills/j-test/scripts/discover-tests.sh" | sed 's/^#//' | tr '\n' ' ' | tr -s ' ')"
  [[ "$flat" == *"$vocab"* ]]
}

@test "the header states the usage line" {
  grep -qF "validate-test-links.sh [--graph <graph.json>] [<links-file>]" "$SCRIPT"
}
