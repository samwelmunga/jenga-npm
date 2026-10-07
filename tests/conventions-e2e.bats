#!/usr/bin/env bats
#
# End-to-end coverage of the whole conventions pipeline (E69_S06_T04): detect, the wizard's scripted answers, the
# conventions.json it writes, the conv- checklist items generated from it, and the real checker listing them.
#
# One scratch project is walked through the REAL scripts with no mocks and no stubs:
#   detect-conventions.sh  ->  conventions-entry.sh draft-init / draft-set / draft-skip / draft-diff / commit
#   ->  conventions.json (validated)  ->  generate-convention-checklist.sh (run by `commit`)  ->  checklists.json
#   ->  scripts/checklist.sh list / check  ->  conventions-digest.sh.
#
# The scratch project is a git repository with a Conventional-Commits history (plus EST board commits), a
# .prettierrc, an eslint config and a package.json `lint` script. The shipped default registry
# (templates/checklists.json) seeds the scratch instance, so the test also proves the default's items survive.
#
# Everything lives under $BATS_TEST_TMPDIR and is aimed at the scratch project with JENGA_PROJECT_ROOT; this
# repository's own project/configs/ is checksummed in setup and teardown and never written.

bats_require_minimum_version 1.5.0
load helpers/assertions

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
ENTRY="$REPO_ROOT/skills/j-conventions/scripts/conventions-entry.sh"
DETECT="$REPO_ROOT/skills/j-conventions/scripts/detect-conventions.sh"
VALIDATE_CONV="$REPO_ROOT/scripts/validate-conventions.sh"
VALIDATE_REG="$REPO_ROOT/scripts/validate-checklists.sh"
CHECKLIST="$REPO_ROOT/scripts/checklist.sh"
DIGEST="$REPO_ROOT/scripts/conventions-digest.sh"
DEFAULT_REG="$REPO_ROOT/templates/checklists.json"
PRESETS="$REPO_ROOT/templates/conventions-presets.json"
REAL_CONFIGS="$REPO_ROOT/project/configs"

setup() {
  REAL_SUM="$(find "$REAL_CONFIGS" -type f -exec cksum {} + | sort | cksum)"
  unset JENGA_CONVENTIONS_SCHEMA JENGA_CONVENTIONS_PRESETS JENGA_CONVENTIONS_GENERATOR JENGA_CONVENTIONS_CHECKLIST_MAP
  unset JENGA_CHECKLISTS_DEFAULT_FILE JENGA_CHECKLISTS_FILE JENGA_CHECKLIST_RUN_ID
  SCRATCH_TMP="$BATS_TEST_TMPDIR/tmp"
  mkdir -p "$SCRATCH_TMP"
  export TMPDIR="$SCRATCH_TMP"
  export JENGA_CHECKLIST_STATE_DIR="$BATS_TEST_TMPDIR/state"
  export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.com GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.com
  PROJ="$BATS_TEST_TMPDIR/proj"
  CFG="$PROJ/project/configs"
  CONV="$CFG/conventions.json"
  REG="$CFG/checklists.json"
  mkdir -p "$CFG" "$PROJ/src"
  printf '{"paths":{"configs":"project/configs"}}\n' > "$CFG/workflow.json"
  export JENGA_PROJECT_ROOT="$PROJ"
  build_project
}

teardown() {
  [ "$(find "$REAL_CONFIGS" -type f -exec cksum {} + | sort | cksum)" = "$REAL_SUM" ]
}

# --- the scratch project ---------------------------------------------------------------------------------------

commit_file() { # <subject>
  printf '%s\n' "$1" >> "$PROJ/src/log.txt"
  git -C "$PROJ" add -A >/dev/null
  git -C "$PROJ" commit -q -m "$1"
}

build_project() {
  git -C "$PROJ" init -q
  printf '{ "singleQuote": true }\n' > "$PROJ/.prettierrc"
  printf '{ "root": true }\n' > "$PROJ/.eslintrc.json"
  printf '{ "name": "scratch", "version": "1.0.0", "scripts": { "lint": "exit 0", "test": "exit 0" } }\n' > "$PROJ/package.json"
  # Conventional Commits history, with EST board commits mixed in (the detector must skip those).
  commit_file "feat: add the first thing"
  commit_file "fix(core): handle the empty case"
  commit_file "task(E01_S01_T01): board work that is not part of the sample"
  commit_file "docs: describe the thing"
  commit_file "chore(deps): bump a dependency"
  commit_file "feat(api): add an endpoint"
  commit_file "story(E01_S01): board rollup"
  commit_file "refactor: split a module"
}

# --- the scripted wizard ---------------------------------------------------------------------------------------

preset_id() { jq -r --arg c "$1" --argjson i "${2:-0}" '.categories[$c][$i].id' "$PRESETS"; }

# answer_all: the scripted equivalent of answering all 9 categories: detected, preset, custom and one skipped.
answer_all() {
  DRAFT="$(bash "$ENTRY" draft-init 2>/dev/null)"
  [ -f "$DRAFT" ]
  # detected
  bash "$ENTRY" draft-set commit-format --draft "$DRAFT" --source detected >/dev/null
  bash "$ENTRY" draft-set formatting-linting --draft "$DRAFT" --source detected >/dev/null
  # preset
  bash "$ENTRY" draft-set branching --draft "$DRAFT" --source preset --preset "$(preset_id branching 0)" >/dev/null
  bash "$ENTRY" draft-set code-comments --draft "$DRAFT" --source preset --preset "$(preset_id code-comments 0)" >/dev/null
  bash "$ENTRY" draft-set file-layout --draft "$DRAFT" --source preset --preset "$(preset_id file-layout 0)" >/dev/null
  bash "$ENTRY" draft-set language-tooling --draft "$DRAFT" --source preset --preset "$(preset_id language-tooling 0)" >/dev/null
  # custom
  bash "$ENTRY" draft-set naming --draft "$DRAFT" --source custom --summary "camelCase identifiers, kebab-case files" \
    --value identifier_case=camelCase --value file_case=kebab-case >/dev/null
  bash "$ENTRY" draft-set documentation-placement --draft "$DRAFT" --source custom --summary "Docs live in the wiki" \
    --value policy=wiki >/dev/null
  # skipped
  bash "$ENTRY" draft-skip testing --draft "$DRAFT" >/dev/null
}

# run_wizard: answer everything and commit.
run_wizard() {
  answer_all
  run --separate-stderr bash "$ENTRY" commit --draft "$DRAFT"
}

# --- tests -----------------------------------------------------------------------------------------------------

@test "e2e 1: detection reports the standards the scratch project already follows, without writing anything" {
  run --separate-stderr bash "$DETECT"
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r '.categories["commit-format"].preset_match')" = "conventional-commits" ]
  [ "$(printf '%s' "$output" | jq -r '.categories["commit-format"].detected.style')" = "conventional-commits" ]
  [ "$(printf '%s' "$output" | jq -r '.categories["formatting-linting"].detected.lint_command')" = "npm run lint" ]
  [ "$(printf '%s' "$output" | jq -r '.categories["code-comments"].preset_only')" = "true" ]
  # The 3 EST board commits are excluded from the sample, not counted as non-conforming.
  assert_contains "$(printf '%s' "$output" | jq -r '.categories["commit-format"].evidence')" "EST"
  [ ! -e "$CONV" ]
  [ ! -e "$REG" ]
}

@test "e2e 2: scripted answers across detected, preset, custom and skipped write a valid conventions.json" {
  run_wizard
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r '.ok')" = "true" ]
  [ -f "$CONV" ]
  run bash "$VALIDATE_CONV" "$CONV"
  [ "$status" -eq 0 ]
  # 8 recorded, the skipped category is absent.
  [ "$(jq -r '.categories | length' "$CONV")" = "8" ]
  [ "$(jq -r '.categories | has("testing")' "$CONV")" = "false" ]
  [ "$(jq -r '.categories["commit-format"].source' "$CONV")" = "detected" ]
  [ "$(jq -r '.categories["formatting-linting"].source' "$CONV")" = "detected" ]
  [ "$(jq -r '.categories.branching.source' "$CONV")" = "preset" ]
  [ "$(jq -r '.categories.naming.source' "$CONV")" = "custom" ]
  # the draft is consumed by a successful commit
  [ ! -e "$DRAFT" ]
}

@test "e2e 3: the registry is seeded from the shipped default and gains one conv- item per recorded category" {
  [ ! -e "$REG" ]
  run_wizard
  [ "$status" -eq 0 ]
  run bash "$VALIDATE_REG" "$REG"
  [ "$status" -eq 0 ]
  # the default's items are all still present, unchanged
  local id
  for id in $(jq -r '.items[].id' "$DEFAULT_REG"); do
    [ "$(jq -r --arg id "$id" '[.items[] | select(.id == $id)] | length' "$REG")" = "1" ]
  done
  [ "$(jq -S -c '.items[:'"$(jq '.items | length' "$DEFAULT_REG")"']' "$REG")" = "$(jq -S -c '.items' "$DEFAULT_REG")" ]
  # one managed item per recorded category, none for the skipped one
  [ "$(jq -r '[.items[] | select(.provenance.source == "convention")] | length' "$REG")" = "8" ]
  [ "$(jq -r '[.items[] | select(.id | startswith("conv-"))] | length' "$REG")" = "8" ]
  [ "$(jq -r '[.items[] | select(.id == "conv-testing")] | length' "$REG")" = "0" ]
  [ "$(jq -r '[.items[] | select(.id == "conv-naming")] | length' "$REG")" = "1" ]
}

@test "e2e 4: no conv- item is block strength, and only advisory or confirm appear (whole registry)" {
  run_wizard
  [ "$status" -eq 0 ]
  [ "$(jq -r '[.items[] | select((.id | startswith("conv-")) and .enforcement == "block")] | length' "$REG")" = "0" ]
  [ "$(jq -r '[.items[] | select(.provenance.source == "convention" and .enforcement == "block")] | length' "$REG")" = "0" ]
  [ "$(jq -r '[.items[] | select(.provenance.source == "convention") | .enforcement] | unique | map(select(. != "advisory" and . != "confirm")) | length' "$REG")" = "0" ]
  # the machine-verifiable category is confirm, the judgment ones advisory; commit-format is advisory (timing finding)
  [ "$(jq -r '.items[] | select(.id == "conv-formatting-linting") | .enforcement' "$REG")" = "confirm" ]
  [ "$(jq -r '.items[] | select(.id == "conv-commit-format") | .enforcement' "$REG")" = "advisory" ]
  [ "$(jq -r '.items[] | select(.id == "conv-naming") | .enforcement' "$REG")" = "advisory" ]
}

@test "e2e 5: the real checker lists the conv- items at pre-commit and pre-task" {
  run_wizard
  [ "$status" -eq 0 ]
  run --separate-stderr bash "$CHECKLIST" list pre-commit
  [ "$status" -eq 0 ]
  assert_contains "$output" "conv-commit-format"
  assert_contains "$output" "conv-formatting-linting"
  assert_contains "$output" "conv-naming"
  assert_contains "$output" "conv-code-comments"
  assert_contains "$output" "conv-documentation-placement"
  run --separate-stderr bash "$CHECKLIST" list pre-task
  [ "$status" -eq 0 ]
  assert_contains "$output" "conv-branching"
  assert_contains "$output" "conv-naming"
  assert_contains "$output" "conv-file-layout"
  assert_contains "$output" "conv-language-tooling"
  assert_not_contains "$output" "conv-testing"
}

@test "e2e 6: checker check runs on the conv- items, the lint item passes and no conv- item halts" {
  command -v npm >/dev/null 2>&1 || skip "npm is not installed"
  run_wizard
  [ "$status" -eq 0 ]
  run --separate-stderr env JENGA_CHECKLIST_RUN_ID=e2e-run bash "$CHECKLIST" check pre-commit
  # the output is one JSON array whatever the exit status (the shipped default may hold its own items)
  [ "$(printf '%s' "$output" | jq -r 'type')" = "array" ]
  [ "$(printf '%s' "$output" | jq -r '[.[] | select(.id | startswith("conv-"))] | length')" -ge 5 ]
  [ "$(printf '%s' "$output" | jq -r '.[] | select(.id == "conv-formatting-linting") | .result')" = "passed" ]
  [ "$(printf '%s' "$output" | jq -r '.[] | select(.id == "conv-formatting-linting") | .kind')" = "machine" ]
  # advisory judgment items remind, they never halt
  [ "$(printf '%s' "$output" | jq -r '[.[] | select((.id | startswith("conv-")) and .action == "halt")] | length')" = "0" ]
  [ "$(printf '%s' "$output" | jq -r '.[] | select(.id == "conv-commit-format") | .action')" = "remind" ]
}

@test "e2e 7: a failing lint command makes the confirm item prompt, never halt" {
  run_wizard
  [ "$status" -eq 0 ]
  # point the convention at a lint command that fails, and regenerate through the real generator
  jq '.categories["formatting-linting"].values.lint_command = "exit 3"' "$CONV" > "$BATS_TEST_TMPDIR/c.json"
  cp "$BATS_TEST_TMPDIR/c.json" "$CONV"
  run bash "$REPO_ROOT/scripts/generate-convention-checklist.sh"
  [ "$status" -eq 0 ]
  run --separate-stderr bash "$CHECKLIST" check pre-commit
  [ "$(printf '%s' "$output" | jq -r '.[] | select(.id == "conv-formatting-linting") | .result')" = "failed" ]
  [ "$(printf '%s' "$output" | jq -r '.[] | select(.id == "conv-formatting-linting") | .action')" = "prompt" ]
}

@test "e2e 8: EST naming for board commits is carried by the generated text and the digest" {
  run_wizard
  [ "$status" -eq 0 ]
  assert_contains "$(jq -r '.items[] | select(.id == "conv-commit-format") | .text' "$REG")" "EST naming"
  assert_contains "$(jq -r '.items[] | select(.id == "conv-commit-format") | .text' "$REG")" "non-board commits only"
  run --separate-stderr bash "$DIGEST"
  [ "$status" -eq 0 ]
  assert_contains "$output" "EST: board commits keep the mandatory task(E##_S##_T##):"
  assert_contains "$output" "applies to non-board commits only"
  assert_contains "$output" "Precedence:"
  # the commit-format recorded convention cannot touch a board subject
  run --separate-stderr bash "$REPO_ROOT/skills/j-commit/scripts/commit-subject-check.sh" "task(E01_S01_T01): anything at all"
  [ "$status" -eq 0 ]
  assert_contains "$output" "kind=board"
}

@test "e2e 9: the digest prints at most 30 lines including the EST line" {
  run_wizard
  [ "$status" -eq 0 ]
  run --separate-stderr bash "$DIGEST" --agent developer
  [ "$status" -eq 0 ]
  local lines
  lines="$(printf '%s\n' "$output" | wc -l | tr -d ' ')"
  [ "$lines" -le 30 ]
  [ "$lines" -ge 4 ]
  assert_contains "$output" "EST:"
  assert_contains "$output" "(checklist item conv-naming)"
}

@test "e2e 10: a second wizard run pre-selects the recorded answers and an unchanged commit is idempotent" {
  run_wizard
  [ "$status" -eq 0 ]
  local conv_sum reg_sum
  conv_sum="$(cksum < "$CONV")"
  reg_sum="$(cksum < "$REG")"
  # draft-init is seeded from the instance: its content equals the recorded file
  DRAFT="$(bash "$ENTRY" draft-init 2>/dev/null)"
  [ -f "$DRAFT" ]
  [ "$(jq -S -c . "$DRAFT")" = "$(jq -S -c . "$CONV")" ]
  run --separate-stderr bash "$ENTRY" draft-diff --draft "$DRAFT" --format json
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r '(.added + .removed + .changed) | length')" = "0" ]
  # committing the untouched draft changes neither file, byte for byte
  run --separate-stderr bash "$ENTRY" commit --draft "$DRAFT"
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r '.ok')" = "true" ]
  [ "$(cksum < "$CONV")" = "$conv_sum" ]
  [ "$(cksum < "$REG")" = "$reg_sum" ]
}

@test "e2e 11: changing one answer on a re-run rewrites only that conv- item" {
  run_wizard
  [ "$status" -eq 0 ]
  local before_branching before_default
  before_branching="$(jq -S -c '.items[] | select(.id == "conv-branching")' "$REG")"
  before_default="$(jq -S -c '.items[:'"$(jq '.items | length' "$DEFAULT_REG")"']' "$REG")"
  DRAFT="$(bash "$ENTRY" draft-init 2>/dev/null)"
  bash "$ENTRY" draft-set naming --draft "$DRAFT" --source custom --summary "snake_case everywhere" \
    --value identifier_case=snake_case >/dev/null
  run --separate-stderr bash "$ENTRY" commit --draft "$DRAFT"
  [ "$status" -eq 0 ]
  assert_contains "$(jq -r '.items[] | select(.id == "conv-naming") | .text' "$REG")" "snake_case everywhere"
  [ "$(jq -S -c '.items[] | select(.id == "conv-branching")' "$REG")" = "$before_branching" ]
  [ "$(jq -S -c '.items[:'"$(jq '.items | length' "$DEFAULT_REG")"']' "$REG")" = "$before_default" ]
  [ "$(jq -r '[.items[] | select(.provenance.source == "convention")] | length' "$REG")" = "8" ]
}

@test "e2e 12: this repository's own project/configs is untouched (asserted again by teardown)" {
  run_wizard
  [ "$status" -eq 0 ]
  [ "$(find "$REAL_CONFIGS" -type f -exec cksum {} + | sort | cksum)" = "$REAL_SUM" ]
  [ ! -e "$REAL_CONFIGS/conventions.json" ]
}
