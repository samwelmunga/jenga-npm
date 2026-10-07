#!/usr/bin/env bats
#
# Coverage for scripts/merge-tools-registry.sh (E66_S01_T04).
#
# Layer files are generated into per-test temp dirs. The descriptor directory is
# a temp dir selected through JENGA_DESCRIPTORS_DIR (inherited by the validator).

bats_require_minimum_version 1.5.0
load helpers/assertions

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
MERGE="$REPO_ROOT/scripts/merge-tools-registry.sh"

setup() {
  export JENGA_DESCRIPTORS_DIR="$BATS_TEST_TMPDIR/descriptors"
  mkdir -p "$JENGA_DESCRIPTORS_DIR"
  SHIPPED="$BATS_TEST_TMPDIR/shipped.json"
  USER_L="$BATS_TEST_TMPDIR/user.json"
  PROJECT="$BATS_TEST_TMPDIR/project.json"
}

# layer_file <path> <suppress-json-array> <tool-spec>...
# Each tool-spec is name:category:enforcement:rationale. Writes a valid registry.
layer_file() {
  local path="$1" suppress="$2" spec tools="[]" n c e r
  shift 2
  for spec in "$@"; do
    IFS=: read -r n c e r <<<"$spec"
    tools="$(jq -c --arg n "$n" --arg c "$c" --arg e "$e" --arg r "$r" \
      '. + [{name:$n,category:$c,enforcement:$e,rationale:$r,alternatives:[],version:"*",install_hint:{text:"t"}}]' <<<"$tools")"
  done
  jq -n --argjson s "$suppress" --argjson t "$tools" \
    '{registry_version:1, suppress:$s, tools:$t}' > "$path"
}

merge() { run --separate-stderr bash "$MERGE" "$@"; }

# tool_field <name> <field>: a field of one merged entry, from $output.
tool_field() { jq -r --arg n "$1" --arg f "$2" '.tools[] | select(.name == $n) | .[$f]' <<<"$output"; }
tool_count() { jq -r --arg n "$1" '[.tools[] | select(.name == $n)] | length' <<<"$output"; }

@test "precedence: project beats user beats shipped, and the winning entry is whole" {
  layer_file "$SHIPPED" '[]' "a:lint:recommended:from-shipped"
  layer_file "$USER_L" '[]' "a:testing:required:from-user"
  layer_file "$PROJECT" '[]' "a:infra:recommended:from-project"
  merge "$SHIPPED" "$USER_L" "$PROJECT"
  [ "$status" -eq 0 ]
  [ "$(tool_count a)" = "1" ]
  [ "$(tool_field a rationale)" = "from-project" ]
  [ "$(tool_field a category)" = "infra" ]
  [ "$(tool_field a layer)" = "project" ]
}

@test "precedence: user beats shipped when there is no project entry" {
  layer_file "$SHIPPED" '[]' "a:lint:recommended:from-shipped"
  layer_file "$USER_L" '[]' "a:testing:required:from-user"
  merge "$SHIPPED" "$USER_L" ""
  [ "$status" -eq 0 ]
  [ "$(tool_count a)" = "1" ]
  [ "$(tool_field a rationale)" = "from-user" ]
  [ "$(tool_field a enforcement)" = "required" ]
  [ "$(tool_field a layer)" = "user" ]
}

@test "every output entry records the layer it came from; distinct names all survive" {
  layer_file "$SHIPPED" '[]' "s-only:lint:recommended:s"
  layer_file "$USER_L" '[]' "u-only:testing:recommended:u"
  layer_file "$PROJECT" '[]' "p-only:infra:required:p"
  merge "$SHIPPED" "$USER_L" "$PROJECT"
  [ "$status" -eq 0 ]
  [ "$(tool_field s-only layer)" = "shipped" ]
  [ "$(tool_field u-only layer)" = "user" ]
  [ "$(tool_field p-only layer)" = "project" ]
  [ "$(jq '.tools | length' <<<"$output")" = "3" ]
  [ "$(jq '.registry_version' <<<"$output")" = "1" ]
}

@test "suppression: a user layer removes a shipped entry" {
  layer_file "$SHIPPED" '[]' "keep:lint:recommended:k" "drop:lint:recommended:d"
  layer_file "$USER_L" '["drop"]'
  merge "$SHIPPED" "$USER_L" ""
  [ "$status" -eq 0 ]
  [ "$(tool_count drop)" = "0" ]
  [ "$(tool_count keep)" = "1" ]
}

@test "suppression: a project layer removes entries from both user and shipped" {
  layer_file "$SHIPPED" '[]' "drop:lint:recommended:s"
  layer_file "$USER_L" '[]' "drop2:lint:recommended:u"
  layer_file "$PROJECT" '["drop","drop2"]'
  merge "$SHIPPED" "$USER_L" "$PROJECT"
  [ "$status" -eq 0 ]
  [ "$(jq '.tools | length' <<<"$output")" = "0" ]
}

@test "suppression does not remove an entry in a higher layer" {
  layer_file "$SHIPPED" '[]' "a:lint:recommended:from-shipped"
  layer_file "$USER_L" '["a"]'
  layer_file "$PROJECT" '[]' "a:testing:required:from-project"
  merge "$SHIPPED" "$USER_L" "$PROJECT"
  [ "$status" -eq 0 ]
  [ "$(tool_count a)" = "1" ]
  [ "$(tool_field a layer)" = "project" ]
  [ "$(tool_field a rationale)" = "from-project" ]
}

@test "a layer cannot suppress its own entries" {
  layer_file "$SHIPPED" '[]' "a:lint:recommended:from-shipped"
  layer_file "$USER_L" '["a"]' "a:testing:required:from-user"
  merge "$SHIPPED" "$USER_L" ""
  [ "$status" -eq 0 ]
  [ "$(tool_count a)" = "1" ]
  [ "$(tool_field a layer)" = "user" ]
  [ "$(tool_field a rationale)" = "from-user" ]
}

@test "a layer cannot suppress an entry it defines even when no lower layer has it" {
  layer_file "$PROJECT" '["solo"]' "solo:lint:required:p"
  merge "" "" "$PROJECT"
  [ "$status" -eq 0 ]
  [ "$(tool_count solo)" = "1" ]
}

@test "absent layers: empty-string and non-existent paths are skipped" {
  layer_file "$SHIPPED" '[]' "a:lint:recommended:s"
  merge "$SHIPPED" "" "$BATS_TEST_TMPDIR/no-such-project-file.json"
  [ "$status" -eq 0 ]
  [ "$(tool_count a)" = "1" ]
  [ "$(tool_field a layer)" = "shipped" ]
}

@test "absent layers: all three absent yields an empty merged document" {
  merge "" "" ""
  [ "$status" -eq 0 ]
  [ "$(jq -c '.tools' <<<"$output")" = "[]" ]
  [ "$(jq -c '.categories' <<<"$output")" = "[]" ]
}

@test "invalid layer: aborts with exit 4, names the file, prints nothing to stdout" {
  layer_file "$SHIPPED" '[]' "a:lint:recommended:s"
  printf '{"registry_version":1,"tools":[{"name":"broken"}]}\n' > "$USER_L"
  merge "$SHIPPED" "$USER_L" ""
  [ "$status" -eq 4 ]
  [ -z "$output" ]
  assert_contains "$stderr" "invalid user layer: $USER_L"
  assert_contains "$stderr" "missing field: category"
}

@test "invalid layer: malformed JSON in the shipped layer is never silently dropped" {
  printf 'not json' > "$SHIPPED"
  layer_file "$PROJECT" '[]' "a:lint:recommended:p"
  merge "$SHIPPED" "" "$PROJECT"
  [ "$status" -eq 4 ]
  [ -z "$output" ]
  assert_contains "$stderr" "invalid shipped layer: $SHIPPED"
}

@test "categories: merged output is the union of the layers' extension lists" {
  layer_file "$SHIPPED" '[]'
  layer_file "$USER_L" '[]'
  jq '.categories = ["db","net"]' "$SHIPPED" > "$SHIPPED.n" && mv "$SHIPPED.n" "$SHIPPED"
  jq '.categories = ["net","queue"]' "$USER_L" > "$USER_L.n" && mv "$USER_L.n" "$USER_L"
  merge "$SHIPPED" "$USER_L" ""
  [ "$status" -eq 0 ]
  [ "$(jq -c '.categories' <<<"$output")" = '["db","net","queue"]' ]
}

@test "output is deterministic and sorted by category then name" {
  layer_file "$SHIPPED" '[]' "z:lint:recommended:z" "a:lint:recommended:a" "m:infra:recommended:m"
  merge "$SHIPPED" "" ""
  [ "$status" -eq 0 ]
  [ "$(jq -r '[.tools[].name] | join(",")' <<<"$output")" = "m,a,z" ]
}

@test "wrong argument count is a usage error (exit 2)" {
  run bash "$MERGE" "$SHIPPED" "$USER_L"
  [ "$status" -eq 2 ]
  assert_output_contains "usage:"
}
