#!/usr/bin/env bats
#
# Coverage for scripts/validate-conventions.sh, templates/conventions.json and
# templates/conventions-presets.json (E69_S01_T05).
#
# Contract under test: templates/conventions-schema.json (the machine-readable source) and
# project/documentation/project-conventions.md (the human guide), plus the header comment of the script.
#
# Every fixture is generated at test time into a scratch project under $BATS_TEST_TMPDIR, which bats
# removes after each test. No invalid file exists anywhere in the repository as a standalone data file;
# the only repository files read are the shipped template, the shipped preset catalog and the schema,
# and nothing here reads or writes this repository's own project/configs/ (one test proves that).
#
# Streams: the script writes one verdict line per file (PASS/FAIL <file>) to stdout and one
# "<file>: <message>" line per problem to stderr, so the tests use `run --separate-stderr`.
#
# Exit codes pinned here: 0 every file clean, 1 any file invalid or unreadable, 2 usage error.
# Exit code 3 (python3 missing) is deliberately NOT tested: it is a single `command -v` guard with no
# logic worth pinning.

bats_require_minimum_version 1.5.0
load helpers/assertions

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
VALIDATE="$REPO_ROOT/scripts/validate-conventions.sh"
SCHEMA="$REPO_ROOT/templates/conventions-schema.json"
TEMPLATE="$REPO_ROOT/templates/conventions.json"
PRESETS="$REPO_ROOT/templates/conventions-presets.json"
REAL_CONFIGS="$REPO_ROOT/project/configs"

setup() {
  PROJ="$BATS_TEST_TMPDIR/proj"
  CFG="$PROJ/project/configs"
  mkdir -p "$CFG"
  printf '{"paths":{"configs":"project/configs"}}\n' > "$CFG/workflow.json"
  export JENGA_PROJECT_ROOT="$PROJ"
  unset JENGA_CONVENTIONS_SCHEMA

  F="$CFG/conventions.json"
  P="$CFG/conventions-presets.json"
  REAL_SUM="$(find "$REAL_CONFIGS" -type f -exec cksum {} + | sort | cksum)"
}

teardown() {
  # Nothing may have touched this repo's own configs, and no instance may have appeared there.
  [ "$(find "$REAL_CONFIGS" -type f -exec cksum {} + | sort | cksum)" = "$REAL_SUM" ]
}

validate() { run --separate-stderr bash "$VALIDATE" "$@"; }

# A valid instance covering all 9 categories, with each source kind, written to $F.
write_valid() {
  cat > "$F" <<'JSON'
{
  "conventions_version": 1,
  "categories": {
    "commit-format": {
      "source": "preset", "preset": "conventional-commits",
      "summary": "Conventional Commits",
      "values": { "style": "conventional-commits", "message_regex": "^(feat|fix): .+", "subject_max_length": 72 },
      "strength": "confirm"
    },
    "branching": {
      "source": "detected",
      "summary": "Trunk-based, short-lived branches",
      "values": { "model": "trunk-based", "default_branch": "main" }
    },
    "naming": {
      "source": "detected", "preset": "kebab-files-camel-identifiers",
      "summary": "kebab-case files, camelCase identifiers",
      "values": { "identifier_case": "camelCase", "file_case": "kebab-case" },
      "strength": "advisory"
    },
    "code-comments": {
      "source": "custom",
      "summary": "Comment the why",
      "values": { "policy": "comment-why-not-what", "public_api_docs_required": true }
    },
    "formatting-linting": {
      "source": "custom",
      "summary": "Formatter and linter run by command",
      "values": { "approach": "formatter-and-linter", "format_command": "make fmt", "lint_command": "make lint", "editorconfig": true },
      "strength": "confirm"
    },
    "testing": {
      "source": "preset", "preset": "tests-for-every-change",
      "summary": "A test for every change",
      "values": { "expectation": "tests-for-every-change", "test_dir": "tests" }
    },
    "file-layout": {
      "source": "preset", "preset": "src-and-tests",
      "summary": "src/ plus tests/",
      "values": { "layout": "src-and-tests", "source_dir": "src", "test_dir": "tests" }
    },
    "language-tooling": {
      "source": "custom",
      "summary": "Pinned runtime with a committed lockfile",
      "values": { "version_policy": "pinned-runtime-and-lockfile", "runtime": "node 20", "package_manager": "npm", "lockfile_committed": true }
    },
    "documentation-placement": {
      "source": "custom",
      "summary": "Published docs in docs/",
      "values": { "policy": "published-docs-in-docs-internal-elsewhere", "public_docs_dir": "docs", "internal_docs_dir": "notes" }
    }
  }
}
JSON
}

# mutate <jq-filter>: apply a jq filter to the valid instance in $F, in place.
mutate() {
  write_valid
  jq "$1" "$F" > "$F.new"
  mv "$F.new" "$F"
}

# mutate_presets <jq-filter>: copy the shipped catalog to $P, applying a jq filter.
mutate_presets() {
  jq "$1" "$PRESETS" > "$P"
}

# ================================================================================================================
# Shipped files
# ================================================================================================================

@test "the shipped templates/conventions.json validates and is exactly the generic empty default" {
  validate "$TEMPLATE"
  [ "$status" -eq 0 ]
  assert_output_contains "PASS $TEMPLATE"
  [ -z "$stderr" ]
  [ "$(jq -c . "$TEMPLATE")" = '{"conventions_version":1,"categories":{}}' ]
}

@test "the shipped preset catalog validates in --presets mode" {
  validate --presets "$PRESETS"
  [ "$status" -eq 0 ]
  assert_output_contains "PASS $PRESETS"
  [ -z "$stderr" ]
}

@test "the schema names exactly the 9 v1 categories, each with a values field list, and forbids block" {
  [ "$(jq -r '.categories | keys | length' "$SCHEMA")" -eq 9 ]
  [ "$(jq -r '.categories | keys | sort | join(",")' "$SCHEMA")" = "branching,code-comments,commit-format,documentation-placement,file-layout,formatting-linting,language-tooling,naming,testing" ]
  [ "$(jq '[.categories[] | select((.values | length) > 0)] | length' "$SCHEMA")" -eq 9 ]
  [ "$(jq -r '.strength.allowed | join(",")' "$SCHEMA")" = "advisory,confirm" ]
  [ "$(jq -r '.strength.forbidden | join(",")' "$SCHEMA")" = "block" ]
  [ "$(jq -r '.top_level_keys | join(",")' "$SCHEMA")" = "conventions_version,categories" ]
}

@test "the shipped preset catalog and template carry no path, name or command specific to this repository" {
  run grep -inE 'project/|agents/|jenga|scrum|E[0-9]+_S[0-9]+|\.claude|\.agents|npm test|bats' "$PRESETS" "$TEMPLATE"
  [ "$status" -eq 1 ]
}

# ================================================================================================================
# Valid instances
# ================================================================================================================

@test "a valid instance covering all 9 categories and each source kind validates" {
  write_valid
  [ "$(jq '.categories | length' "$F")" -eq 9 ]
  [ "$(jq -r '[.categories[].source] | unique | join(",")' "$F")" = "custom,detected,preset" ]
  validate "$F"
  [ "$status" -eq 0 ]
  assert_output_contains "PASS $F"
  [ -z "$stderr" ]
}

@test "an empty categories object and a single-category instance validate (absent category means skipped)" {
  printf '{"conventions_version":1,"categories":{}}\n' > "$F"
  validate "$F"
  [ "$status" -eq 0 ]
  mutate '.categories |= {"naming": .naming}'
  validate "$F"
  [ "$status" -eq 0 ]
}

@test "several files in one run each get their own verdict, and the exit code is 1 if any fails" {
  write_valid
  printf '{bad' > "$CFG/other.json"
  validate "$F" "$CFG/other.json"
  [ "$status" -eq 1 ]
  assert_output_contains "PASS $F"
  assert_output_contains "FAIL $CFG/other.json"
}

# ================================================================================================================
# Instance rejections
# ================================================================================================================

@test "malformed JSON is rejected" {
  printf '{"conventions_version": 1, "categories": ' > "$F"
  validate "$F"
  [ "$status" -eq 1 ]
  assert_output_contains "FAIL $F"
  assert_contains "$stderr" "$F: malformed JSON"
}

@test "a non-object top level is rejected" {
  printf '[1, 2]\n' > "$F"
  validate "$F"
  [ "$status" -eq 1 ]
  assert_contains "$stderr" "top level must be a JSON object"
}

@test "a duplicate object key is rejected as malformed JSON rather than silently overriding (pinned judgment call)" {
  printf '{"conventions_version":1,"categories":{"naming":{},"naming":{}}}\n' > "$F"
  validate "$F"
  [ "$status" -eq 1 ]
  assert_contains "$stderr" "malformed JSON: duplicate object key"
}

@test "an unknown top-level key is rejected, naming it" {
  mutate '. + {"extra": 1}'
  validate "$F"
  [ "$status" -eq 1 ]
  assert_contains "$stderr" "unknown top-level key: extra"
}

@test "a wrong or missing conventions_version is rejected" {
  mutate '.conventions_version = 2'
  validate "$F"
  [ "$status" -eq 1 ]
  assert_contains "$stderr" "bad conventions_version"
  mutate '.conventions_version = "1"'
  validate "$F"
  [ "$status" -eq 1 ]
  assert_contains "$stderr" "bad conventions_version"
  mutate 'del(.conventions_version)'
  validate "$F"
  [ "$status" -eq 1 ]
  assert_contains "$stderr" "missing required field: conventions_version"
}

@test "an unknown category id is rejected, naming its JSON path and the allowed ids" {
  mutate '.categories["error-handling"] = .categories.naming'
  validate "$F"
  [ "$status" -eq 1 ]
  assert_contains "$stderr" "unknown category: categories.error-handling"
  assert_contains "$stderr" "commit-format"
}

@test "a category entry that is not an object is rejected" {
  mutate '.categories.naming = "kebab-case"'
  validate "$F"
  [ "$status" -eq 1 ]
  assert_contains "$stderr" "categories.naming must be an object"
}

@test "a wrong-typed field is rejected, naming its path (summary, values and a typed value)" {
  mutate '.categories.naming.summary = 7'
  validate "$F"
  [ "$status" -eq 1 ]
  assert_contains "$stderr" "categories.naming.summary must be a string"
  mutate '.categories.naming.values = "camelCase"'
  validate "$F"
  [ "$status" -eq 1 ]
  assert_contains "$stderr" "categories.naming.values must be an object"
  mutate '.categories["code-comments"].values.public_api_docs_required = "yes"'
  validate "$F"
  [ "$status" -eq 1 ]
  assert_contains "$stderr" "categories.code-comments.values.public_api_docs_required must be a boolean"
  mutate '.categories["commit-format"].values.subject_max_length = "72"'
  validate "$F"
  [ "$status" -eq 1 ]
  assert_contains "$stderr" "categories.commit-format.values.subject_max_length must be an integer"
}

@test "a missing required field is rejected (summary, source, values and a values field)" {
  mutate 'del(.categories.naming.summary)'
  validate "$F"
  [ "$status" -eq 1 ]
  assert_contains "$stderr" "missing required field: categories.naming.summary"
  mutate 'del(.categories.naming.source)'
  validate "$F"
  [ "$status" -eq 1 ]
  assert_contains "$stderr" "missing required field: categories.naming.source"
  mutate 'del(.categories.naming.values)'
  validate "$F"
  [ "$status" -eq 1 ]
  assert_contains "$stderr" "missing required field: categories.naming.values"
  mutate 'del(.categories.naming.values.identifier_case)'
  validate "$F"
  [ "$status" -eq 1 ]
  assert_contains "$stderr" "missing required field: categories.naming.values.identifier_case"
}

@test "a source outside detected, preset and custom is rejected" {
  mutate '.categories.naming.source = "guessed"'
  validate "$F"
  [ "$status" -eq 1 ]
  assert_contains "$stderr" "bad source: categories.naming.source"
}

@test "source preset without a preset id is rejected" {
  mutate 'del(.categories["commit-format"].preset)'
  validate "$F"
  [ "$status" -eq 1 ]
  assert_contains "$stderr" "missing preset: categories.commit-format.preset"
}

@test "source custom with a preset id is rejected" {
  mutate '.categories["code-comments"].preset = "comment-the-why"'
  validate "$F"
  [ "$status" -eq 1 ]
  assert_contains "$stderr" "unexpected preset: categories.code-comments.preset"
}

@test "source detected may carry a preset id or omit it" {
  # both forms are present in the valid fixture (naming carries one, branching does not)
  write_valid
  [ "$(jq '.categories.naming | has("preset")' "$F")" = "true" ]
  [ "$(jq '.categories.branching | has("preset")' "$F")" = "false" ]
  validate "$F"
  [ "$status" -eq 0 ]
}

@test "a malformed preset id is rejected" {
  mutate '.categories["commit-format"].preset = "Conventional Commits"'
  validate "$F"
  [ "$status" -eq 1 ]
  assert_contains "$stderr" "malformed preset id: categories.commit-format.preset"
}

@test "an unknown key inside values is rejected, naming its path" {
  mutate '.categories.naming.values.colour = "red"'
  validate "$F"
  [ "$status" -eq 1 ]
  assert_contains "$stderr" "unknown key in values: categories.naming.values.colour"
}

@test "a key from another category's values is unknown here" {
  mutate '.categories.naming.values.model = "trunk-based"'
  validate "$F"
  [ "$status" -eq 1 ]
  assert_contains "$stderr" "unknown key in values: categories.naming.values.model"
}

@test "an unknown field on a category entry is rejected" {
  mutate '.categories.naming.note = "x"'
  validate "$F"
  [ "$status" -eq 1 ]
  assert_contains "$stderr" "unknown field: categories.naming.note"
}

@test "a multi-line summary is rejected, and so is a multi-line values string" {
  mutate '.categories.naming.summary = "line one\nline two"'
  validate "$F"
  [ "$status" -eq 1 ]
  assert_contains "$stderr" "multi-line value: categories.naming.summary"
  mutate '.categories["formatting-linting"].values.lint_command = "make lint\nrm -rf x"'
  validate "$F"
  [ "$status" -eq 1 ]
  assert_contains "$stderr" "multi-line value: categories.formatting-linting.values.lint_command"
}

@test "an empty or whitespace-only summary is rejected" {
  mutate '.categories.naming.summary = "   "'
  validate "$F"
  [ "$status" -eq 1 ]
  assert_contains "$stderr" "empty value: categories.naming.summary"
}

@test "a block strength is rejected: the message names the JSON path and says block is not allowed for conventions" {
  mutate '.categories.naming.strength = "block"'
  validate "$F"
  [ "$status" -eq 1 ]
  assert_output_contains "FAIL $F"
  assert_contains "$stderr" "categories.naming.strength"
  assert_contains "$stderr" "block"
  assert_contains "$stderr" "not allowed for conventions"
}

@test "a block anywhere under a strength or enforcement key is rejected, at any depth" {
  mutate '.categories.naming.values.enforcement = "block"'
  validate "$F"
  [ "$status" -eq 1 ]
  assert_contains "$stderr" "block strength: categories.naming.values.enforcement"
  mutate '. + {"nested": {"list": [{"strength": "block"}]}}'
  validate "$F"
  [ "$status" -eq 1 ]
  assert_contains "$stderr" "block strength: nested.list[0].strength"
  assert_contains "$stderr" "not allowed for conventions"
}

@test "the word block as an ordinary value is not a strength and is not flagged" {
  mutate '.categories.naming.summary = "block comments are fine"'
  validate "$F"
  [ "$status" -eq 0 ]
}

@test "a strength other than advisory and confirm is rejected, and advisory and confirm are accepted" {
  mutate '.categories.naming.strength = "loud"'
  validate "$F"
  [ "$status" -eq 1 ]
  assert_contains "$stderr" "bad strength: categories.naming.strength"
  mutate '.categories.naming.strength = "confirm"'
  validate "$F"
  [ "$status" -eq 0 ]
}

@test "every problem in a file is reported in one run, not just the first" {
  write_valid
  jq '
    .categories["error-handling"] = {"source":"custom","summary":"x","values":{}}
    | .categories.naming.values.identifier_case = 5
    | del(.categories.branching.summary)
    | .categories["commit-format"].strength = "block"
  ' "$F" > "$F.new"
  mv "$F.new" "$F"
  validate "$F"
  [ "$status" -eq 1 ]
  assert_output_contains "FAIL $F"
  assert_contains "$stderr" "unknown category: categories.error-handling"
  assert_contains "$stderr" "categories.naming.values.identifier_case must be a string"
  assert_contains "$stderr" "missing required field: categories.branching.summary"
  assert_contains "$stderr" "categories.commit-format.strength"
  assert_contains "$stderr" "not allowed for conventions"
  [ "$(printf '%s\n' "$stderr" | grep -c "^$F: ")" -ge 4 ]
}

# ================================================================================================================
# Usage, absent files, environment
# ================================================================================================================

@test "no arguments is a usage error: exit 2 with a usage line" {
  validate
  [ "$status" -eq 2 ]
  assert_contains "$stderr" "usage:"
  [ -z "$output" ]
}

@test "--presets with no file, and an unknown option, are usage errors" {
  validate --presets
  [ "$status" -eq 2 ]
  assert_contains "$stderr" "usage:"
  validate --bogus "$F"
  [ "$status" -eq 2 ]
  assert_contains "$stderr" "unknown option"
}

@test "a missing file exits 1 with a message naming the file, never a silent pass" {
  validate "$CFG/does-not-exist.json"
  [ "$status" -eq 1 ]
  assert_output_contains "FAIL $CFG/does-not-exist.json"
  assert_not_contains "$output" "PASS"
  assert_contains "$stderr" "$CFG/does-not-exist.json: cannot read file"
  validate --presets "$CFG/does-not-exist.json"
  [ "$status" -eq 1 ]
  assert_contains "$stderr" "$CFG/does-not-exist.json: cannot read file"
}

@test "a missing file in a list does not hide the valid files around it" {
  write_valid
  validate "$F" "$CFG/missing.json" "$TEMPLATE"
  [ "$status" -eq 1 ]
  assert_output_contains "PASS $F"
  assert_output_contains "FAIL $CFG/missing.json"
  assert_output_contains "PASS $TEMPLATE"
}

@test "the schema is located relative to the script: a consumer-style layout validates" {
  local pkg="$BATS_TEST_TMPDIR/node_modules/@jenga-ai/agent"
  mkdir -p "$pkg/scripts" "$pkg/templates"
  cp "$VALIDATE" "$pkg/scripts/"
  cp "$SCHEMA" "$TEMPLATE" "$PRESETS" "$pkg/templates/"
  cd "$PROJ"
  run --separate-stderr bash "$pkg/scripts/validate-conventions.sh" "$pkg/templates/conventions.json"
  [ "$status" -eq 0 ]
  run --separate-stderr bash "$pkg/scripts/validate-conventions.sh" --presets "$pkg/templates/conventions-presets.json"
  [ "$status" -eq 0 ]
}

@test "an unreadable or malformed schema exits 1 naming the schema, rather than passing everything" {
  printf '{bad' > "$BATS_TEST_TMPDIR/schema.json"
  JENGA_CONVENTIONS_SCHEMA="$BATS_TEST_TMPDIR/schema.json" validate "$TEMPLATE"
  [ "$status" -eq 1 ]
  assert_contains "$stderr" "$BATS_TEST_TMPDIR/schema.json: malformed JSON"
  JENGA_CONVENTIONS_SCHEMA="$BATS_TEST_TMPDIR/no-schema.json" validate "$TEMPLATE"
  [ "$status" -eq 1 ]
  assert_contains "$stderr" "no-schema.json: cannot read file"
}

@test "the category list comes from the schema, not from the script: a schema with one category changes what is valid" {
  jq '.categories |= {"naming": .naming}' "$SCHEMA" > "$BATS_TEST_TMPDIR/one.json"
  write_valid
  JENGA_CONVENTIONS_SCHEMA="$BATS_TEST_TMPDIR/one.json" validate "$F"
  [ "$status" -eq 1 ]
  assert_contains "$stderr" "unknown category: categories.commit-format"
  mutate '.categories |= {"naming": .naming}'
  JENGA_CONVENTIONS_SCHEMA="$BATS_TEST_TMPDIR/one.json" validate "$F"
  [ "$status" -eq 0 ]
  # and the catalog check requires presets only for the schema's categories
  jq '.categories |= {"naming": .naming}' "$PRESETS" > "$P"
  JENGA_CONVENTIONS_SCHEMA="$BATS_TEST_TMPDIR/one.json" validate --presets "$P"
  [ "$status" -eq 0 ]
  validate --presets "$P"
  [ "$status" -eq 1 ]
  assert_contains "$stderr" "category with no presets: categories.branching"
}

@test "the script carries no quoted category id: the ids live in the schema only" {
  # the nine ids appear in the shipped schema; the script must not carry them as a second copy
  run grep -c -E '"(commit-format|branching|code-comments|formatting-linting|file-layout|language-tooling|documentation-placement)"' "$VALIDATE"
  [ "$output" = "0" ]
}

# ================================================================================================================
# Preset catalog
# ================================================================================================================

@test "catalog: a category with no presets (absent) is rejected, naming the category" {
  mutate_presets 'del(.categories.branching)'
  validate --presets "$P"
  [ "$status" -eq 1 ]
  assert_output_contains "FAIL $P"
  assert_contains "$stderr" "category with no presets: categories.branching"
}

@test "catalog: a category with an empty preset list is rejected, naming the category" {
  mutate_presets '.categories.naming = []'
  validate --presets "$P"
  [ "$status" -eq 1 ]
  assert_contains "$stderr" "category with no presets: categories.naming"
}

@test "catalog: a category with 1 preset is rejected as outside the 2 to 3 range" {
  mutate_presets '.categories.testing |= [.[0]]'
  validate --presets "$P"
  [ "$status" -eq 1 ]
  assert_contains "$stderr" "wrong preset count: categories.testing has 1 preset (need 2 to 3)"
}

@test "catalog: a category with 4 presets is rejected as outside the 2 to 3 range" {
  mutate_presets '.categories.testing |= . + [{"id":"extra-one","label":"Extra","description":"An extra preset.","values":{"expectation":"extra"}}]'
  validate --presets "$P"
  [ "$status" -eq 1 ]
  assert_contains "$stderr" "wrong preset count: categories.testing has 4 presets (need 2 to 3)"
}

@test "catalog: exactly 2 and exactly 3 presets are accepted" {
  mutate_presets '.categories.branching |= .[0:2] | .categories.naming |= .[0:3]'
  validate --presets "$P"
  [ "$status" -eq 0 ]
}

@test "catalog: a duplicate preset id inside a category is rejected, naming the id and both positions" {
  mutate_presets '.categories.branching[1].id = .categories.branching[0].id'
  validate --presets "$P"
  [ "$status" -eq 1 ]
  assert_contains "$stderr" "duplicate preset id: categories.branching[1].id"
  assert_contains "$stderr" "categories.branching[0]"
}

@test "catalog: the same preset id in two different categories is allowed" {
  mutate_presets '.categories.testing[0].id = "shared-id" | .categories["file-layout"][0].id = "shared-id"'
  validate --presets "$P"
  [ "$status" -eq 0 ]
}

@test "catalog: a preset missing id, label, description or values is rejected, naming the field" {
  local field
  for field in id label description values; do
    mutate_presets "del(.categories.naming[0].$field)"
    validate --presets "$P"
    [ "$status" -eq 1 ]
    assert_contains "$stderr" "missing required field: categories.naming[0].$field"
  done
}

@test "catalog: a malformed preset id is rejected" {
  mutate_presets '.categories.naming[0].id = "Not Kebab"'
  validate --presets "$P"
  [ "$status" -eq 1 ]
  assert_contains "$stderr" "malformed preset id: categories.naming[0].id"
}

@test "catalog: preset values that do not validate against the category field list are rejected" {
  mutate_presets '.categories.naming[0].values.colour = "red"'
  validate --presets "$P"
  [ "$status" -eq 1 ]
  assert_contains "$stderr" "unknown key in values: categories.naming[0].values.colour"
  mutate_presets '.categories.naming[0].values.identifier_case = 3'
  validate --presets "$P"
  [ "$status" -eq 1 ]
  assert_contains "$stderr" "categories.naming[0].values.identifier_case must be a string"
  mutate_presets 'del(.categories.naming[0].values.identifier_case)'
  validate --presets "$P"
  [ "$status" -eq 1 ]
  assert_contains "$stderr" "missing required field: categories.naming[0].values.identifier_case"
}

@test "catalog: a preset that sets a block strength is rejected, with the path and the not-allowed message" {
  mutate_presets '.categories.naming[0].strength = "block"'
  validate --presets "$P"
  [ "$status" -eq 1 ]
  assert_contains "$stderr" "categories.naming[0].strength"
  assert_contains "$stderr" "not allowed for conventions"
}

@test "catalog: an unknown category and an unknown top-level key are rejected" {
  mutate_presets '.categories["release"] = .categories.naming | . + {"extra": 1}'
  validate --presets "$P"
  [ "$status" -eq 1 ]
  assert_contains "$stderr" "unknown category: categories.release"
  assert_contains "$stderr" "unknown top-level key: extra"
}

@test "catalog: a wrong presets_version and malformed JSON are rejected" {
  mutate_presets '.presets_version = 2'
  validate --presets "$P"
  [ "$status" -eq 1 ]
  assert_contains "$stderr" "bad presets_version"
  printf '{"presets_version":' > "$P"
  validate --presets "$P"
  [ "$status" -eq 1 ]
  assert_contains "$stderr" "malformed JSON"
}

@test "catalog: several problems in one catalog are all reported" {
  mutate_presets 'del(.categories.branching) | .categories.testing |= [.[0]] | .categories.naming[1].id = .categories.naming[0].id'
  validate --presets "$P"
  [ "$status" -eq 1 ]
  assert_contains "$stderr" "category with no presets: categories.branching"
  assert_contains "$stderr" "wrong preset count: categories.testing"
  assert_contains "$stderr" "duplicate preset id: categories.naming[1].id"
}

@test "an instance is not a valid catalog and a catalog is not a valid instance" {
  validate --presets "$TEMPLATE"
  [ "$status" -eq 1 ]
  validate "$PRESETS"
  [ "$status" -eq 1 ]
  assert_contains "$stderr" "unknown top-level key: presets_version"
}

@test "every shipped preset id is kebab-case, unique within its category, and has a one-line description" {
  [ "$(jq '[.categories[][] | select(.id | test("^[a-z0-9]+(-[a-z0-9]+)*$") | not)] | length' "$PRESETS")" -eq 0 ]
  [ "$(jq '[.categories[] | (map(.id) | length) - (map(.id) | unique | length)] | add' "$PRESETS")" -eq 0 ]
  [ "$(jq '[.categories[][] | select((.description | test("\n")) or (.description | length) == 0)] | length' "$PRESETS")" -eq 0 ]
}

@test "formatting-linting presets mark placeholder commands as placeholders in the description" {
  local n
  n="$(jq '[.categories["formatting-linting"][] | select((.values.format_command // "" | test("^<.*>$")) or (.values.lint_command // "" | test("^<.*>$")))] | length' "$PRESETS")"
  [ "$n" -ge 1 ]
  [ "$(jq '[.categories["formatting-linting"][] | select(((.values.format_command // "") + (.values.lint_command // "")) != "") | select(.description | test("placeholder"))] | length' "$PRESETS")" -eq "$n" ]
  # and no preset anywhere stores a command that is not a bracketed placeholder
  [ "$(jq '[.categories[][].values | to_entries[] | select(.key | test("_command$")) | select(.value | test("^<.*>$") | not)] | length' "$PRESETS")" -eq 0 ]
}

# ================================================================================================================
# Isolation
# ================================================================================================================

@test "the scratch project is under the test's temp dir and this repo's configs hold no conventions instance" {
  case "$JENGA_PROJECT_ROOT" in "$BATS_TEST_TMPDIR"/*) ;; *) return 1 ;; esac
  [ ! -e "$REAL_CONFIGS/conventions.json" ]
  [ ! -e "$REAL_CONFIGS/conventions-presets.json" ]
}
