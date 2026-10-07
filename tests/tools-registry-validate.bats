#!/usr/bin/env bats
#
# Coverage for scripts/validate-tools-registry.sh (E66_S01_T04).
#
# Registry files are generated into per-test temp dirs; the descriptor directory
# is a temp dir selected through JENGA_DESCRIPTORS_DIR, so nothing here depends
# on or writes into skills/j-connect/descriptors/.

bats_require_minimum_version 1.5.0
load helpers/assertions

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
VALIDATE="$REPO_ROOT/scripts/validate-tools-registry.sh"

setup() {
  export JENGA_DESCRIPTORS_DIR="$BATS_TEST_TMPDIR/descriptors"
  mkdir -p "$JENGA_DESCRIPTORS_DIR"
  printf '{"id":"fakeservice"}\n' > "$JENGA_DESCRIPTORS_DIR/fakeservice.json"
  F="$BATS_TEST_TMPDIR/registry.json"
}

# A fully valid file, written to $F.
write_valid() {
  cat > "$F" <<'JSON'
{
  "registry_version": 1,
  "categories": ["db"],
  "suppress": ["old-tool"],
  "tools": [
    {
      "name": "fake",
      "category": "CI",
      "enforcement": "required",
      "rationale": "One authenticated CLI for the service.",
      "alternatives": [{ "name": "curl", "why_not": "hand-rolled auth" }],
      "version": ">=1.5 <3",
      "install_hint": { "descriptor": "fakeservice", "text": "brew install fake" }
    },
    {
      "name": "pg",
      "category": "db",
      "enforcement": "recommended",
      "rationale": "Extended category declared in this file.",
      "alternatives": [],
      "version": "*",
      "install_hint": { "text": "no descriptor, free text only" }
    }
  ]
}
JSON
}

# Rewrites $F by applying a jq filter to the valid file.
mutate() {
  write_valid
  jq "$1" "$F" > "$F.new" && mv "$F.new" "$F"
}

@test "a valid file exits 0 with no output" {
  write_valid
  run bash "$VALIDATE" "$F"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "an empty tools list is valid" {
  printf '{"registry_version":1,"tools":[]}\n' > "$F"
  run bash "$VALIDATE" "$F"
  [ "$status" -eq 0 ]
}

@test "version constraints in the documented grammar are accepted" {
  local v
  for v in '*' '1' '1.5' '1.5.0' '>=1.5' '<=2' '>3' '<4.0' '=2.1.0' '^20' '~3.4.1' '>=18 <22'; do
    mutate ".tools[0].version = \"$v\""
    run bash "$VALIDATE" "$F"
    [ "$status" -eq 0 ] || { echo "version '$v' rejected: $output" >&2; return 1; }
  done
}

@test "malformed JSON exits 1 with a malformed JSON message" {
  printf '{ "registry_version": 1, "tools": [' > "$F"
  run bash "$VALIDATE" "$F"
  [ "$status" -eq 1 ]
  assert_output_contains "malformed JSON"
}

@test "a non-object top level exits 1" {
  printf '[]\n' > "$F"
  run bash "$VALIDATE" "$F"
  [ "$status" -eq 1 ]
  assert_output_contains "top level must be a JSON object"
}

@test "a missing field exits 1 and names the field and the tool" {
  mutate 'del(.tools[0].rationale)'
  run bash "$VALIDATE" "$F"
  [ "$status" -eq 1 ]
  assert_output_contains "tools[0] (fake): missing field: rationale"
}

@test "a missing top-level tools field exits 1" {
  printf '{"registry_version":1}\n' > "$F"
  run bash "$VALIDATE" "$F"
  [ "$status" -eq 1 ]
  assert_output_contains "missing field: tools"
}

@test "a wrong registry_version exits 1" {
  mutate '.registry_version = 2'
  run bash "$VALIDATE" "$F"
  [ "$status" -eq 1 ]
  assert_output_contains "registry_version must be 1"
}

@test "an unknown category exits 1 and names it" {
  mutate '.tools[0].category = "frontend"'
  run bash "$VALIDATE" "$F"
  [ "$status" -eq 1 ]
  assert_output_contains 'unknown category "frontend"'
}

@test "a category extended by the same file is accepted, an undeclared one is not" {
  mutate '.categories = [] | .tools[1].category = "db"'
  run bash "$VALIDATE" "$F"
  [ "$status" -eq 1 ]
  assert_output_contains 'unknown category "db"'
}

@test "an extension category duplicating a base category is rejected case-insensitively" {
  mutate '.categories = ["ci"]'
  run bash "$VALIDATE" "$F"
  [ "$status" -eq 1 ]
  assert_output_contains "duplicates a base category"
}

@test "a bad enforcement value exits 1 and names it" {
  mutate '.tools[0].enforcement = "mandatory"'
  run bash "$VALIDATE" "$F"
  [ "$status" -eq 1 ]
  assert_output_contains 'bad enforcement value "mandatory"'
}

@test "a malformed version constraint exits 1" {
  local v
  for v in 'v1.2' '1.2.3.4' 'latest' '>= 1' '1 || 2' ''; do
    mutate ".tools[0].version = \"$v\""
    run bash "$VALIDATE" "$F"
    [ "$status" -eq 1 ] || { echo "version '$v' accepted" >&2; return 1; }
    assert_output_contains "malformed version constraint"
  done
}

@test "an install_hint.descriptor that names no descriptor file exits 1" {
  mutate '.tools[0].install_hint.descriptor = "no-such-service"'
  run bash "$VALIDATE" "$F"
  [ "$status" -eq 1 ]
  assert_output_contains 'install_hint.descriptor "no-such-service" names no file under skills/j-connect/descriptors/'
}

@test "an install_hint with neither descriptor nor text exits 1" {
  mutate '.tools[0].install_hint = {}'
  run bash "$VALIDATE" "$F"
  [ "$status" -eq 1 ]
  assert_output_contains "install_hint needs a descriptor and/or text"
}

@test "a text-only install_hint (the no-descriptor fallback) is valid" {
  mutate '.tools[0].install_hint = {"text": "download from the vendor site"}'
  run bash "$VALIDATE" "$F"
  [ "$status" -eq 0 ]
}

@test "a duplicate tool name within one file exits 1" {
  mutate '.tools[1].name = "fake"'
  run bash "$VALIDATE" "$F"
  [ "$status" -eq 1 ]
  assert_output_contains 'duplicate tool name "fake"'
}

@test "every failure is reported in a single run, not only the first" {
  mutate '.tools[0].category = "frontend" | .tools[0].enforcement = "maybe" | .tools[0].version = "v1" | del(.tools[0].rationale) | .tools[0].install_hint.descriptor = "nope" | .tools[1].name = "fake"'
  run bash "$VALIDATE" "$F"
  [ "$status" -eq 1 ]
  assert_output_contains "unknown category"
  assert_output_contains "bad enforcement value"
  assert_output_contains "malformed version constraint"
  assert_output_contains "missing field: rationale"
  assert_output_contains "names no file under"
  assert_output_contains "duplicate tool name"
}

@test "no arguments is a usage error (exit 2)" {
  run bash "$VALIDATE"
  [ "$status" -eq 2 ]
  assert_output_contains "usage:"
}

@test "a non-existent file is a usage error (exit 2)" {
  run bash "$VALIDATE" "$BATS_TEST_TMPDIR/does-not-exist.json"
  [ "$status" -eq 2 ]
  assert_output_contains "cannot read file"
}

@test "a missing jq exits 3 with a clear message, not a parse failure" {
  write_valid
  local stub="$BATS_TEST_TMPDIR/nojq-bin" tool
  mkdir -p "$stub"
  for tool in dirname cat sed sort find; do
    ln -s "$(command -v "$tool")" "$stub/$tool"
  done
  PATH="$stub" run /bin/bash "$VALIDATE" "$F"
  [ "$status" -eq 3 ]
  assert_output_contains "jq is required"
}
