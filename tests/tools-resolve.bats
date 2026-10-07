#!/usr/bin/env bats
#
# Coverage for scripts/resolve-tools.sh (E66_S02_T03).
#
# Most tests run against a throwaway copy of the package ($PKG) whose shipped file is a
# controlled fixture, so they do not depend on the curated defaults. A few run against the
# real repo scripts and the real shipped file. Nothing here reads or writes the real HOME or
# the real project configs: the user layer is always selected through JENGA_USER_TOOLS_FILE
# and the project layer through a temp project root.

bats_require_minimum_version 1.5.0
load helpers/assertions

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"

setup() {
  # Package copy: scripts the resolver needs, descriptors for the validator, a fixture shipped file.
  PKG="$BATS_TEST_TMPDIR/pkg"
  mkdir -p "$PKG/scripts" "$PKG/skills/j-tools/assets" "$PKG/skills/j-connect"
  cp "$REPO_ROOT"/scripts/resolve-tools.sh "$REPO_ROOT"/scripts/merge-tools-registry.sh \
    "$REPO_ROOT"/scripts/validate-tools-registry.sh "$REPO_ROOT"/scripts/resolve-root.sh "$PKG/scripts/"
  cp -R "$REPO_ROOT/skills/j-connect/descriptors" "$PKG/skills/j-connect/descriptors"
  RESOLVE="$PKG/scripts/resolve-tools.sh"
  SHIPPED="$PKG/skills/j-tools/assets/shipped-tools.json"

  # Temp project with a working-file registry, selected via JENGA_PROJECT_ROOT.
  PROJ="$BATS_TEST_TMPDIR/proj"
  mkdir -p "$PROJ/project/configs"
  printf '{"paths":{"configs":"project/configs"}}\n' > "$PROJ/project/configs/workflow.json"
  PROJECT_FILE="$PROJ/project/configs/preferred-tools.json"
  export JENGA_PROJECT_ROOT="$PROJ"

  USER_FILE="$BATS_TEST_TMPDIR/user-tools.json"
  export JENGA_USER_TOOLS_FILE="$USER_FILE"
  unset JENGA_DESCRIPTORS_DIR
}

# layer_file <path> <suppress-json-array> <categories-json-array> <tool-spec>...
# Each tool-spec is name:category:enforcement:rationale. Writes a valid registry.
layer_file() {
  local path="$1" suppress="$2" cats="$3" spec tools="[]" n c e r
  shift 3
  for spec in "$@"; do
    IFS=: read -r n c e r <<<"$spec"
    tools="$(jq -c --arg n "$n" --arg c "$c" --arg e "$e" --arg r "$r" \
      '. + [{name:$n,category:$c,enforcement:$e,rationale:$r,alternatives:[],version:"*",install_hint:{text:"t"}}]' <<<"$tools")"
  done
  jq -n --argjson s "$suppress" --argjson k "$cats" --argjson t "$tools" \
    '{registry_version:1, categories:$k, suppress:$s, tools:$t}' > "$path"
}

resolve() { run --separate-stderr bash "$RESOLVE" "$@"; }

# tool_field <name> <field>: a field of one resolved entry, from $output (json format).
tool_field() { jq -r --arg n "$1" --arg f "$2" '.tools[] | select(.name == $n) | .[$f]' <<<"$output"; }
tool_count() { jq -r --arg n "$1" '[.tools[] | select(.name == $n)] | length' <<<"$output"; }

# --- shipped only -------------------------------------------------------------

@test "shipped only: returns the shipped entries, each marked layer shipped" {
  layer_file "$SHIPPED" '[]' '[]' "a:lint:recommended:ra" "b:runtime:required:rb"
  resolve
  [ "$status" -eq 0 ]
  [ "$(jq -r '.tools | length' <<<"$output")" = "2" ]
  [ "$(jq -r '.registry_version' <<<"$output")" = "1" ]
  [ "$(tool_field a layer)" = "shipped" ]
  [ "$(tool_field b layer)" = "shipped" ]
  [ -z "$stderr" ]
}

@test "shipped only, real repo: the real shipped file resolves and every entry is layer shipped" {
  run --separate-stderr bash "$REPO_ROOT/scripts/resolve-tools.sh"
  [ "$status" -eq 0 ]
  [ -z "$stderr" ]
  expected="$(jq '.tools | length' "$REPO_ROOT/skills/j-tools/assets/shipped-tools.json")"
  [ "$expected" -gt 0 ]
  [ "$(jq '.tools | length' <<<"$output")" = "$expected" ]
  [ "$(jq '[.tools[] | select(.layer != "shipped")] | length' <<<"$output")" = "0" ]
}

@test "the real shipped file still passes the validator" {
  run --separate-stderr bash "$REPO_ROOT/scripts/validate-tools-registry.sh" "$REPO_ROOT/skills/j-tools/assets/shipped-tools.json"
  [ "$status" -eq 0 ]
}

# --- all three layers ---------------------------------------------------------

@test "all three layers: precedence, layer values and suppression" {
  layer_file "$SHIPPED" '[]' '[]' "a:lint:recommended:from-shipped" "gone:lint:recommended:g" "s-only:runtime:recommended:s"
  layer_file "$USER_FILE" '[]' '[]' "a:testing:required:from-user" "u-only:testing:recommended:u"
  layer_file "$PROJECT_FILE" '["gone"]' '[]' "a:infra:recommended:from-project" "p-only:CI:required:p"
  resolve
  [ "$status" -eq 0 ]
  [ "$(tool_count a)" = "1" ]
  [ "$(tool_field a layer)" = "project" ]
  [ "$(tool_field a rationale)" = "from-project" ]
  [ "$(tool_field u-only layer)" = "user" ]
  [ "$(tool_field s-only layer)" = "shipped" ]
  [ "$(tool_field p-only layer)" = "project" ]
  [ "$(tool_count gone)" = "0" ]
  [ "$(jq '.tools | length' <<<"$output")" = "4" ]
}

@test "user and shipped only: user entry wins and is marked user" {
  layer_file "$SHIPPED" '[]' '[]' "a:lint:recommended:from-shipped"
  layer_file "$USER_FILE" '[]' '[]' "a:lint:required:from-user"
  resolve
  [ "$status" -eq 0 ]
  [ "$(tool_field a layer)" = "user" ]
  [ "$(tool_field a enforcement)" = "required" ]
}

@test "project layer is found from the working directory when JENGA_PROJECT_ROOT is unset" {
  layer_file "$SHIPPED" '[]' '[]' "a:lint:recommended:s"
  layer_file "$PROJECT_FILE" '[]' '[]' "p-only:CI:required:p"
  unset JENGA_PROJECT_ROOT
  cd "$PROJ"
  resolve
  [ "$status" -eq 0 ]
  [ "$(tool_field p-only layer)" = "project" ]
}

@test "project layer follows a relocated configs path, not a hardcoded project/ literal" {
  layer_file "$SHIPPED" '[]' '[]' "a:lint:recommended:s"
  mkdir -p "$PROJ/custom/cfg"
  printf '{"paths":{"configs":"custom/cfg"}}\n' > "$PROJ/project/configs/workflow.json"
  layer_file "$PROJ/custom/cfg/preferred-tools.json" '[]' '[]' "moved:CI:recommended:m"
  layer_file "$PROJECT_FILE" '[]' '[]' "stale:CI:recommended:old-location"
  resolve
  [ "$status" -eq 0 ]
  [ "$(tool_field moved layer)" = "project" ]
  [ "$(tool_count stale)" = "0" ]
}

# --- category filter ----------------------------------------------------------

@test "--category filters the entries and keeps their layer" {
  layer_file "$SHIPPED" '[]' '[]' "a:lint:recommended:a" "b:runtime:required:b"
  layer_file "$USER_FILE" '[]' '[]' "c:lint:recommended:c"
  resolve --category lint
  [ "$status" -eq 0 ]
  [ "$(jq -r '[.tools[].name] | sort | join(",")' <<<"$output")" = "a,c" ]
  [ "$(tool_field c layer)" = "user" ]
}

@test "--category=<name> form works and a known category with no entries yields an empty list" {
  layer_file "$SHIPPED" '[]' '[]' "a:lint:recommended:a"
  resolve --category=infra
  [ "$status" -eq 0 ]
  [ "$(jq '.tools | length' <<<"$output")" = "0" ]
}

@test "unknown category exits 2 and lists the valid categories" {
  layer_file "$SHIPPED" '[]' '[]' "a:lint:recommended:a"
  resolve --category nonsense
  [ "$status" -eq 2 ]
  [ -z "$output" ]
  assert_contains "$stderr" "nonsense"
  assert_contains "$stderr" "valid categories"
  assert_contains "$stderr" "runtime, testing, lint, CI, infra"
}

@test "a category declared by a layer is valid and is listed in the unknown-category message" {
  layer_file "$SHIPPED" '[]' '[]' "a:lint:recommended:a"
  layer_file "$USER_FILE" '[]' '["docs"]' "d:docs:recommended:d"
  resolve --category docs
  [ "$status" -eq 0 ]
  [ "$(jq -r '.tools[0].name' <<<"$output")" = "d" ]
  resolve --category other
  [ "$status" -eq 2 ]
  assert_contains "$stderr" "docs"
}

@test "category match is case-sensitive: ci is not CI" {
  layer_file "$SHIPPED" '[]' '[]' "a:CI:recommended:a"
  resolve --category ci
  [ "$status" -eq 2 ]
  resolve --category CI
  [ "$status" -eq 0 ]
}

# --- output formats -----------------------------------------------------------

@test "--format text prints one tab-separated line per entry: category name enforcement layer version rationale" {
  layer_file "$SHIPPED" '[]' '[]' "a:lint:recommended:why-a"
  layer_file "$USER_FILE" '[]' '[]' "b:lint:required:why-b"
  resolve --format text
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | wc -l | tr -d ' ')" = "2" ]
  first="$(printf '%s\n' "$output" | sed -n 1p)"
  [ "$first" = "$(printf 'lint\ta\trecommended\tshipped\t*\twhy-a')" ]
  second="$(printf '%s\n' "$output" | sed -n 2p)"
  [ "$second" = "$(printf 'lint\tb\trequired\tuser\t*\twhy-b')" ]
}

@test "json output carries registry_version, categories and tools, but no suppress" {
  layer_file "$SHIPPED" '[]' '[]' "a:lint:recommended:a"
  layer_file "$USER_FILE" '["zzz"]' '["docs"]' "d:docs:recommended:d"
  resolve --format json
  [ "$status" -eq 0 ]
  [ "$(jq -c 'keys' <<<"$output")" = '["categories","registry_version","tools"]' ]
  [ "$(jq -c '.categories' <<<"$output")" = '["docs"]' ]
}

@test "unknown --format, missing option values and stray arguments exit 2" {
  layer_file "$SHIPPED" '[]' '[]' "a:lint:recommended:a"
  resolve --format yaml
  [ "$status" -eq 2 ]
  resolve --format
  [ "$status" -eq 2 ]
  resolve --category
  [ "$status" -eq 2 ]
  resolve --category ""
  [ "$status" -eq 2 ]
  resolve stray
  [ "$status" -eq 2 ]
}

# --- absent layers ------------------------------------------------------------

@test "absent user and project files are skipped silently" {
  layer_file "$SHIPPED" '[]' '[]' "a:lint:recommended:a"
  [ ! -e "$USER_FILE" ]
  [ ! -e "$PROJECT_FILE" ]
  resolve
  [ "$status" -eq 0 ]
  [ -z "$stderr" ]
  [ "$(jq '.tools | length' <<<"$output")" = "1" ]
}

@test "only a project layer present: it is merged over the shipped layer without a user file" {
  layer_file "$SHIPPED" '[]' '[]' "a:lint:recommended:a"
  layer_file "$PROJECT_FILE" '[]' '[]' "p:CI:recommended:p"
  resolve
  [ "$status" -eq 0 ]
  [ -z "$stderr" ]
  [ "$(jq '.tools | length' <<<"$output")" = "2" ]
}

# --- invalid layers -----------------------------------------------------------

@test "invalid user layer: exit 4, file named on stderr, nothing on stdout" {
  layer_file "$SHIPPED" '[]' '[]' "a:lint:recommended:a"
  printf '{"registry_version": 2, "tools": []}\n' > "$USER_FILE"
  resolve
  [ "$status" -eq 4 ]
  [ -z "$output" ]
  assert_contains "$stderr" "$USER_FILE"
  assert_contains "$stderr" "user"
}

@test "invalid project layer: exit 4 and file named, never silently dropped" {
  layer_file "$SHIPPED" '[]' '[]' "a:lint:recommended:a"
  printf 'not json at all\n' > "$PROJECT_FILE"
  resolve
  [ "$status" -eq 4 ]
  [ -z "$output" ]
  assert_contains "$stderr" "$PROJECT_FILE"
  assert_contains "$stderr" "project"
}

@test "invalid shipped layer: exit 4 and file named" {
  printf '{"registry_version": 1}\n' > "$SHIPPED"
  resolve
  [ "$status" -eq 4 ]
  assert_contains "$stderr" "$SHIPPED"
}

@test "an invalid layer is an error even when --category is given" {
  layer_file "$SHIPPED" '[]' '[]' "a:lint:recommended:a"
  printf '{}\n' > "$USER_FILE"
  resolve --category lint
  [ "$status" -eq 4 ]
}

@test "unresolvable project configs path (JENGA_PROJECT_ROOT without a registry) exits 5" {
  layer_file "$SHIPPED" '[]' '[]' "a:lint:recommended:a"
  export JENGA_PROJECT_ROOT="$BATS_TEST_TMPDIR/does-not-exist"
  resolve
  [ "$status" -eq 5 ]
  [ -z "$output" ]
}

# --- package-root layout ------------------------------------------------------

@test "package root: finds the shipped file under a simulated node_modules/@jenga-ai/agent/ layout" {
  NM="$BATS_TEST_TMPDIR/consumer/node_modules/@jenga-ai/agent"
  mkdir -p "$(dirname "$NM")"
  mv "$PKG" "$NM"
  layer_file "$NM/skills/j-tools/assets/shipped-tools.json" '[]' '[]' "only-in-installed-copy:runtime:required:marker"
  # Run from the consumer project root, not from the package, as a real consumer would.
  cd "$BATS_TEST_TMPDIR/consumer"
  run --separate-stderr bash "$NM/scripts/resolve-tools.sh"
  [ "$status" -eq 0 ]
  [ -z "$stderr" ]
  [ "$(jq -r '.tools[0].name' <<<"$output")" = "only-in-installed-copy" ]
  [ "$(jq -r '.tools[0].layer' <<<"$output")" = "shipped" ]
  [ "$(jq '.tools | length' <<<"$output")" = "1" ]
}

@test "package root: result does not depend on the caller's working directory" {
  layer_file "$SHIPPED" '[]' '[]' "a:lint:recommended:a"
  cd /
  resolve
  [ "$status" -eq 0 ]
  [ "$(tool_field a layer)" = "shipped" ]
}

@test "package root: resolver also runs through a symlink-free relative invocation from the package" {
  layer_file "$SHIPPED" '[]' '[]' "a:lint:recommended:a"
  cd "$PKG"
  run --separate-stderr bash scripts/resolve-tools.sh
  [ "$status" -eq 0 ]
  [ "$(tool_field a layer)" = "shipped" ]
}

# --- portability --------------------------------------------------------------

@test "runs under /bin/bash (macOS bash 3.2)" {
  [ -x /bin/bash ] || skip "no /bin/bash"
  layer_file "$SHIPPED" '[]' '[]' "a:lint:recommended:a"
  layer_file "$USER_FILE" '[]' '[]' "b:lint:recommended:b"
  run --separate-stderr /bin/bash "$RESOLVE" --category lint
  [ "$status" -eq 0 ]
  [ "$(jq '.tools | length' <<<"$output")" = "2" ]
}
