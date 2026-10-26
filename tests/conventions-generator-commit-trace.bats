#!/usr/bin/env bats
#
# Coverage for the commit-template variant and the commit-trace item of the convention checklist generator
# (the opt_in_categories and opt_in_alternatives sections of templates/conventions-checklist-map.json, and the
# one-line ordering/lookup support in scripts/generate-convention-checklist.sh).
#
# New file on purpose: tests/conventions-generator.bats and tests/conventions-legacy-regression.bats keep their
# assertions untouched, and between them prove that a project recording neither a template nor commit-trace gets the
# same bytes as before. This file proves the new paths and that no new path is stronger than confirm.
#
# Every fixture is a scratch project under $BATS_TEST_TMPDIR; nothing here writes this repository's project/configs/.

bats_require_minimum_version 1.5.0
load helpers/assertions

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
GEN="$REPO_ROOT/scripts/generate-convention-checklist.sh"
VALIDATE="$REPO_ROOT/scripts/validate-checklists.sh"
MAPFILE="$REPO_ROOT/templates/conventions-checklist-map.json"
SCHEMA="$REPO_ROOT/templates/conventions-schema.json"
PRESETS="$REPO_ROOT/templates/conventions-presets.json"
REAL_CONFIGS="$REPO_ROOT/project/configs"

# The commit-format entry's own text_template exactly as it was before the template variant existed.
LEGACY_COMMIT_FORMAT_TEXT="My commit message follows the project's commit convention: {summary}. This applies to non-board commits only; EST naming (task(E##_S##_T##):, story(...) and epic(...)) stays required for board commits."

setup() {
  REAL_SUM="$(find "$REAL_CONFIGS" -type f -exec cksum {} + | sort | cksum)"
  unset JENGA_CONVENTIONS_SCHEMA JENGA_CONVENTIONS_CHECKLIST_MAP JENGA_CHECKLISTS_DEFAULT_FILE JENGA_CHECKLISTS_FILE
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

write_conv() {
  jq -n "{conventions_version: 1, categories: ($1)}" > "$CONV"
}

# conv_all: all 9 core categories, built from the first shipped preset of each.
conv_all() {
  jq '{conventions_version: 1, categories: (.categories | to_entries | map({key: .key, value: {source: "preset", preset: .value[0].id, summary: .value[0].label, values: .value[0].values}}) | from_entries)}' "$PRESETS" > "$CONV"
}

# conv_full: the 9 core categories plus commit-trace, and a template on commit-format.
conv_full() {
  conv_all
  jq '.categories["commit-format"].values.template = "{ref} {summary}"
      | .categories["commit-trace"] = {source: "custom", summary: "Jenga-Task trailer", values: {mode: "trailer", trailer_key: "Jenga-Task"}}' \
    "$CONV" > "$CONV.tmp" && mv "$CONV.tmp" "$CONV"
}

item() { printf '%s' "$output" | jq -c --arg id "$1" '.[] | select(.id == $id)'; }

# --- the map ---------------------------------------------------------------------------------------------------

@test "ct map: the existing commit-format entry is untouched and the core table still equals the schema categories" {
  [ "$(jq -r '.categories["commit-format"].text_template' "$MAPFILE")" = "$LEGACY_COMMIT_FORMAT_TEXT" ]
  [ "$(jq -r '.categories["commit-format"].alternatives | length' "$MAPFILE")" = "1" ]
  [ "$(jq -S -c '.categories | keys' "$MAPFILE")" = "$(jq -S -c '.categories | keys' "$SCHEMA")" ]
}

@test "ct map: conv-commit-trace is a pre-commit judgment/advisory entry with no verify_template and no machine claim" {
  [ "$(jq -r '.opt_in_categories["commit-trace"] | .item_id + "/" + .kind + "/" + .enforcement + "/" + .tick_scope + "/" + (.situations | join(","))' "$MAPFILE")" = "conv-commit-trace/judgment/advisory/run/pre-commit" ]
  [ "$(jq -r '.opt_in_categories["commit-trace"] | has("verify_template")' "$MAPFILE")" = "false" ]
  [ "$(jq -r '.opt_in_categories["commit-trace"].text_template | contains("{summary}")' "$MAPFILE")" = "true" ]
  [ "$(jq -r '.opt_in_categories["commit-trace"].text_template | test("verified|machine"; "i")' "$MAPFILE")" = "false" ]
}

@test "ct map: the template variant requires template, is advisory judgment, and states the template and the board-commit condition" {
  [ "$(jq -r '.opt_in_alternatives["commit-format"] | length' "$MAPFILE")" = "1" ]
  [ "$(jq -r '.opt_in_alternatives["commit-format"][0] | (.requires | join(",")) + "/" + .kind + "/" + .enforcement + "/" + (.enabled | tostring)' "$MAPFILE")" = "template/judgment/advisory/true" ]
  run jq -r '.opt_in_alternatives["commit-format"][0].text_template' "$MAPFILE"
  assert_output_contains "{values.template}"
  assert_output_contains "apply_to_board_commits"
  assert_output_contains "only when"
}

@test "ct map: nothing in the new sections is stronger than confirm and the new sections hold no board id outside metadata" {
  [ "$(jq -r '[.opt_in_categories[], (.opt_in_alternatives[][])] | map(.enforcement) | unique | join(",")' "$MAPFILE")" = "advisory" ]
  [ "$(jq -r '[(.opt_in_categories, .opt_in_alternatives) | .. | strings | select(test("E[0-9]{2}_S[0-9]{2}"))] | length' "$MAPFILE")" = "0" ]
}

# --- the template variant --------------------------------------------------------------------------------------

@test "ct variant: a recorded template selects the advisory template variant naming the template and the board-commit condition" {
  write_conv '{"commit-format": {source: "custom", summary: "ticket-first", values: {style: "ticket", template: "{ref} {summary}"}}}'
  run --separate-stderr bash "$GEN" --print
  [ "$status" -eq 0 ]
  [ -z "$stderr" ]
  [ "$(printf '%s' "$output" | jq 'length')" = "1" ]
  [ "$(printf '%s' "$output" | jq -r '.[0] | .id + "/" + .kind + "/" + .enforcement + "/" + (has("verify") | tostring)')" = "conv-commit-format/judgment/advisory/false" ]
  text="$(printf '%s' "$output" | jq -r '.[0].text')"
  assert_contains "$text" "commit template {ref} {summary}: ticket-first."
  assert_contains "$text" "only when the project sets apply_to_board_commits to true"
  [ "$(printf '%s' "$output" | jq -r '.[0].situations | join(",")')" = "pre-commit" ]
}

@test "ct variant: without a template the item is the legacy item, with the legacy text, whatever else commit-format records" {
  write_conv '{"commit-format": {source: "custom", summary: "conventional", values: {style: "conventional", message_regex: "^(feat|fix): .+"}}}'
  run --separate-stderr bash "$GEN" --print
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r '.[0].text')" = "My commit message follows the project's commit convention: conventional. This applies to non-board commits only; EST naming (task(E##_S##_T##):, story(...) and epic(...)) stays required for board commits." ]
}

# --- commit-trace ----------------------------------------------------------------------------------------------

@test "ct trace: a recorded commit-trace produces conv-commit-trace, advisory, at pre-commit, with convention provenance" {
  write_conv '{"commit-trace": {source: "custom", summary: "Jenga-Task trailer", values: {mode: "trailer", trailer_key: "Jenga-Task"}}}'
  run --separate-stderr bash "$GEN" --print
  [ "$status" -eq 0 ]
  [ -z "$stderr" ]
  [ "$(printf '%s' "$output" | jq -r '.[0] | .id + "/" + .kind + "/" + .enforcement + "/" + .tick_scope + "/" + (.situations | join(",")) + "/" + .provenance.source + "/" + .provenance.category')" = "conv-commit-trace/judgment/advisory/run/pre-commit/convention/commit-trace" ]
  [ "$(printf '%s' "$output" | jq -r '.[0] | has("verify")')" = "false" ]
  assert_contains "$(printf '%s' "$output" | jq -r '.[0].text')" "Jenga-Task trailer"
}

@test "ct trace: commit-trace comes after the core categories, in schema order" {
  conv_full
  run --separate-stderr bash "$GEN" --print
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -c 'map(.provenance.category)')" = "$(jq -c '(.categories | keys_unsorted) + (.opt_in_categories | keys_unsorted)' "$SCHEMA")" ]
}

# --- strength --------------------------------------------------------------------------------------------------

@test "ct strength: across the 9 core categories plus commit-trace and a template, no item is block, judgment items are advisory" {
  conv_full
  run --separate-stderr bash "$GEN" --print
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq 'length')" = "10" ]
  [ "$(printf '%s' "$output" | jq -r '[.[] | select(.enforcement != "advisory" and .enforcement != "confirm")] | length')" = "0" ]
  [ "$(printf '%s' "$output" | jq -r '[.[] | select(.kind == "judgment" and .enforcement != "advisory")] | length')" = "0" ]
  [ "$(printf '%s' "$output" | jq -r '[.[] | select(.id == "conv-commit-trace" or .id == "conv-commit-format")] | map(.enforcement) | unique | join(",")')" = "advisory" ]
}

@test "ct strength: a hostile opt-in section carrying the forbidden strength is refused, exit 1, no items on stdout" {
  jq '.opt_in_categories["commit-trace"].enforcement = "block"' "$MAPFILE" > "$BATS_TEST_TMPDIR/hostile-map.json"
  write_conv '{"commit-trace": {source: "custom", summary: "t", values: {}}}'
  JENGA_CONVENTIONS_CHECKLIST_MAP="$BATS_TEST_TMPDIR/hostile-map.json" run --separate-stderr bash "$GEN" --print
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  jq '.opt_in_alternatives["commit-format"][0].enforcement = "block"' "$MAPFILE" > "$BATS_TEST_TMPDIR/hostile-map2.json"
  write_conv '{"commit-format": {source: "custom", summary: "t", values: {style: "s", template: "{ref} {summary}"}}}'
  JENGA_CONVENTIONS_CHECKLIST_MAP="$BATS_TEST_TMPDIR/hostile-map2.json" run --separate-stderr bash "$GEN" --print
  [ "$status" -eq 1 ]
  [ -z "$output" ]
}

@test "ct strength: a user strength of block on commit-trace is still rejected by the validator before anything is generated" {
  write_conv '{"commit-trace": {source: "custom", summary: "t", strength: "block", values: {}}}'
  run --separate-stderr bash "$GEN" --print
  [ "$status" -eq 1 ]
  [ -z "$output" ]
}

# --- the registry ----------------------------------------------------------------------------------------------

@test "ct registry: the generated items (template variant and commit-trace included) validate and are written, idempotently" {
  conv_full
  run bash "$GEN"
  [ "$status" -eq 0 ]
  run bash "$VALIDATE" "$REG"
  [ "$status" -eq 0 ]
  [ "$(jq -r '[.items[] | select(.id | startswith("conv-")) | .id] | contains(["conv-commit-trace", "conv-commit-format"])' "$REG")" = "true" ]
  [ "$(jq -r '[.items[] | select(.id | startswith("conv-")) | .enforcement] | map(select(. == "block")) | length' "$REG")" = "0" ]
  before="$(cksum < "$REG")"
  run bash "$GEN"
  [ "$status" -eq 0 ]
  [ "$(cksum < "$REG")" = "$before" ]
  run bash "$GEN" --check
  [ "$status" -eq 0 ]
}

@test "ct registry: removing commit-trace and the template removes the trace item and restores the legacy commit-format text" {
  conv_full
  run bash "$GEN"
  [ "$status" -eq 0 ]
  conv_all
  run bash "$GEN"
  [ "$status" -eq 0 ]
  [ "$(jq -r '[.items[] | select(.id == "conv-commit-trace")] | length' "$REG")" = "0" ]
  assert_contains "$(jq -r '.items[] | select(.id == "conv-commit-format") | .text' "$REG")" "follows the project's commit convention"
}

# --- default-off -----------------------------------------------------------------------------------------------

@test "ct default-off: the map additions are not reached by the 9 core categories (output equals a map without the new sections)" {
  conv_all
  run --separate-stderr bash "$GEN" --print
  [ "$status" -eq 0 ]
  with_new="$output"
  jq 'del(.opt_in_categories, .opt_in_alternatives)' "$MAPFILE" > "$BATS_TEST_TMPDIR/old-map.json"
  JENGA_CONVENTIONS_CHECKLIST_MAP="$BATS_TEST_TMPDIR/old-map.json" run --separate-stderr bash "$GEN" --print
  [ "$status" -eq 0 ]
  [ "$output" = "$with_new" ]
}

@test "ct default-off: an old-style map with no new sections still works for a legacy project and fails clearly for commit-trace" {
  jq 'del(.opt_in_categories, .opt_in_alternatives)' "$MAPFILE" > "$BATS_TEST_TMPDIR/old-map.json"
  write_conv '{"commit-trace": {source: "custom", summary: "t", values: {}}}'
  JENGA_CONVENTIONS_CHECKLIST_MAP="$BATS_TEST_TMPDIR/old-map.json" run --separate-stderr bash "$GEN" --print
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  assert_contains "$stderr" "no map entry for category commit-trace"
}
