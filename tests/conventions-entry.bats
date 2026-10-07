#!/usr/bin/env bats
#
# Coverage for skills/j-conventions/scripts/conventions-entry.sh (E69_S04_T03), the deterministic backend of the
# j.conventions wizard.
#
# Contract under test: the script's own header comment (`conventions-entry.sh --help`): read subcommands (path, show,
# categories, detect, presets), per-input validation (check), draft handling (draft-init/set/skip/show/diff) and the
# validated atomic `commit` with rollback.
#
# Every test builds its own scratch project under $BATS_TEST_TMPDIR (a project/configs/workflow.json, its own
# conventions.json and checklists.json) and aims the script at it with JENGA_PROJECT_ROOT. TMPDIR is redirected to a
# scratch directory too, so draft files land (and are inspected) there. Nothing here writes this repository's own
# project/configs/; setup and teardown prove it by checksum.
#
# Failures are forced without touching shipped files: JENGA_CONVENTIONS_GENERATOR swaps in a stub generator (exit 1, or
# writing an invalid registry), and the lock is held by creating the lock directory with-lock.sh uses.
#
# Streams: JSON results go to stdout, refusals and diagnostics to stderr; tests that care use `run --separate-stderr`.

bats_require_minimum_version 1.5.0
load helpers/assertions

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
ENTRY="$REPO_ROOT/skills/j-conventions/scripts/conventions-entry.sh"
DETECT="$REPO_ROOT/skills/j-conventions/scripts/detect-conventions.sh"
VALIDATE_CONV="$REPO_ROOT/scripts/validate-conventions.sh"
VALIDATE_REG="$REPO_ROOT/scripts/validate-checklists.sh"
SCHEMA="$REPO_ROOT/templates/conventions-schema.json"
PRESETS="$REPO_ROOT/templates/conventions-presets.json"
REAL_CONFIGS="$REPO_ROOT/project/configs"

setup() {
  REAL_SUM="$(find "$REAL_CONFIGS" -type f -exec cksum {} + | sort | cksum)"
  unset JENGA_CONVENTIONS_SCHEMA JENGA_CONVENTIONS_PRESETS JENGA_CONVENTIONS_GENERATOR JENGA_CONVENTIONS_CHECKLIST_MAP
  unset JENGA_CHECKLISTS_DEFAULT_FILE JENGA_CHECKLISTS_FILE WITH_LOCK_TIMEOUT_SECONDS WITH_LOCK_POLL_SECONDS WITH_LOCK_STALE_SECONDS
  SCRATCH_TMP="$BATS_TEST_TMPDIR/tmp"
  mkdir -p "$SCRATCH_TMP"
  export TMPDIR="$SCRATCH_TMP"
  PROJ="$BATS_TEST_TMPDIR/proj"
  CFG="$PROJ/project/configs"
  CONV="$CFG/conventions.json"
  REG="$CFG/checklists.json"
  mkdir -p "$CFG"
  printf '{}\n' > "$CFG/workflow.json"
  export JENGA_PROJECT_ROOT="$PROJ"
}

teardown() {
  [ "$(find "$REAL_CONFIGS" -type f -exec cksum {} + | sort | cksum)" = "$REAL_SUM" ]
}

# --- helpers ---------------------------------------------------------------------------------------------------

entry() { run --separate-stderr bash "$ENTRY" "$@"; }

# new_draft: create a draft with draft-init and set DRAFT.
new_draft() {
  DRAFT="$(bash "$ENTRY" draft-init 2>/dev/null)"
  [ -f "$DRAFT" ]
}

# preset_id <category> [<index>]: id of a shipped preset.
preset_id() {
  jq -r --arg c "$1" --argjson i "${2:-0}" '.categories[$c][$i].id' "$PRESETS"
}

# set_preset <category> [<preset index>]: draft-set from a shipped preset (must succeed).
set_preset() {
  bash "$ENTRY" draft-set "$1" --draft "$DRAFT" --source preset --preset "$(preset_id "$1" "${2:-0}")" >/dev/null
}

# set_custom <category> <summary> <field=value>: draft-set from custom text (must succeed).
set_custom() {
  bash "$ENTRY" draft-set "$1" --draft "$DRAFT" --source custom --summary "$2" --value "$3" >/dev/null
}

# sum <file>: checksum of a file's bytes.
sum() { cksum < "$1"; }

# tree_sum: checksum of every file under the scratch project (names and contents).
tree_sum() { (cd "$PROJ" && find . -type f -exec cksum {} + | sort | cksum); }

# put_instance <jq filter over the categories object>: write a valid recorded conventions.json.
put_instance() {
  jq -n "{conventions_version: 1, categories: ($1)}" > "$CONV"
}

# RECORDED: a small valid instance (naming from a custom answer, testing from a custom answer).
recorded_two() {
  put_instance '{
    "naming": {source: "custom", summary: "camelCase identifiers", values: {identifier_case: "camelCase"}},
    "testing": {source: "custom", summary: "unit tests for new logic", values: {expectation: "unit tests"}}
  }'
}

# stub_generator_fail: a generator that always fails; sets JENGA_CONVENTIONS_GENERATOR.
stub_generator_fail() {
  printf '#!/bin/bash\necho "stub generator: boom" >&2\nexit 1\n' > "$BATS_TEST_TMPDIR/gen-fail.sh"
  export JENGA_CONVENTIONS_GENERATOR="$BATS_TEST_TMPDIR/gen-fail.sh"
}

# stub_generator_bad_registry: a generator that exits 0 but leaves an invalid registry beside the conventions file.
stub_generator_bad_registry() {
  cat > "$BATS_TEST_TMPDIR/gen-bad.sh" <<'EOF'
#!/bin/bash
# usage: gen-bad.sh --conventions <file>
printf '{"checklist_version": 1, "items": "not-an-array"}\n' > "$(dirname "$2")/checklists.json"
echo "stub generator: wrote an invalid registry"
EOF
  export JENGA_CONVENTIONS_GENERATOR="$BATS_TEST_TMPDIR/gen-bad.sh"
}

# mkrepo: turn the scratch project into a git repository whose last 10 commits are Conventional Commits.
mkrepo() {
  git -C "$PROJ" init -q -b main
  git -C "$PROJ" config user.name "Fixture"
  git -C "$PROJ" config user.email "fixture@example.invalid"
  git -C "$PROJ" config commit.gpgsign false
  local i=1
  while [ "$i" -le 10 ]; do
    git -C "$PROJ" commit -q --allow-empty -m "feat(core): add thing $i"
    i=$((i + 1))
  done
}

# --- path / show -----------------------------------------------------------------------------------------------

@test "path prints the project instance path, whether or not the file exists" {
  entry path
  [ "$status" -eq 0 ]
  [ "$output" = "$CONV" ]
  [ ! -e "$CONV" ]
}

@test "show with no instance prints the empty skeleton and exits 0" {
  entry show
  [ "$status" -eq 0 ]
  [ "$output" = '{"conventions_version":1,"categories":{}}' ]
}

@test "show with an instance prints it unchanged" {
  recorded_two
  entry show
  [ "$status" -eq 0 ]
  [ "$output" = "$(cat "$CONV")" ]
}

@test "show --category prints one entry, exits 1 when the category is absent or there is no instance" {
  recorded_two
  entry show --category naming
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r '.summary')" = "camelCase identifiers" ]
  entry show --category branching
  [ "$status" -eq 1 ]
  rm -f "$CONV"
  entry show --category naming
  [ "$status" -eq 1 ]
}

@test "show refuses an instance that is not a JSON object (exit 4)" {
  printf 'not json\n' > "$CONV"
  entry show
  [ "$status" -eq 4 ]
}

@test "show and path write nothing" {
  recorded_two
  before="$(tree_sum)"
  entry show
  entry path
  [ "$(tree_sum)" = "$before" ]
}

# --- categories / detect / presets -----------------------------------------------------------------------------

@test "categories lists the 9 schema ids in schema order with their labels" {
  entry categories
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | wc -l | tr -d ' ')" = "9" ]
  [ "$(printf '%s\n' "$output" | cut -f1)" = "$(jq -r '.categories | keys_unsorted[]' "$SCHEMA")" ]
  assert_output_contains "commit-format	Commit format"
}

@test "categories --format json carries the field list and the commit-format scope note" {
  entry categories --format json
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq 'length')" = "9" ]
  [ "$(printf '%s' "$output" | jq -r '.[0].id')" = "commit-format" ]
  [ "$(printf '%s' "$output" | jq -r '.[0].values.style.required')" = "true" ]
  assert_contains "$(printf '%s' "$output" | jq -r '.[0].applies_to')" "non-board commits only"
}

@test "detect prints the detector's JSON unchanged and writes nothing" {
  mkrepo
  before="$(tree_sum)"
  expected="$(bash "$DETECT")"
  entry detect
  [ "$status" -eq 0 ]
  [ "$output" = "$expected" ]
  [ "$(tree_sum)" = "$before" ]
}

@test "presets prints 2 or 3 presets for every one of the 9 categories" {
  for id in $(jq -r '.categories | keys_unsorted[]' "$SCHEMA"); do
    entry presets "$id"
    [ "$status" -eq 0 ]
    n="$(printf '%s' "$output" | jq 'length')"
    [ "$n" -ge 2 ]
    [ "$n" -le 3 ]
    [ "$(printf '%s' "$output" | jq -c '[.[].id]')" = "$(jq -c --arg c "$id" '[.categories[$c][].id]' "$PRESETS")" ]
  done
}

@test "presets flags the preset values that are still a bare placeholder" {
  entry presets formatting-linting
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -c '[.[] | select(.id == "formatter-and-linter") | .placeholder_fields[]]')" = '["format_command","lint_command"]' ]
  entry presets naming
  [ "$(printf '%s' "$output" | jq -c '[.[].placeholder_fields[]]')" = '[]' ]
}

@test "presets for an unknown category exits 1" {
  entry presets no-such-category
  [ "$status" -eq 1 ]
  assert_contains "$stderr" "unknown category"
}

# --- check -----------------------------------------------------------------------------------------------------

@test "check accepts a valid value" {
  entry check naming identifier_case camelCase
  [ "$status" -eq 0 ]
  [ "$output" = '{"valid":true}' ]
  entry check commit-format subject_max_length 72
  [ "$output" = '{"valid":true}' ]
  entry check code-comments public_api_docs_required true
  [ "$output" = '{"valid":true}' ]
  entry check summary "one line is fine"
  [ "$output" = '{"valid":true}' ]
}

@test "check refuses a multi-line value with the validator's reason and still exits 0" {
  entry check naming identifier_case $'camel\nCase'
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r '.valid')" = "false" ]
  assert_contains "$(printf '%s' "$output" | jq -r '.reason')" "multi-line value"
}

@test "check refuses a multi-line summary" {
  entry check summary $'first\nsecond'
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r '.valid')" = "false" ]
  assert_contains "$(printf '%s' "$output" | jq -r '.reason')" "multi-line value"
}

@test "check refuses an empty value, an unknown field, an unknown category and a wrong type" {
  entry check naming identifier_case ""
  [ "$status" -eq 0 ]
  assert_contains "$(printf '%s' "$output" | jq -r '.reason')" "empty value"
  entry check naming no_such_field x
  [ "$status" -eq 0 ]
  assert_contains "$(printf '%s' "$output" | jq -r '.reason')" "unknown key in values"
  entry check no-such-category identifier_case x
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r '.valid')" = "false" ]
  assert_contains "$(printf '%s' "$output" | jq -r '.reason')" "unknown category"
  entry check commit-format subject_max_length seventy-two
  assert_contains "$(printf '%s' "$output" | jq -r '.reason')" "must be an integer"
  entry check code-comments public_api_docs_required maybe
  assert_contains "$(printf '%s' "$output" | jq -r '.reason')" "must be a boolean"
}

@test "check refuses a block strength and accepts advisory and confirm" {
  entry check naming strength block
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r '.valid')" = "false" ]
  assert_contains "$(printf '%s' "$output" | jq -r '.reason')" "block"
  entry check naming strength advisory
  [ "$output" = '{"valid":true}' ]
  entry check naming strength confirm
  [ "$output" = '{"valid":true}' ]
  entry check naming strength strict
  [ "$(printf '%s' "$output" | jq -r '.valid')" = "false" ]
}

@test "check refuses a bare <placeholder> value but accepts a pattern that merely contains <...>" {
  entry check formatting-linting lint_command "<lint command>"
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r '.valid')" = "false" ]
  assert_contains "$(printf '%s' "$output" | jq -r '.reason')" "unreplaced placeholder"
  entry check formatting-linting lint_command "npm run lint"
  [ "$output" = '{"valid":true}' ]
  entry check branching branch_pattern "feature/<slug>"
  [ "$output" = '{"valid":true}' ]
}

@test "check uses the real validator: a rule changed in a schema copy changes the verdict" {
  jq '.categories.naming.values.identifier_case.non_empty = false' "$SCHEMA" > "$BATS_TEST_TMPDIR/schema.json"
  JENGA_CONVENTIONS_SCHEMA="$BATS_TEST_TMPDIR/schema.json" entry check naming identifier_case ""
  [ "$output" = '{"valid":true}' ]
  entry check naming identifier_case ""
  [ "$(printf '%s' "$output" | jq -r '.valid')" = "false" ]
}

@test "check writes nothing" {
  before="$(tree_sum)"
  entry check naming identifier_case camelCase
  entry check naming identifier_case $'a\nb'
  [ "$(tree_sum)" = "$before" ]
}

# --- no layer option -------------------------------------------------------------------------------------------

@test "there is no --layer option: every subcommand refuses it and the contract's usage lines never mention it" {
  entry path --layer user
  [ "$status" -eq 2 ]
  entry show --layer user
  [ "$status" -eq 2 ]
  new_draft
  entry draft-set naming --draft "$DRAFT" --source custom --summary x --value identifier_case=x --layer user
  [ "$status" -eq 2 ]
  entry commit --draft "$DRAFT" --layer project
  [ "$status" -eq 2 ]
  entry --help
  [ "$status" -eq 0 ]
  usage_lines="$(printf '%s\n' "$output" | grep -E '^  conventions-entry.sh ')"
  assert_not_contains "$usage_lines" "--layer"
}

@test "an unknown subcommand and a missing subcommand are usage errors" {
  entry frobnicate
  [ "$status" -eq 2 ]
  entry
  [ "$status" -eq 2 ]
}

# --- draft-init ------------------------------------------------------------------------------------------------

@test "draft-init with no instance seeds the empty skeleton, outside the project tree" {
  before="$(tree_sum)"
  entry draft-init
  [ "$status" -eq 0 ]
  [ -f "$output" ]
  assert_starts_with "$output" "$SCRATCH_TMP/"
  [ "$(jq -c . "$output")" = '{"conventions_version":1,"categories":{}}' ]
  assert_contains "$stderr" "starting blank"
  [ "$(tree_sum)" = "$before" ]
  [ -z "$(find "$PROJ" -name 'conventions-draft*')" ]
}

@test "draft-init never places the draft inside the project tree, even when TMPDIR points into it" {
  mkdir -p "$PROJ/scratch"
  TMPDIR="$PROJ/scratch" entry draft-init
  [ "$status" -eq 0 ]
  case "$output" in "$PROJ"/*) false ;; esac
  [ -z "$(find "$PROJ" -name 'conventions-draft*')" ]
  rm -f "$output"
}

@test "draft-init on a project with recorded conventions seeds the recorded answers (a re-run pre-selects them)" {
  recorded_two
  entry draft-init
  [ "$status" -eq 0 ]
  [ "$(jq -c . "$output")" = "$(jq -c . "$CONV")" ]
  assert_contains "$stderr" "seeded from the recorded conventions"
  DRAFT="$output"
  entry draft-show --draft "$DRAFT" --category naming
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r '.summary')" = "camelCase identifiers" ]
}

@test "draft-init refuses an invalid recorded instance and creates no draft" {
  printf '{"conventions_version":1,"categories":{"naming":{"source":"custom","summary":"x","values":{"identifier_case":"a"},"strength":"block"}}}\n' > "$CONV"
  entry draft-init
  [ "$status" -eq 4 ]
  assert_contains "$stderr" "not valid"
  [ -z "$(ls "$SCRATCH_TMP")" ]
}

# --- draft-set -------------------------------------------------------------------------------------------------

@test "draft-set from a preset takes the summary and values from the catalog and records the preset id" {
  new_draft
  pid="$(preset_id naming 0)"
  entry draft-set naming --draft "$DRAFT" --source preset --preset "$pid"
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r '.changed')" = "true" ]
  [ "$(jq -r '.categories.naming.source' "$DRAFT")" = "preset" ]
  [ "$(jq -r '.categories.naming.preset' "$DRAFT")" = "$pid" ]
  [ "$(jq -r '.categories.naming.summary' "$DRAFT")" = "$(jq -r '.categories.naming[0].label' "$PRESETS")" ]
  [ "$(jq -c '.categories.naming.values' "$DRAFT")" = "$(jq -c '.categories.naming[0].values' "$PRESETS")" ]
  [ "$(bash "$VALIDATE_CONV" "$DRAFT" 2>/dev/null)" = "PASS $DRAFT" ]
}

@test "draft-set from a preset honours --summary and a --value override" {
  new_draft
  entry draft-set naming --draft "$DRAFT" --source preset --preset "$(preset_id naming 0)" --summary "our naming" --value identifier_case=snake_case
  [ "$status" -eq 0 ]
  [ "$(jq -r '.categories.naming.summary' "$DRAFT")" = "our naming" ]
  [ "$(jq -r '.categories.naming.values.identifier_case' "$DRAFT")" = "snake_case" ]
}

@test "draft-set from detected output records source detected with the detector's values" {
  mkrepo
  new_draft
  entry draft-set commit-format --draft "$DRAFT" --source detected
  [ "$status" -eq 0 ]
  [ "$(jq -r '.categories["commit-format"].source' "$DRAFT")" = "detected" ]
  [ "$(jq -r '.categories["commit-format"].values.style' "$DRAFT")" = "conventional-commits" ]
  [ "$(jq -r '.categories["commit-format"].summary' "$DRAFT")" = "Conventional Commits" ]
  [ "$(bash "$VALIDATE_CONV" "$DRAFT" 2>/dev/null)" = "PASS $DRAFT" ]
}

@test "draft-set --source detected exits 1 when the detector found nothing for the category" {
  new_draft
  before="$(sum "$DRAFT")"
  entry draft-set code-comments --draft "$DRAFT" --source detected
  [ "$status" -eq 1 ]
  assert_contains "$stderr" "found no standard"
  [ "$(sum "$DRAFT")" = "$before" ]
}

@test "draft-set from custom text records source custom with the given values" {
  new_draft
  entry draft-set testing --draft "$DRAFT" --source custom --summary "integration tests first" --value expectation="integration tests" --value test_dir=spec
  [ "$status" -eq 0 ]
  [ "$(jq -r '.categories.testing.source' "$DRAFT")" = "custom" ]
  [ "$(jq -r '.categories.testing.values.test_dir' "$DRAFT")" = "spec" ]
  [ "$(jq -r '.categories.testing | has("preset")' "$DRAFT")" = "false" ]
}

@test "draft-set types --value from the schema: booleans and integers" {
  new_draft
  entry draft-set commit-format --draft "$DRAFT" --source custom --summary "short subjects" --value style=custom-style --value subject_max_length=72
  [ "$status" -eq 0 ]
  [ "$(jq -r '.categories["commit-format"].values.subject_max_length | type' "$DRAFT")" = "number" ]
  entry draft-set code-comments --draft "$DRAFT" --source custom --summary "document the public API" --value policy=public-api --value public_api_docs_required=true
  [ "$status" -eq 0 ]
  [ "$(jq -r '.categories["code-comments"].values.public_api_docs_required | type' "$DRAFT")" = "boolean" ]
}

@test "draft-set refuses an invalid input, with the validator's reason, leaving the draft byte-identical" {
  new_draft
  set_preset naming
  before="$(sum "$DRAFT")"
  # multi-line summary
  entry draft-set testing --draft "$DRAFT" --source custom --summary $'one\ntwo' --value expectation=x
  [ "$status" -eq 1 ]
  assert_contains "$stderr" "multi-line value"
  [ "$(sum "$DRAFT")" = "$before" ]
  # block strength
  entry draft-set testing --draft "$DRAFT" --source custom --summary ok --value expectation=x --strength block
  [ "$status" -eq 1 ]
  assert_contains "$stderr" "block"
  [ "$(sum "$DRAFT")" = "$before" ]
  # unknown field
  entry draft-set testing --draft "$DRAFT" --source custom --summary ok --value expectation=x --value no_such_field=y
  [ "$status" -eq 1 ]
  assert_contains "$stderr" "unknown key in values"
  [ "$(sum "$DRAFT")" = "$before" ]
  # wrong type
  entry draft-set commit-format --draft "$DRAFT" --source custom --summary ok --value style=x --value subject_max_length=lots
  [ "$status" -eq 1 ]
  assert_contains "$stderr" "must be an integer"
  [ "$(sum "$DRAFT")" = "$before" ]
  # missing required field
  entry draft-set testing --draft "$DRAFT" --source custom --summary ok
  [ "$status" -eq 1 ]
  assert_contains "$stderr" "missing required field"
  [ "$(sum "$DRAFT")" = "$before" ]
  # unknown preset and unknown category
  entry draft-set naming --draft "$DRAFT" --source preset --preset no-such-preset
  [ "$status" -eq 1 ]
  [ "$(sum "$DRAFT")" = "$before" ]
  entry draft-set no-such-category --draft "$DRAFT" --source custom --summary ok --value x=y
  [ "$status" -eq 1 ]
  [ "$(sum "$DRAFT")" = "$before" ]
}

@test "draft-set usage errors: missing --source, --preset without preset source, custom without summary" {
  new_draft
  entry draft-set naming --draft "$DRAFT"
  [ "$status" -eq 2 ]
  entry draft-set naming --draft "$DRAFT" --source custom --summary x --preset foo
  [ "$status" -eq 2 ]
  entry draft-set naming --draft "$DRAFT" --source custom
  [ "$status" -eq 2 ]
  entry draft-set naming --draft "$DRAFT" --source preset
  [ "$status" -eq 2 ]
  entry draft-set naming --source custom --summary x
  [ "$status" -eq 2 ]
}

@test "a preset with a <placeholder> command is never stored as is: refused until the real value or --unset is given" {
  new_draft
  before="$(sum "$DRAFT")"
  entry draft-set formatting-linting --draft "$DRAFT" --source preset --preset formatter-and-linter
  [ "$status" -eq 1 ]
  assert_contains "$stderr" "unreplaced placeholder"
  assert_contains "$stderr" "lint_command"
  assert_contains "$stderr" "format_command"
  [ "$(sum "$DRAFT")" = "$before" ]
  # only one of the two replaced: still refused
  entry draft-set formatting-linting --draft "$DRAFT" --source preset --preset formatter-and-linter --value lint_command="npm run lint"
  [ "$status" -eq 1 ]
  assert_contains "$stderr" "format_command"
  [ "$(sum "$DRAFT")" = "$before" ]
  # a placeholder typed in by hand is refused the same way
  entry draft-set formatting-linting --draft "$DRAFT" --source preset --preset formatter-and-linter --value lint_command="<lint command>" --value format_command="npm run format"
  [ "$status" -eq 1 ]
  [ "$(sum "$DRAFT")" = "$before" ]
  # both replaced: stored with the real commands
  entry draft-set formatting-linting --draft "$DRAFT" --source preset --preset formatter-and-linter --value lint_command="npm run lint" --value format_command="npm run format"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.categories["formatting-linting"].values.lint_command' "$DRAFT")" = "npm run lint" ]
  # one replaced, the other left unset
  entry draft-set formatting-linting --draft "$DRAFT" --source preset --preset formatter-and-linter --value lint_command="npm run lint" --unset format_command
  [ "$status" -eq 0 ]
  [ "$(jq -r '.categories["formatting-linting"].values | has("format_command")' "$DRAFT")" = "false" ]
  [ "$(grep -c '<' "$DRAFT")" = "0" ]
}

@test "draft-set keeps categories in schema order whatever the order they were answered in" {
  new_draft
  set_custom testing "unit tests" expectation=unit
  set_custom naming "camelCase" identifier_case=camelCase
  set_custom commit-format "short subjects" style=short
  [ "$(jq -c '.categories | keys_unsorted' "$DRAFT")" = '["commit-format","naming","testing"]' ]
}

# --- draft-skip / draft-show / draft-diff ----------------------------------------------------------------------

@test "draft-skip removes a category from the draft and is a no-op for one that is not there" {
  new_draft
  set_preset naming
  entry draft-skip naming --draft "$DRAFT"
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r '.changed')" = "true" ]
  [ "$(jq -r '.categories | has("naming")' "$DRAFT")" = "false" ]
  entry draft-skip naming --draft "$DRAFT"
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r '.changed')" = "false" ]
  entry draft-skip no-such-category --draft "$DRAFT"
  [ "$status" -eq 1 ]
}

@test "draft-skip on a re-run drops a recorded category from the draft only, not from the instance" {
  recorded_two
  before="$(sum "$CONV")"
  new_draft
  entry draft-skip testing --draft "$DRAFT"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.categories | has("testing")' "$DRAFT")" = "false" ]
  [ "$(sum "$CONV")" = "$before" ]
}

@test "draft-show prints the draft, or one entry; exits 1 for an absent entry; needs --draft" {
  new_draft
  set_preset naming
  entry draft-show --draft "$DRAFT"
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r '.categories | keys[0]')" = "naming" ]
  entry draft-show --draft "$DRAFT" --category naming
  [ "$status" -eq 0 ]
  entry draft-show --draft "$DRAFT" --category testing
  [ "$status" -eq 1 ]
  entry draft-show
  [ "$status" -eq 2 ]
  entry draft-show --draft "$BATS_TEST_TMPDIR/no-such-draft"
  [ "$status" -eq 1 ]
}

@test "draft-diff reports added, removed, changed and unchanged categories against the recorded instance" {
  recorded_two
  put_instance '{
    "naming": {source: "custom", summary: "camelCase identifiers", values: {identifier_case: "camelCase"}},
    "testing": {source: "custom", summary: "unit tests for new logic", values: {expectation: "unit tests"}},
    "branching": {source: "custom", summary: "trunk based", values: {model: "trunk-based"}}
  }'
  new_draft
  entry draft-skip branching --draft "$DRAFT" >/dev/null
  set_custom testing "integration tests first" expectation="integration tests"
  set_custom commit-format "short subjects" style=short
  entry draft-diff --draft "$DRAFT"
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -c '.added')" = '["commit-format"]' ]
  [ "$(printf '%s' "$output" | jq -c '.removed')" = '["branching"]' ]
  [ "$(printf '%s' "$output" | jq -c '.changed')" = '["testing"]' ]
  [ "$(printf '%s' "$output" | jq -c '.unchanged')" = '["naming"]' ]
  [ "$(printf '%s' "$output" | jq -r '.categories[] | select(.id == "testing") | .before.summary')" = "unit tests for new logic" ]
  [ "$(printf '%s' "$output" | jq -r '.categories[] | select(.id == "testing") | .after.summary')" = "integration tests first" ]
  [ "$(printf '%s' "$output" | jq -r '.categories[] | select(.id == "commit-format") | .before')" = "null" ]
}

@test "draft-diff --format text prints one marked line per category; with no instance everything is added" {
  new_draft
  set_custom naming "camelCase" identifier_case=camelCase
  entry draft-diff --draft "$DRAFT" --format text
  [ "$status" -eq 0 ]
  [ "$output" = "+ naming: camelCase" ]
  entry draft-diff --draft "$DRAFT" --format xml
  [ "$status" -eq 2 ]
}

@test "the draft subcommands write nothing inside the project" {
  recorded_two
  before="$(tree_sum)"
  new_draft
  set_preset naming
  entry draft-skip testing --draft "$DRAFT"
  entry draft-show --draft "$DRAFT"
  entry draft-diff --draft "$DRAFT"
  [ "$(tree_sum)" = "$before" ]
}

# --- commit: success -------------------------------------------------------------------------------------------

@test "commit writes conventions.json and the conv- checklist items, validates both, prints success and removes the draft" {
  new_draft
  set_preset naming
  set_custom testing "unit tests for new logic" expectation="unit tests"
  entry commit --draft "$DRAFT"
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r '.ok')" = "true" ]
  [ "$(printf '%s' "$output" | jq -r '.action')" = "commit" ]
  [ "$(printf '%s' "$output" | jq -r '.categories')" = "2" ]
  [ "$(printf '%s' "$output" | jq -r '.path')" = "$CONV" ]
  [ ! -e "$DRAFT" ]
  [ -f "$CONV" ]
  [ "$(bash "$VALIDATE_CONV" "$CONV" 2>/dev/null)" = "PASS $CONV" ]
  [ "$(bash "$VALIDATE_REG" "$REG" 2>/dev/null)" = "PASS $REG" ]
  [ "$(jq -c '[.items[] | select(.id | startswith("conv-")) | .id]' "$REG")" = '["conv-naming","conv-testing"]' ]
  [ "$(jq -c '[.items[] | select(.id | startswith("conv-")) | .provenance.source] | unique' "$REG")" = '["convention"]' ]
}

@test "commit never produces a block item and leaves no temp, backup or lock files beside the instance" {
  new_draft
  set_preset naming
  set_custom testing "unit tests" expectation=unit
  entry commit --draft "$DRAFT"
  [ "$status" -eq 0 ]
  [ "$(jq -r '[.items[] | select(.id | startswith("conv-")) | .enforcement] | map(select(. == "block")) | length' "$REG")" = "0" ]
  [ "$(ls -A "$CFG" | sort | tr '\n' ' ')" = "checklists.json conventions.json workflow.json " ]
}

@test "commit keeps hand-written checklist items and writes categories in schema order" {
  jq -n '{checklist_version: 1, items: [{id: "hand-written", text: "mine", situations: ["pre-commit"], kind: "judgment", enforcement: "advisory", tick_scope: "run"}]}' > "$REG"
  new_draft
  set_custom testing "unit tests" expectation=unit
  set_custom naming "camelCase" identifier_case=camelCase
  entry commit --draft "$DRAFT"
  [ "$status" -eq 0 ]
  [ "$(jq -c '.categories | keys_unsorted' "$CONV")" = '["naming","testing"]' ]
  [ "$(jq -r '.items[0].id' "$REG")" = "hand-written" ]
  [ "$(jq -c '[.items[].id]' "$REG")" = '["hand-written","conv-naming","conv-testing"]' ]
}

@test "after a commit, a re-run seeds its draft with the recorded answers instead of starting blank" {
  new_draft
  set_preset naming
  entry commit --draft "$DRAFT"
  [ "$status" -eq 0 ]
  entry draft-init
  [ "$status" -eq 0 ]
  DRAFT="$output"
  [ "$(jq -c . "$DRAFT")" = "$(jq -c . "$CONV")" ]
  [ "$(jq -r '.categories.naming.preset' "$DRAFT")" = "$(preset_id naming 0)" ]
}

@test "committing a draft with a category removed also removes its conv- item" {
  new_draft
  set_preset naming
  set_custom testing "unit tests" expectation=unit
  entry commit --draft "$DRAFT"
  [ "$status" -eq 0 ]
  new_draft
  entry draft-skip testing --draft "$DRAFT"
  entry commit --draft "$DRAFT"
  [ "$status" -eq 0 ]
  [ "$(jq -c '[.items[] | select(.id | startswith("conv-")) | .id]' "$REG")" = '["conv-naming"]' ]
  [ "$(jq -c '.categories | keys' "$CONV")" = '["naming"]' ]
}

@test "a second commit of an unchanged draft changes nothing" {
  new_draft
  set_preset naming
  entry commit --draft "$DRAFT"
  [ "$status" -eq 0 ]
  conv_sum="$(sum "$CONV")"
  reg_sum="$(sum "$REG")"
  new_draft
  entry commit --draft "$DRAFT"
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r '.changed')" = "false" ]
  [ "$(sum "$CONV")" = "$conv_sum" ]
  [ "$(sum "$REG")" = "$reg_sum" ]
}

# --- commit: refusal and rollback ------------------------------------------------------------------------------

@test "commit refuses an invalid draft before writing anything and keeps the draft" {
  new_draft
  set_preset naming
  jq '.categories.naming.strength = "block"' "$DRAFT" > "$DRAFT.edit" && mv "$DRAFT.edit" "$DRAFT"
  before="$(tree_sum)"
  entry commit --draft "$DRAFT"
  [ "$status" -eq 4 ]
  assert_not_contains "$output" '"ok"'
  assert_contains "$stderr" "block"
  [ "$(tree_sum)" = "$before" ]
  [ -f "$DRAFT" ]
}

@test "commit refuses a draft that still holds a <placeholder> value" {
  new_draft
  jq '.categories["formatting-linting"] = {source: "custom", summary: "lint", values: {approach: "lint", lint_command: "<lint command>"}}' "$DRAFT" > "$DRAFT.edit" && mv "$DRAFT.edit" "$DRAFT"
  before="$(tree_sum)"
  entry commit --draft "$DRAFT"
  [ "$status" -eq 4 ]
  assert_contains "$stderr" "unreplaced placeholder"
  [ "$(tree_sum)" = "$before" ]
  [ -f "$DRAFT" ]
}

@test "commit rolls back when the generator fails: previous conventions.json and registry restored, no success line, draft kept" {
  recorded_two
  new_draft
  set_preset branching
  jq -n '{checklist_version: 1, items: [{id: "hand-written", text: "mine", situations: ["pre-commit"], kind: "judgment", enforcement: "advisory", tick_scope: "run"}]}' > "$REG"
  conv_before="$(sum "$CONV")"
  reg_before="$(sum "$REG")"
  stub_generator_fail
  entry commit --draft "$DRAFT"
  [ "$status" -ne 0 ]
  [ "$status" -eq 7 ]
  assert_not_contains "$output" '"ok"'
  assert_contains "$stderr" "stub generator: boom"
  assert_contains "$stderr" "restored"
  [ "$(sum "$CONV")" = "$conv_before" ]
  [ "$(sum "$REG")" = "$reg_before" ]
  [ -f "$DRAFT" ]
  [ "$(ls -A "$CFG" | sort | tr '\n' ' ')" = "checklists.json conventions.json workflow.json " ]
}

@test "commit rolls back to 'no conventions.json' when there was none and the generator fails" {
  new_draft
  set_preset naming
  stub_generator_fail
  entry commit --draft "$DRAFT"
  [ "$status" -eq 7 ]
  assert_not_contains "$output" '"ok"'
  [ ! -e "$CONV" ]
  [ ! -e "$REG" ]
  [ -f "$DRAFT" ]
}

@test "commit rolls back when the resulting registry fails validation: both files restored, no success line, draft kept" {
  recorded_two
  new_draft
  set_preset branching
  bash "$REPO_ROOT/scripts/generate-convention-checklist.sh" >/dev/null
  conv_before="$(sum "$CONV")"
  reg_before="$(sum "$REG")"
  stub_generator_bad_registry
  entry commit --draft "$DRAFT"
  [ "$status" -ne 0 ]
  [ "$status" -eq 4 ]
  assert_not_contains "$output" '"ok"'
  assert_contains "$stderr" "failed validation"
  [ "$(sum "$CONV")" = "$conv_before" ]
  [ "$(sum "$REG")" = "$reg_before" ]
  [ -f "$DRAFT" ]
}

@test "commit rolls back to 'no files' when there was no conventions.json and the registry fails validation" {
  new_draft
  set_preset naming
  stub_generator_bad_registry
  entry commit --draft "$DRAFT"
  [ "$status" -eq 4 ]
  assert_not_contains "$output" '"ok"'
  [ ! -e "$CONV" ]
  [ ! -e "$REG" ]
  [ -f "$DRAFT" ]
}

@test "commit while the lock is held exits non-zero without writing, and the draft is kept" {
  recorded_two
  new_draft
  set_preset branching
  conv_before="$(sum "$CONV")"
  mkdir "$CONV.lock.d"
  printf '%s\n' "$$" > "$CONV.lock.d/pid"
  WITH_LOCK_TIMEOUT_SECONDS=1 entry commit --draft "$DRAFT"
  [ "$status" -eq 6 ]
  assert_not_contains "$output" '"ok"'
  assert_contains "$stderr" "could not acquire the lock"
  [ "$(sum "$CONV")" = "$conv_before" ]
  [ ! -e "$REG" ]
  [ -f "$DRAFT" ]
  rm -rf "$CONV.lock.d"
}

# --- isolation -------------------------------------------------------------------------------------------------

@test "a full flow leaves this repository's own project/configs/ byte-identical" {
  before="$(find "$REAL_CONFIGS" -type f -exec cksum {} + | sort | cksum)"
  new_draft
  set_preset naming
  set_custom testing "unit tests" expectation=unit
  entry commit --draft "$DRAFT"
  [ "$status" -eq 0 ]
  [ "$(find "$REAL_CONFIGS" -type f -exec cksum {} + | sort | cksum)" = "$before" ]
}
