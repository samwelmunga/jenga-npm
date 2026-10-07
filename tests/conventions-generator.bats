#!/usr/bin/env bats
#
# Coverage for scripts/generate-convention-checklist.sh and templates/conventions-checklist-map.json (E69_S03_T05).
#
# Contract under test: the script's own header comment (output contract, managed-item boundary, seeding, atomic
# write, exit codes) and the mapping file's _comment. Human write-up: project/documentation/project-conventions.md,
# section "Checklist generation".
#
# Every fixture is a scratch project built at test time under $BATS_TEST_TMPDIR (removed by bats after each test):
# its own project/configs/workflow.json, conventions.json and checklists.json. JENGA_PROJECT_ROOT aims the generator
# at it. Nothing here writes this repository's project/configs/; setup/teardown prove it by checksum.
#
# Streams: the generator writes its result (items or the one summary line) to stdout and every diagnostic to stderr.
# Tests that care which is which use `run --separate-stderr`.
#
# Exit codes pinned here: 0 ok / up to date, 1 refused / invalid / stale, 2 lock not acquired, 3 usage.

bats_require_minimum_version 1.5.0
load helpers/assertions

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
GEN="$REPO_ROOT/scripts/generate-convention-checklist.sh"
VALIDATE="$REPO_ROOT/scripts/validate-checklists.sh"
CHECKLIST="$REPO_ROOT/scripts/checklist.sh"
MAPFILE="$REPO_ROOT/templates/conventions-checklist-map.json"
SCHEMA="$REPO_ROOT/templates/conventions-schema.json"
PRESETS="$REPO_ROOT/templates/conventions-presets.json"
DEFAULT_REG="$REPO_ROOT/templates/checklists.json"
REAL_CONFIGS="$REPO_ROOT/project/configs"

setup() {
  REAL_SUM="$(find "$REAL_CONFIGS" -type f -exec cksum {} + | sort | cksum)"
  unset JENGA_CONVENTIONS_SCHEMA JENGA_CONVENTIONS_CHECKLIST_MAP JENGA_CHECKLISTS_DEFAULT_FILE JENGA_CHECKLISTS_FILE
  unset WITH_LOCK_TIMEOUT_SECONDS WITH_LOCK_POLL_SECONDS WITH_LOCK_STALE_SECONDS
  PROJ="$BATS_TEST_TMPDIR/proj"
  CFG="$PROJ/project/configs"
  REG="$CFG/checklists.json"
  CONV="$CFG/conventions.json"
  mkdir -p "$CFG"
  printf '{}\n' > "$CFG/workflow.json"
  export JENGA_PROJECT_ROOT="$PROJ"
}

teardown() {
  [ "$(find "$REAL_CONFIGS" -type f -exec cksum {} + | sort | cksum)" = "$REAL_SUM" ]
}

# --- fixture builders ----------------------------------------------------------------------------------------

# write_conv <jq filter over the categories object>: write $CONV from an object built by the filter.
write_conv() {
  jq -n "{conventions_version: 1, categories: ($1)}" > "$CONV"
}

# A custom entry: entry <summary> <values-json> -> JSON.
entry() {
  jq -n --arg s "$1" --argjson v "$2" '{source: "custom", summary: $s, values: $v}'
}

# conv_three: naming, testing, branching.
conv_three() {
  write_conv '{
    "naming": {source: "custom", summary: "camelCase identifiers", values: {identifier_case: "camelCase"}},
    "testing": {source: "custom", summary: "unit tests for new logic", values: {expectation: "unit tests"}},
    "branching": {source: "custom", summary: "short-lived feature branches", values: {model: "trunk-based"}}
  }'
}

# conv_all: all 9 categories, built from the first shipped preset of each.
conv_all() {
  jq '{conventions_version: 1, categories: (.categories | to_entries | map({key: .key, value: {source: "preset", preset: .value[0].id, summary: .value[0].label, values: .value[0].values}}) | from_entries)}' "$PRESETS" > "$CONV"
}

# conv_lint <lint command>: formatting-linting with that lint_command.
conv_lint() {
  write_conv "{\"formatting-linting\": {source: \"custom\", summary: \"lint it\", values: {approach: \"lint\", lint_command: $(jq -n --arg c "$1" '$c')}}}"
}

# reg_hand: a registry with an authored item, a suggested item and a conv- item with other provenance.
reg_hand() {
  jq -n '{
    checklist_version: 1,
    items: [
      {id: "hand-written", text: "A hand-written item.", situations: ["pre-commit"], kind: "judgment", enforcement: "advisory", tick_scope: "run"},
      {id: "agent-suggested", text: "An accepted agent suggestion.", situations: ["pre-task"], kind: "judgment", enforcement: "confirm", tick_scope: "run",
       provenance: {source: "suggested", suggested_by: "developer", origin: "precautionary", evidence: "scripts/x.sh exits 0 on failure", accepted_on: "2026-10-01"}},
      {id: "conv-lookalike", text: "Looks generated, is not.", situations: ["pre-commit"], kind: "judgment", enforcement: "advisory", tick_scope: "run",
       provenance: {source: "authored"}},
      {id: "conv-noprov", text: "No provenance at all.", situations: ["pre-commit"], kind: "judgment", enforcement: "advisory", tick_scope: "run"}
    ]
  }' > "$REG"
}

sum_of() { cksum < "$1"; }

# --- the mapping data -----------------------------------------------------------------------------------------

@test "map: parses and has exactly one entry for each category id in the schema" {
  run jq -e . "$MAPFILE"
  [ "$status" -eq 0 ]
  [ "$(jq -S -c '.categories | keys' "$MAPFILE")" = "$(jq -S -c '.categories | keys' "$SCHEMA")" ]
}

@test "map: the forbidden strength string appears nowhere in the file, in any case" {
  run grep -ic 'block' "$MAPFILE"
  [ "$output" = "0" ]
}

@test "map: every enforcement is advisory or confirm and every situation is a base phase (entries, fallbacks, alternatives)" {
  run jq -r '[.categories[] | (., .fallback?, .alternatives[]?) | select(. != null) | .enforcement // empty] | unique | join(",")' "$MAPFILE"
  [ "$status" -eq 0 ]
  assert_one_of "$output" "advisory" "confirm" "advisory,confirm"
  run jq -r '[.categories[] | .situations[]?] | unique | join(",")' "$MAPFILE"
  assert_one_of "$output" "pre-commit" "pre-task" "pre-commit,pre-task"
}

@test "map: item_id is conv-<category>, judgment entries are advisory, formatting-linting is machine/confirm with a fallback" {
  [ "$(jq -r '[.categories | to_entries[] | select(.value.item_id != ("conv-" + .key))] | length' "$MAPFILE")" = "0" ]
  [ "$(jq -r '[.categories | to_entries[] | select(.value.kind == "judgment" and .value.enforcement != "advisory")] | length' "$MAPFILE")" = "0" ]
  [ "$(jq -r '.categories["formatting-linting"] | .kind + "/" + .enforcement + "/" + (.fallback.kind) + "/" + (.fallback.enforcement)' "$MAPFILE")" = "machine/confirm/judgment/advisory" ]
}

@test "map: commit-format is judgment/advisory with a DISABLED confirm regex alternative, and its text states the scope and the EST exception" {
  [ "$(jq -r '.categories["commit-format"] | .kind + "/" + .enforcement' "$MAPFILE")" = "judgment/advisory" ]
  [ "$(jq -r '.categories["commit-format"].alternatives | length' "$MAPFILE")" = "1" ]
  [ "$(jq -r '.categories["commit-format"].alternatives[0] | (.enabled | tostring) + "/" + .enforcement + "/" + .kind' "$MAPFILE")" = "false/confirm/machine" ]
  run jq -r '.categories["commit-format"].text_template' "$MAPFILE"
  assert_output_contains "non-board commits only"
  assert_output_contains "EST naming"
  assert_output_contains "board commits"
}

@test "map: every {values.<field>} placeholder in a text template names a REQUIRED field of that category" {
  local cat field
  for cat in $(jq -r '.categories | keys[]' "$MAPFILE"); do
    for field in $(jq -r --arg c "$cat" '.categories[$c] | (.text_template, .fallback.text_template? // empty) | scan("\\{values\\.([a-z_]+)\\}") | .[0]' "$MAPFILE"); do
      [ "$(jq -r --arg c "$cat" --arg f "$field" '.categories[$c].values[$f].required' "$SCHEMA")" = "true" ]
    done
  done
}

# --- --print: shape ------------------------------------------------------------------------------------------

@test "--print: 3 recorded categories print exactly 3 conv- items with convention provenance, in schema order, exit 0" {
  conv_three
  run --separate-stderr bash "$GEN" --print
  [ "$status" -eq 0 ]
  [ -z "$stderr" ]
  [ "$(printf '%s' "$output" | jq 'length')" = "3" ]
  [ "$(printf '%s' "$output" | jq -r 'map(.id) | join(",")')" = "conv-branching,conv-naming,conv-testing" ]
  [ "$(printf '%s' "$output" | jq '[.[] | select(.provenance.source == "convention" and (.id | startswith("conv-")) and (.id == "conv-" + .provenance.category))] | length')" = "3" ]
}

@test "--print: 1 recorded category prints exactly 1 item whose text carries the convention's summary" {
  write_conv "{\"naming\": $(entry 'snake_case everywhere' '{"identifier_case": "snake_case"}')}"
  run bash "$GEN" --print
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq 'length')" = "1" ]
  [ "$(printf '%s' "$output" | jq -r '.[0].text')" = "New and renamed identifiers, files and types follow the project's naming convention: snake_case everywhere." ]
}

@test "--print: all 9 categories print 9 items, one per schema category, each valid in a registry" {
  conv_all
  run bash "$GEN" --print
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq 'length')" = "9" ]
  [ "$(printf '%s' "$output" | jq -c 'map(.provenance.category)')" = "$(jq -c '.categories | keys_unsorted' "$SCHEMA")" ]
  printf '%s' "$output" | jq '{checklist_version: 1, items: .}' > "$BATS_TEST_TMPDIR/all.json"
  run bash "$VALIDATE" "$BATS_TEST_TMPDIR/all.json"
  [ "$status" -eq 0 ]
}

@test "--print: item keys appear in the documented order" {
  conv_three
  run bash "$GEN" --print
  [ "$(printf '%s' "$output" | jq -c '.[0] | keys_unsorted')" = '["id","text","situations","kind","enforcement","tick_scope","provenance"]' ]
}

@test "--print: no conventions.json prints [] and exits 0" {
  run --separate-stderr bash "$GEN" --print
  [ "$status" -eq 0 ]
  [ "$output" = "[]" ]
}

@test "--print: a conventions.json with an empty categories prints [] and exits 0" {
  write_conv '{}'
  run bash "$GEN" --print
  [ "$status" -eq 0 ]
  [ "$output" = "[]" ]
}

@test "--print: an invalid conventions.json prints nothing on stdout, the validator's message on stderr, exit 1" {
  write_conv '{"naming": {}}'
  run --separate-stderr bash "$GEN" --print
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  assert_contains "$stderr" "categories.naming.source"
}

@test "--print: --conventions reads the named file instead of the configs one" {
  conv_three
  jq -n '{conventions_version: 1, categories: {naming: {source: "custom", summary: "x", values: {identifier_case: "x"}}}}' > "$BATS_TEST_TMPDIR/other.json"
  run bash "$GEN" --print --conventions "$BATS_TEST_TMPDIR/other.json"
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq 'length')" = "1" ]
}

@test "--print: two consecutive runs print byte-identical output" {
  conv_all
  bash "$GEN" --print > "$BATS_TEST_TMPDIR/a.json"
  bash "$GEN" --print > "$BATS_TEST_TMPDIR/b.json"
  run cmp "$BATS_TEST_TMPDIR/a.json" "$BATS_TEST_TMPDIR/b.json"
  [ "$status" -eq 0 ]
}

@test "usage: no mode flag combination, an unknown flag and a flag missing its value exit 3" {
  run bash "$GEN" --bogus
  [ "$status" -eq 3 ]
  run bash "$GEN" --print --check
  [ "$status" -eq 3 ]
  run bash "$GEN" --print --conventions
  [ "$status" -eq 3 ]
}

# --- strength rule -------------------------------------------------------------------------------------------

@test "strength: across all 9 categories every item is advisory or confirm, judgment ones advisory, never the forbidden strength" {
  conv_all
  run bash "$GEN" --print
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq '[.[] | select(.enforcement != "advisory" and .enforcement != "confirm")] | length')" = "0" ]
  [ "$(printf '%s' "$output" | jq '[.[] | select(.kind == "judgment" and .enforcement != "advisory")] | length')" = "0" ]
  run grep -ic 'block' <<<"$output"
  [ "$output" = "0" ]
}

@test "strength: commit-format is judgment/advisory even when a message_regex is recorded (the alternative is disabled)" {
  write_conv "{\"commit-format\": $(entry 'conventional' '{"style": "conventional-commits", "message_regex": "^(feat|fix): .+"}')}"
  run bash "$GEN" --print
  [ "$(printf '%s' "$output" | jq -r '.[0] | .kind + "/" + .enforcement + "/" + (has("verify") | tostring)')" = "judgment/advisory/false" ]
}

@test "strength: formatting-linting with a lint_command is machine/confirm; without one it falls back to judgment/advisory with no verify" {
  conv_lint "npm run lint"
  run bash "$GEN" --print
  [ "$(printf '%s' "$output" | jq -r '.[0] | .kind + "/" + .enforcement + "/" + .verify')" = "machine/confirm/bash -c 'npm run lint'" ]
  write_conv "{\"formatting-linting\": $(entry 'prettier by hand' '{"approach": "prettier"}')}"
  run bash "$GEN" --print
  [ "$(printf '%s' "$output" | jq -r '.[0] | .kind + "/" + .enforcement + "/" + (has("verify") | tostring)')" = "judgment/advisory/false" ]
}

@test "strength: an unreplaced <placeholder> lint_command counts as unset, so the item stays judgment/advisory with no verify" {
  conv_lint "<lint command>"
  run bash "$GEN" --print
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r '.[0] | .kind + "/" + .enforcement + "/" + (has("verify") | tostring)')" = "judgment/advisory/false" ]
  conv_lint "  <lint command> "
  run bash "$GEN" --print
  [ "$(printf '%s' "$output" | jq -r '.[0] | has("verify") | tostring')" = "false" ]
  conv_lint "npm run <script>"
  run bash "$GEN" --print
  [ "$(printf '%s' "$output" | jq -r '.[0] | .kind + "/" + .verify')" = "machine/bash -c 'npm run <script>'" ]
}

@test "strength: an entry's own advisory/confirm strength overrides the map's enforcement" {
  write_conv "{\"naming\": $(entry 'camel' '{"identifier_case": "camelCase"}' | jq '. + {strength: "confirm"}')}"
  run bash "$GEN" --print
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r '.[0].enforcement')" = "confirm" ]
}

@test "strength: a map that carries the forbidden strength is refused with exit 1 and no items on stdout" {
  conv_three
  jq '.categories.naming.enforcement = "block"' "$MAPFILE" > "$BATS_TEST_TMPDIR/hostile-map.json"
  JENGA_CONVENTIONS_CHECKLIST_MAP="$BATS_TEST_TMPDIR/hostile-map.json" run --separate-stderr bash "$GEN" --print
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  assert_contains "$stderr" "refusing"
  assert_contains "$stderr" "conv-naming"
}

@test "strength: a hostile fallback or alternative that yields the forbidden strength is refused too" {
  write_conv "{\"formatting-linting\": $(entry 'no lint command' '{"approach": "by hand"}')}"
  jq '.categories["formatting-linting"].fallback.enforcement = "block"' "$MAPFILE" > "$BATS_TEST_TMPDIR/hostile-map.json"
  JENGA_CONVENTIONS_CHECKLIST_MAP="$BATS_TEST_TMPDIR/hostile-map.json" run --separate-stderr bash "$GEN" --print
  [ "$status" -eq 1 ]
  [ -z "$output" ]
}

@test "strength: a convention entry strength of the forbidden value is refused (by the conventions validator) with exit 1" {
  write_conv "{\"naming\": $(entry 'camel' '{"identifier_case": "camelCase"}' | jq '. + {strength: "block"}')}"
  run --separate-stderr bash "$GEN" --print
  [ "$status" -eq 1 ]
  [ -z "$output" ]
}

@test "strength: the generator refuses an unquoted placeholder in a verify_template" {
  conv_lint "npm run lint"
  jq '.categories["formatting-linting"].verify_template = "bash -c {values.lint_command}"' "$MAPFILE" > "$BATS_TEST_TMPDIR/hostile-map.json"
  JENGA_CONVENTIONS_CHECKLIST_MAP="$BATS_TEST_TMPDIR/hostile-map.json" run --separate-stderr bash "$GEN" --print
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  assert_contains "$stderr" "unquoted placeholder"
}

# --- verify quoting ------------------------------------------------------------------------------------------

@test "quoting: a lint command with a quote and a semicolon cannot break out of the verify command (marker file proves it)" {
  local marker="$BATS_TEST_TMPDIR/PWNED"
  conv_lint "true' ; touch $marker ; '"
  run bash "$GEN" --print
  [ "$status" -eq 0 ]
  local verify
  verify="$(printf '%s' "$output" | jq -r '.[0].verify')"
  (cd "$PROJ" && bash -c "$verify") >/dev/null 2>&1 || true
  [ ! -e "$marker" ]
}

@test "quoting: a legitimate command containing single quotes and a semicolon still runs as written" {
  local marker="$BATS_TEST_TMPDIR/RAN"
  conv_lint "printf '%s' 'a b' > '$BATS_TEST_TMPDIR/out.txt'; touch '$marker'"
  run bash "$GEN" --print
  local verify
  verify="$(printf '%s' "$output" | jq -r '.[0].verify')"
  run bash -c "cd '$PROJ' && $verify"
  [ "$status" -eq 0 ]
  [ -e "$marker" ]
  [ "$(cat "$BATS_TEST_TMPDIR/out.txt")" = "a b" ]
}

@test "quoting: the verify command's exit status is the lint command's" {
  conv_lint "exit 7"
  run bash "$GEN" --print
  local verify
  verify="$(printf '%s' "$output" | jq -r '.[0].verify')"
  run bash -c "$verify"
  [ "$status" -eq 7 ]
}

@test "quoting: a summary containing placeholder-looking text is substituted once and never re-expanded" {
  write_conv "{\"naming\": $(entry 'uses {values.identifier_case} and {q:summary} literally' '{"identifier_case": "camelCase"}')}"
  run bash "$GEN" --print
  [ "$status" -eq 0 ]
  assert_output_contains "uses {values.identifier_case} and {q:summary} literally"
}

# --- write: idempotency, seeding, boundary -------------------------------------------------------------------

@test "write: no conventions and no registry creates nothing and exits 0" {
  run bash "$GEN"
  [ "$status" -eq 0 ]
  assert_output_contains "nothing to do"
  [ ! -e "$REG" ]
}

@test "write: an empty conventions.json and no registry also creates nothing" {
  write_conv '{}'
  run bash "$GEN"
  [ "$status" -eq 0 ]
  [ ! -e "$REG" ]
}

@test "seed: with no registry the default's 5 items are all carried and the generated items follow, and it validates" {
  conv_three
  run --separate-stderr bash "$GEN"
  [ "$status" -eq 0 ]
  assert_contains "$output" "3 added"
  assert_contains "$output" "seeded"
  [ "$(jq '.items | length' "$REG")" = "8" ]
  [ "$(jq -c '.items[0:5] | map(.id)' "$REG")" = "$(jq -c '.items | map(.id)' "$DEFAULT_REG")" ]
  [ "$(jq -c '.items[5:] | map(.id)' "$REG")" = '["conv-branching","conv-naming","conv-testing"]' ]
  run bash "$VALIDATE" "$REG"
  [ "$status" -eq 0 ]
}

@test "seed: the carried default items are unchanged in content" {
  conv_three
  bash "$GEN" >/dev/null
  [ "$(jq -S -c '.items[0:5]' "$REG")" = "$(jq -S -c '.items' "$DEFAULT_REG")" ]
}

@test "seed: the shipped default itself is never written" {
  local before
  before="$(sum_of "$DEFAULT_REG")"
  conv_three
  bash "$GEN" >/dev/null
  [ "$(sum_of "$DEFAULT_REG")" = "$before" ]
}

@test "idempotent: a second run leaves the registry byte-identical and reports zero changes" {
  conv_all
  bash "$GEN" >/dev/null
  local before
  before="$(sum_of "$REG")"
  run bash "$GEN"
  [ "$status" -eq 0 ]
  assert_output_contains "0 added, 0 updated, 0 removed, 9 unchanged"
  [ "$(sum_of "$REG")" = "$before" ]
  bash "$GEN" >/dev/null
  [ "$(sum_of "$REG")" = "$before" ]
}

@test "non-clobbering: authored, suggested and conv- lookalike items keep their content and relative order, byte for byte" {
  reg_hand
  jq -c '.items' "$REG" > "$BATS_TEST_TMPDIR/before-items.json"
  conv_three
  run bash "$GEN"
  [ "$status" -eq 0 ]
  assert_output_contains "3 added"
  [ "$(jq -c '.items[0:4]' "$REG")" = "$(cat "$BATS_TEST_TMPDIR/before-items.json")" ]
  [ "$(jq -c '.items[4:] | map(.id)' "$REG")" = '["conv-branching","conv-naming","conv-testing"]' ]
  run bash "$VALIDATE" "$REG"
  [ "$status" -eq 0 ]
}

@test "non-clobbering: a hand-edited registry in the repository's own format keeps its non-managed text byte for byte" {
  cp "$DEFAULT_REG" "$REG"
  local before
  before="$(sed -n '1,/"id": "tests-pass-before-release"/p' "$REG")"
  conv_three
  bash "$GEN" >/dev/null
  [ "$(head -n "$(printf '%s\n' "$before" | wc -l)" "$REG")" = "$before" ]
}

@test "non-clobbering: a conv- item with another provenance or none is never modified or removed when its category is removed" {
  reg_hand
  conv_three
  bash "$GEN" >/dev/null
  write_conv '{}'
  run bash "$GEN"
  [ "$status" -eq 0 ]
  assert_output_contains "3 removed"
  [ "$(jq -c '.items | map(.id)' "$REG")" = '["hand-written","agent-suggested","conv-lookalike","conv-noprov"]' ]
}

@test "non-clobbering: unknown top-level keys of the registry survive" {
  reg_hand
  jq '. + {situations: ["pre-deploy"], note: "keep me"}' "$REG" > "$REG.x" && mv "$REG.x" "$REG"
  conv_three
  bash "$GEN" >/dev/null
  [ "$(jq -c '[.situations, .note]' "$REG")" = '[["pre-deploy"],"keep me"]' ]
}

@test "removal: dropping one category removes only its conv- item on the next run" {
  conv_three
  bash "$GEN" >/dev/null
  jq 'del(.categories.naming)' "$CONV" > "$CONV.x" && mv "$CONV.x" "$CONV"
  run bash "$GEN"
  [ "$status" -eq 0 ]
  assert_output_contains "0 added, 0 updated, 1 removed, 2 unchanged"
  [ "$(jq -c '.items | map(.id)' "$REG" | jq -c '[.[] | select(startswith("conv-"))]')" = '["conv-branching","conv-testing"]' ]
  [ "$(jq '.items | length' "$REG")" = "7" ]
}

@test "update: a changed convention rewrites only its own item" {
  conv_three
  bash "$GEN" >/dev/null
  cp "$REG" "$BATS_TEST_TMPDIR/before.json"
  jq '.categories.naming.summary = "PascalCase types"' "$CONV" > "$CONV.x" && mv "$CONV.x" "$CONV"
  run bash "$GEN"
  [ "$status" -eq 0 ]
  assert_output_contains "0 added, 1 updated, 0 removed, 2 unchanged"
  [ "$(jq -r '.items[] | select(.id == "conv-naming") | .text' "$REG")" = "New and renamed identifiers, files and types follow the project's naming convention: PascalCase types." ]
  [ "$(jq -S -c '[.items[] | select(.id != "conv-naming")]' "$REG")" = "$(jq -S -c '[.items[] | select(.id != "conv-naming")]' "$BATS_TEST_TMPDIR/before.json")" ]
}

@test "update: a stale managed item that the user hand-raised is rewritten back to the generated strength" {
  conv_three
  bash "$GEN" >/dev/null
  jq '(.items[] | select(.id == "conv-naming") | .enforcement) = "confirm"' "$REG" > "$REG.x" && mv "$REG.x" "$REG"
  run bash "$GEN"
  assert_output_contains "1 updated"
  [ "$(jq -r '.items[] | select(.id == "conv-naming") | .enforcement' "$REG")" = "advisory" ]
}

@test "collision: a rendered id that matches a non-managed item exits 1 naming it and changes nothing" {
  reg_hand
  jq '.items += [{id: "conv-naming", text: "Mine, not generated.", situations: ["pre-commit"], kind: "judgment", enforcement: "advisory", tick_scope: "run"}]' "$REG" > "$REG.x" && mv "$REG.x" "$REG"
  conv_three
  local before
  before="$(sum_of "$REG")"
  run --separate-stderr bash "$GEN"
  [ "$status" -eq 1 ]
  assert_contains "$stderr" "conv-naming"
  assert_contains "$stderr" "collision"
  [ "$(sum_of "$REG")" = "$before" ]
}

# --- validation failure and locking --------------------------------------------------------------------------

@test "validation failure: an invalid merged candidate leaves the live file byte-identical, no candidate file, exit 1" {
  jq -n '{checklist_version: 1, items: [{id: "broken", text: "x", situations: ["pre-commit"], kind: "judgment", enforcement: "nope", tick_scope: "run"}]}' > "$REG"
  conv_three
  local before
  before="$(sum_of "$REG")"
  run --separate-stderr bash "$GEN"
  [ "$status" -eq 1 ]
  assert_contains "$stderr" "bad enforcement"
  assert_contains "$stderr" "live registry was not touched"
  [ "$(sum_of "$REG")" = "$before" ]
  [ "$(ls "$CFG" | grep -c candidate || true)" = "0" ]
}

@test "validation failure: a registry that is not JSON exits 1, is untouched and leaves no candidate" {
  printf 'not json\n' > "$REG"
  conv_three
  local before
  before="$(sum_of "$REG")"
  run --separate-stderr bash "$GEN"
  [ "$status" -eq 1 ]
  [ "$(sum_of "$REG")" = "$before" ]
  [ "$(ls "$CFG" | grep -c candidate || true)" = "0" ]
}

@test "validation failure: --check also reports an invalid candidate as exit 1 without writing" {
  jq -n '{checklist_version: 1, items: [{id: "broken", text: "x", situations: ["pre-commit"], kind: "judgment", enforcement: "nope", tick_scope: "run"}]}' > "$REG"
  conv_three
  local before
  before="$(sum_of "$REG")"
  run bash "$GEN" --check
  [ "$status" -eq 1 ]
  [ "$(sum_of "$REG")" = "$before" ]
}

@test "lock: with the registry lock held the generator exits non-zero and writes nothing" {
  jq -n '{checklist_version: 1, items: []}' > "$REG"
  conv_three
  local before
  before="$(sum_of "$REG")"
  bash "$REPO_ROOT/scripts/with-lock.sh" "$REG" -- sleep 8 &
  local holder=$!
  sleep 1
  WITH_LOCK_TIMEOUT_SECONDS=1 run --separate-stderr bash "$GEN"
  local rc=$status
  kill "$holder" 2>/dev/null || true
  wait "$holder" 2>/dev/null || true
  [ "$rc" -eq 2 ]
  [ "$(sum_of "$REG")" = "$before" ]
  assert_contains "$stderr" "failed to acquire lock"
}

@test "lock: the lock directory is released after a successful run" {
  conv_three
  bash "$GEN" >/dev/null
  [ ! -e "$REG.lock.d" ]
}

# --- --check -------------------------------------------------------------------------------------------------

@test "--check: exit 1 before the first write, 0 once up to date, 1 again after conventions.json changes, and it never writes" {
  conv_three
  run bash "$GEN" --check
  [ "$status" -eq 1 ]
  [ ! -e "$REG" ]
  bash "$GEN" >/dev/null
  local before
  before="$(sum_of "$REG")"
  run bash "$GEN" --check
  [ "$status" -eq 0 ]
  jq '.categories.testing.summary = "changed"' "$CONV" > "$CONV.x" && mv "$CONV.x" "$CONV"
  run bash "$GEN" --check
  [ "$status" -eq 1 ]
  [ "$(sum_of "$REG")" = "$before" ]
}

@test "--check: with nothing recorded and no registry it is up to date (exit 0)" {
  run bash "$GEN" --check
  [ "$status" -eq 0 ]
  [ ! -e "$REG" ]
}

# --- the checker accepts the result --------------------------------------------------------------------------

@test "checker: scripts/checklist.sh list pre-commit lists the generated items with their enforcement, unmodified" {
  conv_all
  bash "$GEN" >/dev/null
  run bash "$VALIDATE" "$REG"
  [ "$status" -eq 0 ]
  run --separate-stderr env JENGA_CHECKLISTS_FILE="$REG" JENGA_CHECKLIST_STATE_DIR="$BATS_TEST_TMPDIR/state" \
    bash "$CHECKLIST" list pre-commit
  [ "$status" -eq 0 ]
  assert_contains "$output" "conv-commit-format"
  assert_contains "$output" "conv-formatting-linting"
  assert_contains "$output" "advisory"
  local ids
  ids="$(jq -r '.items[] | select(.situations | index("pre-commit")) | .id' "$REG")"
  local id
  for id in $ids; do
    assert_contains "$output" "$id"
  done
}

@test "checker: a machine conv- item reaches the checker as a confirm-strength item" {
  conv_lint "npm run lint"
  bash "$GEN" >/dev/null
  run --separate-stderr env JENGA_CHECKLISTS_FILE="$REG" JENGA_CHECKLIST_STATE_DIR="$BATS_TEST_TMPDIR/state" \
    bash "$CHECKLIST" list pre-commit
  [ "$status" -eq 0 ]
  assert_contains "$output" "conv-formatting-linting"
  assert_contains "$output" "confirm"
}

@test "repository: this project's own registry is not touched by the suite (checksum, also asserted in teardown)" {
  conv_three
  bash "$GEN" >/dev/null
  [ "$(find "$REAL_CONFIGS" -type f -exec cksum {} + | sort | cksum)" = "$REAL_SUM" ]
}
