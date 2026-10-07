#!/usr/bin/env bats
#
# End-to-end scenario for the preferred-tools registry (E66_S04_T04).
#
# Drives the real resolve/merge/validate scripts through a temp project. The user layer is
# selected with JENGA_USER_TOOLS_FILE, the project layer with a temp project root, and HOME is
# pointed at a temp dir, so the real ~/.jenga/ and the real project/configs/preferred-tools.json
# are never read or written.
#
# What this proves: the DATA PATH (what an agent gets back from the resolver for a required
# entry, a recommended entry, an override and a suppression) and the WIRING (both agent files
# reference scripts/resolve-tools.sh). What it does not prove: agent behaviour itself. Stopping
# to ask the user on a required entry, or recording a justified deviation, is prose guidance in
# agents/developer.md and agents/tester.md and cannot be exercised by bats.

bats_require_minimum_version 1.5.0
load helpers/assertions

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"

setup() {
  export HOME="$BATS_TEST_TMPDIR/home"
  mkdir -p "$HOME"

  PKG="$BATS_TEST_TMPDIR/pkg"
  mkdir -p "$PKG/scripts" "$PKG/skills/j-tools/assets" "$PKG/skills/j-connect"
  cp "$REPO_ROOT"/scripts/resolve-tools.sh "$REPO_ROOT"/scripts/merge-tools-registry.sh \
    "$REPO_ROOT"/scripts/validate-tools-registry.sh "$REPO_ROOT"/scripts/resolve-root.sh "$PKG/scripts/"
  cp -R "$REPO_ROOT/skills/j-connect/descriptors" "$PKG/skills/j-connect/descriptors"
  RESOLVE="$PKG/scripts/resolve-tools.sh"
  SHIPPED="$PKG/skills/j-tools/assets/shipped-tools.json"

  PROJ="$BATS_TEST_TMPDIR/proj"
  mkdir -p "$PROJ/project/configs"
  printf '{"paths":{"configs":"project/configs"}}\n' > "$PROJ/project/configs/workflow.json"
  PROJECT_FILE="$PROJ/project/configs/preferred-tools.json"
  export JENGA_PROJECT_ROOT="$PROJ"

  USER_FILE="$BATS_TEST_TMPDIR/user-tools.json"
  export JENGA_USER_TOOLS_FILE="$USER_FILE"
  unset JENGA_DESCRIPTORS_DIR
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
    '{registry_version:1, categories:[], suppress:$s, tools:$t}' > "$path"
}

resolve() { run --separate-stderr bash "$RESOLVE" "$@"; }

# tool_field <name> <field>: a field of one resolved entry, from $output (json format).
tool_field() { jq -r --arg n "$1" --arg f "$2" '.tools[] | select(.name == $n) | .[$f]' <<<"$output"; }
tool_count() { jq -r --arg n "$1" '[.tools[] | select(.name == $n)] | length' <<<"$output"; }

# --- scenario: required and recommended entries -------------------------------------------

@test "required entry: resolves with enforcement required for its category" {
  layer_file "$SHIPPED" '[]' "fmt:lint:recommended:shipped default"
  layer_file "$PROJECT_FILE" '[]' "vitest:testing:required:project standard"
  resolve --category testing
  [ "$status" -eq 0 ]
  [ -z "$stderr" ]
  [ "$(tool_field vitest enforcement)" = "required" ]
  [ "$(tool_field vitest category)" = "testing" ]
  [ "$(tool_field vitest layer)" = "project" ]
  # The category filter holds: the lint entry is not returned for a testing query.
  [ "$(tool_count fmt)" = "0" ]
}

@test "recommended entry: resolves as advisory, not required" {
  layer_file "$SHIPPED" '[]' "shellcheck:lint:recommended:static analysis"
  resolve --category lint
  [ "$status" -eq 0 ]
  [ "$(tool_field shellcheck enforcement)" = "recommended" ]
  [ "$(jq -r '[.tools[] | select(.enforcement == "required")] | length' <<<"$output")" = "0" ]
}

@test "required and recommended entries in one category are told apart in text format" {
  layer_file "$SHIPPED" '[]' "bats:testing:required:harness" "pytest:testing:recommended:python"
  resolve --category testing --format text
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -qE $'^testing\tbats\trequired\tshipped\t'
  printf '%s\n' "$output" | grep -qE $'^testing\tpytest\trecommended\tshipped\t'
}

# --- scenario: override and suppress ------------------------------------------------------

@test "override: a project entry replaces the shipped entry of the same name" {
  layer_file "$SHIPPED" '[]' "shellcheck:lint:recommended:shipped advisory"
  layer_file "$PROJECT_FILE" '[]' "shellcheck:lint:required:project makes it binding"
  resolve --category lint
  [ "$status" -eq 0 ]
  [ "$(tool_count shellcheck)" = "1" ]
  [ "$(tool_field shellcheck enforcement)" = "required" ]
  [ "$(tool_field shellcheck layer)" = "project" ]
  [ "$(tool_field shellcheck rationale)" = "project makes it binding" ]
}

@test "override: a user entry replaces shipped, and a project entry replaces the user entry" {
  layer_file "$SHIPPED" '[]' "gh:CI:recommended:shipped"
  layer_file "$USER_FILE" '[]' "gh:CI:required:user"
  resolve --category CI
  [ "$(tool_field gh layer)" = "user" ]
  layer_file "$PROJECT_FILE" '[]' "gh:CI:recommended:project"
  resolve --category CI
  [ "$(tool_count gh)" = "1" ]
  [ "$(tool_field gh layer)" = "project" ]
  [ "$(tool_field gh enforcement)" = "recommended" ]
}

@test "suppress: a project suppress removes the shipped entry" {
  layer_file "$SHIPPED" '[]' "doctl:infra:recommended:droplets" "rclone:infra:recommended:cloud storage"
  layer_file "$PROJECT_FILE" '["doctl"]'
  resolve --category infra
  [ "$status" -eq 0 ]
  [ "$(tool_count doctl)" = "0" ]
  [ "$(tool_count rclone)" = "1" ]
  # suppress is a directive, never part of the output
  [ "$(jq 'has("suppress")' <<<"$output")" = "false" ]
}

@test "suppress: a project suppress also removes a user-layer entry" {
  layer_file "$USER_FILE" '[]' "doctl:infra:required:user"
  layer_file "$PROJECT_FILE" '["doctl"]'
  resolve --category infra
  [ "$(tool_count doctl)" = "0" ]
}

# --- failure handling data path (what the agents are told to react to) ---------------------

@test "absent user and project layers: not an error, shipped entries still resolve" {
  layer_file "$SHIPPED" '[]' "bats:testing:required:harness"
  [ ! -e "$USER_FILE" ]
  [ ! -e "$PROJECT_FILE" ]
  resolve --category testing
  [ "$status" -eq 0 ]
  [ "$(tool_field bats layer)" = "shipped" ]
}

@test "known category with no entries: exit 0 and an empty list, not an error" {
  layer_file "$SHIPPED" '[]' "bats:testing:required:harness"
  resolve --category infra
  [ "$status" -eq 0 ]
  [ "$(jq '.tools | length' <<<"$output")" = "0" ]
}

@test "invalid project layer: exit 4, layer and file named on stderr, nothing on stdout" {
  layer_file "$SHIPPED" '[]' "bats:testing:required:harness"
  printf '{"registry_version":1,"tools":[{"name":"x"}]}\n' > "$PROJECT_FILE"
  resolve --category testing
  [ "$status" -eq 4 ]
  [ -z "$output" ]
  [[ "$stderr" == *project* ]]
  [[ "$stderr" == *"$PROJECT_FILE"* ]]
}

@test "the real user and project files are never involved: HOME is a temp dir" {
  [ "$HOME" = "$BATS_TEST_TMPDIR/home" ]
  [ "$JENGA_USER_TOOLS_FILE" = "$BATS_TEST_TMPDIR/user-tools.json" ]
  [ "$JENGA_PROJECT_ROOT" = "$BATS_TEST_TMPDIR/proj" ]
}

# --- wiring: real shipped file and consumer agents ------------------------------------------

@test "real shipped file: bats is a required testing entry, consistent with test-config.json" {
  run --separate-stderr bash "$REPO_ROOT/scripts/resolve-tools.sh" --category testing
  [ "$status" -eq 0 ]
  [ "$(tool_field bats enforcement)" = "required" ]
  jq -e '.tools[] | select(.tool_name == "bats" and .type == "unit")' "$REPO_ROOT/project/configs/test-config.json" >/dev/null
}

@test "wiring: agents/developer.md references scripts/resolve-tools.sh" {
  grep -q 'scripts/resolve-tools.sh' "$REPO_ROOT/agents/developer.md"
}

@test "wiring: agents/tester.md references scripts/resolve-tools.sh" {
  grep -q 'scripts/resolve-tools.sh' "$REPO_ROOT/agents/tester.md"
}

@test "wiring: both agent files point at the registry doc for the contract" {
  grep -q 'project/documentation/preferred-tools-registry.md' "$REPO_ROOT/agents/developer.md"
  grep -q 'project/documentation/preferred-tools-registry.md' "$REPO_ROOT/agents/tester.md"
}
