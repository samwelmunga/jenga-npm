#!/usr/bin/env bats
#
# Coverage for templates/test-scope-map.json (E72_S01_T05): the shipped default changed-file to test-glob table.
#
# Contract under test: the task spec and the file's own `_comment`. Four things matter:
#   1. the file is well-formed (valid JSON, integer map_version, a rules array of {source, tests});
#   2. it documents its own additive (all-matching-rules) semantics, so the future scope mapper cannot read it
#      as first-match-wins;
#   3. it stays project-agnostic: templates/ ships downstream through /j-mirror-public, so no path specific to
#      this repository may appear anywhere in it (comment included);
#   4. it actually ships: it lives under a directory package.json `files` lists, .publicignore does not block it,
#      and no per-project copy is scaffolded under project/configs/.
#
# Read-only: nothing here writes outside $BATS_TEST_TMPDIR.

bats_require_minimum_version 1.5.0
load helpers/assertions

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd -P)"
MAP="$REPO_ROOT/templates/test-scope-map.json"
MATCH="$REPO_ROOT/scripts/check-publicignore-match.sh"

@test "the map file exists and parses as JSON" {
  [ -f "$MAP" ]
  run jq -e . "$MAP"
  [ "$status" -eq 0 ]
}

@test "map_version is an integer" {
  run jq -e '(.map_version | type) == "number" and (.map_version == (.map_version | floor))' "$MAP"
  [ "$status" -eq 0 ]
}

@test "map_version is 1" {
  run jq -r '.map_version' "$MAP"
  [ "$status" -eq 0 ]
  [ "$output" = "1" ]
}

@test "rules is a non-empty array" {
  run jq -e '(.rules | type) == "array" and (.rules | length) > 0' "$MAP"
  [ "$status" -eq 0 ]
}

@test "every rule has a non-empty source string" {
  run jq -e '[.rules[] | (.source | type) == "string" and (.source | length) > 0] | all' "$MAP"
  [ "$status" -eq 0 ]
}

@test "every rule has a non-empty tests array of non-empty strings" {
  run jq -e '[.rules[] | (.tests | type) == "array" and (.tests | length) > 0
              and ([.tests[] | type == "string" and length > 0] | all)] | all' "$MAP"
  [ "$status" -eq 0 ]
}

@test "every source and test entry is a glob (contains a wildcard)" {
  run jq -e '[.rules[] | .source, .tests[] | test("[*?]")] | all' "$MAP"
  [ "$status" -eq 0 ]
}

@test "rules carry no keys beyond source and tests" {
  run jq -e '[.rules[] | keys == ["source", "tests"]] | all' "$MAP"
  [ "$status" -eq 0 ]
}

@test "_comment documents the additive all-matching-rules semantics" {
  run jq -r '._comment' "$MAP"
  [ "$status" -eq 0 ]
  assert_output_contains "ALL matching rules"
  assert_output_contains "additive"
  assert_output_contains "first-match-wins"
}

@test "_comment tells projects to override via commit_scope_map_file, not by editing the shipped copy" {
  run jq -r '._comment' "$MAP"
  [ "$status" -eq 0 ]
  assert_output_contains "commit_scope_map_file"
  assert_output_contains "not by editing"
}

@test "no entry contains a project-specific path (leak check)" {
  # Case-insensitive grep over the whole file, comment included, so a leak cannot hide in metadata.
  local token
  for token in 'skills/j-' 'project/board' 'project/configs' '\.agents' '\.claude' 'jenga'; do
    run grep -inE -- "$token" "$MAP"
    if [ "$status" -eq 0 ]; then
      echo "project-specific token '$token' found in templates/test-scope-map.json:" >&2
      echo "$output" >&2
      false
    fi
    [ "$status" -eq 1 ]
  done
}

@test "no rule targets this repository's own layout (hooks, board, skills, mirrors)" {
  run jq -e '[.rules[] | .source, .tests[]
              | test("^(skills|hooks|agents|project|\\.agents|\\.claude)/")] | any | not' "$MAP"
  [ "$status" -eq 0 ]
}

@test "the file ships: package.json files lists templates/ as a directory" {
  run jq -e '.files | index("templates/") != null' "$REPO_ROOT/package.json"
  [ "$status" -eq 0 ]
}

@test "the file ships: .publicignore does not block it" {
  [ -f "$MATCH" ] || skip "scripts/check-publicignore-match.sh is not present in this tree"
  command -v rsync >/dev/null 2>&1 || skip "rsync unavailable"
  run bash -c "cd '$REPO_ROOT' && bash '$MATCH' templates/test-scope-map.json"
  [ "$status" -eq 0 ]
  assert_starts_with "$output" "PUBLIC"
  assert_output_contains "templates/test-scope-map.json"
}

@test "no per-project copy is scaffolded at project/configs/test-scope-map.json" {
  [ ! -e "$REPO_ROOT/project/configs/test-scope-map.json" ]
}
