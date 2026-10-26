#!/usr/bin/env bats
#
# End-to-end proof that the commit-format pieces agree with each other on one opted-in project, and that the
# default-off path is untouched. It drives the real scripts together, in the order a project meets them:
#
#   skills/j-conventions/scripts/conventions-entry.sh  records conventions.json (draft-set, then commit)
#   scripts/validate-conventions.sh                    judges the file
#   scripts/commit-settings.sh                         opt-in rule and effective settings
#   scripts/commit-template.sh                         derives the subject check from the template
#   scripts/conventions-digest.sh                      the digest agents read
#   scripts/generate-convention-checklist.sh           the advisory checklist items
#
# Scenario A: opted in by template + apply_to_board_commits only (no commit-trace): the trace defaults apply.
# Scenario B: an explicit commit-trace (mode=trailer); a reserved mode is refused and nothing changes.
# Scenario C: default off (9 legacy categories plus a commit-trace entry, no opt-in flag): not opted in, and the
#             commit settings add nothing to the digest or the generator output.
# Scenario D: the hostile inputs are refused end to end and PWNED is never created.
#
# The board task calls the entry script's write command `set`; the real subcommands are draft-set, then commit.
# The reserved-mode refusal message is generic ("reserved for a later phase"): shipped files carry no board ids
# (tests/conventions-no-leak.bats), so this file asserts that wording.
#
# The final legacy-suite run (tests/conventions-legacy-regression.bats and the other tests/conventions-*.bats
# suites) is a separate bats invocation made by the tester; a nested suite run is never started from inside a test.
#
# Every test works in a scratch project under $BATS_TEST_TMPDIR aimed at with JENGA_PROJECT_ROOT and writes its
# drafts under a redirected TMPDIR. Nothing here writes this repository's project/configs/; setup and teardown
# prove it by checksum.

bats_require_minimum_version 1.5.0
load helpers/assertions

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
ENTRY="$REPO_ROOT/skills/j-conventions/scripts/conventions-entry.sh"
VALIDATE_CONV="$REPO_ROOT/scripts/validate-conventions.sh"
SETTINGS="$REPO_ROOT/scripts/commit-settings.sh"
TEMPLATE="$REPO_ROOT/scripts/commit-template.sh"
DIGEST="$REPO_ROOT/scripts/conventions-digest.sh"
GEN="$REPO_ROOT/scripts/generate-convention-checklist.sh"
PRESETS="$REPO_ROOT/templates/conventions-presets.json"
REAL_CONFIGS="$REPO_ROOT/project/configs"

OPT_COMMIT_LINE="Commit format (opt-in): "
OPT_EST_PREFIX="EST override: "
TRACE_WORDING="trace: trailer via 'Jenga-Task'"
RESERVED_WORDING="reserved for a later phase"

setup() {
  REAL_SUM="$(find "$REAL_CONFIGS" -type f -exec cksum {} + | sort | cksum)"
  unset JENGA_CONVENTIONS_SCHEMA JENGA_CONVENTIONS_PRESETS JENGA_CONVENTIONS_GENERATOR JENGA_CONVENTIONS_CHECKLIST_MAP
  unset JENGA_CONVENTIONS_DIGEST_MAX_LINES JENGA_CHECKLISTS_DEFAULT_FILE JENGA_CHECKLISTS_FILE
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
  DRAFT="$(bash "$ENTRY" draft-init 2>/dev/null)"
  [ -f "$DRAFT" ]
}

teardown() {
  [ "$(find "$REAL_CONFIGS" -type f -exec cksum {} + | sort | cksum)" = "$REAL_SUM" ]
}

# --- helpers ---------------------------------------------------------------------------------------------------

entry() { run --separate-stderr bash "$ENTRY" "$@"; }
digest() { run --separate-stderr bash "$DIGEST" "$@"; }
gen_print() { run --separate-stderr bash "$GEN" --print; }

# record_opt_in: the opted-in shape through the entry script's draft-set: a template and the opt-in flag on
# commit-format, plus two core categories so the digest and the generator have more than one thing to list.
record_opt_in() {
  bash "$ENTRY" draft-set commit-format --draft "$DRAFT" --source custom --summary "Ref first" \
    --value style=ref-first --value 'template={ref} {summary}' --value apply_to_board_commits=true >/dev/null
  bash "$ENTRY" draft-set branching --draft "$DRAFT" --source preset \
    --preset "$(jq -r '.categories.branching[0].id' "$PRESETS")" >/dev/null
  bash "$ENTRY" draft-set naming --draft "$DRAFT" --source preset \
    --preset "$(jq -r '.categories.naming[0].id' "$PRESETS")" >/dev/null
}

# commit_draft: the entry script's commit (validate, atomic write, generate, self-validate) must succeed.
commit_draft() {
  entry commit --draft "$DRAFT"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.ok' <<<"$output")" = "true" ]
}

# build_a: Scenario A's project: opted in, no commit-trace entry.
build_a() {
  record_opt_in
  commit_draft
}

# add_trace: re-seed a draft from the recorded file, add an explicit commit-trace entry and commit it.
add_trace() {
  DRAFT="$(bash "$ENTRY" draft-init 2>/dev/null)"
  [ -f "$DRAFT" ]
  bash "$ENTRY" draft-set commit-trace --draft "$DRAFT" --source custom --summary "Jenga-Task trailer" \
    --value mode=trailer >/dev/null
  commit_draft
}

# reg_item <id>: the registry item with that id, compact JSON (empty when absent).
reg_item() { jq -c --arg id "$1" '.items[] | select(.id == $id)' "$REG"; }

# legacy_nine: a valid conventions.json recording the 9 core categories, each from its first shipped preset.
legacy_nine() {
  jq '{conventions_version: 1, categories: (.categories | to_entries
        | map({key: .key, value: {source: "preset", preset: .value[0].id, summary: .value[0].label, values: .value[0].values}})
        | from_entries)}' "$PRESETS" > "$CONV"
}

# edit_conv <jq filter>: apply the filter to the recorded file.
edit_conv() {
  jq "$1" "$CONV" > "$CONV.tmp" && mv "$CONV.tmp" "$CONV"
}

# write_hostile <values json>: a hand-written conventions.json whose commit-format values are the given object,
# bypassing the entry script, so the downstream scripts are shown to refuse the file on their own.
write_hostile() {
  jq -n --argjson v "$1" \
    '{conventions_version: 1, categories: {"commit-format": {source: "custom", summary: "hostile", values: $v}}}' > "$CONV"
}

# refuse_draft_set <expected stderr fragment> <draft-set --value args...>: the entry script refuses the input with
# exit 1, names the reason, and leaves the draft byte-identical.
refuse_draft_set() {
  local frag="$1" before
  shift
  before="$(cksum < "$DRAFT")"
  entry draft-set commit-format --draft "$DRAFT" --source custom --summary hostile --value style=custom "$@"
  [ "$status" -eq 1 ]
  assert_contains "$stderr" "$frag"
  assert_contains "$stderr" "The draft was not changed."
  [ "$(cksum < "$DRAFT")" = "$before" ]
}

# --- Scenario A: opted in, trace defaults ----------------------------------------------------------------------

@test "A1: a template-and-flag-only project is written by the entry script, validates, and records no commit-trace" {
  build_a
  [ -f "$CONV" ]
  run bash "$VALIDATE_CONV" "$CONV"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.categories["commit-format"].values.template' "$CONV")" = "{ref} {summary}" ]
  [ "$(jq -r '.categories["commit-format"].values.apply_to_board_commits | type' "$CONV")" = "boolean" ]
  [ "$(jq -r '.categories | has("commit-trace")' "$CONV")" = "false" ]
  # the entry script's commit ran the generator into the scratch registry, never into this repository
  [ -f "$REG" ]
}

@test "A2: commit-settings.sh reports opted in and resolves the trace defaults to trailer and Jenga-Task" {
  build_a
  run --separate-stderr bash "$SETTINGS" opted-in
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  run --separate-stderr bash "$SETTINGS" show
  [ "$status" -eq 0 ]
  [ -z "$stderr" ]
  [ "$(printf '%s\n' "$output" | sed -n 's/^trace_mode=//p')" = "trailer" ]
  [ "$(printf '%s\n' "$output" | sed -n 's/^trailer_key=//p')" = "Jenga-Task" ]
  [ "$(printf '%s\n' "$output" | sed -n 's/^template=//p')" = "{ref} {summary}" ]
  [ "$(printf '%s\n' "$output" | sed -n 's/^on_unresolved=//p')" = "fail" ]
}

@test "A3: the digest prints the commit-settings line and the EST override line within 30 lines, for every --agent" {
  build_a
  local a
  for a in developer tester scrum-master commit; do
    digest --agent "$a"
    [ "$status" -eq 0 ]
    [ -z "$stderr" ]
    [ "$(printf '%s\n' "$output" | wc -l | tr -d ' ')" -le 30 ]
    assert_output_contains "$OPT_COMMIT_LINE"
    assert_output_contains "template '{ref} {summary}'"
    assert_output_contains "$TRACE_WORDING"
    assert_output_contains "$OPT_EST_PREFIX"
    # the unchanged EST line is still there, and the opt-in lines come after it
    [ "$(printf '%s\n' "$output" | tail -n 3 | head -n 1 | cut -c1-4)" = "EST:" ]
  done
}

@test "A4: the generator emits the advisory template variant of conv-commit-format and no commit-trace item" {
  build_a
  local item
  item="$(reg_item conv-commit-format)"
  [ -n "$item" ]
  [ "$(jq -r '.enforcement + "/" + .kind' <<<"$item")" = "advisory/judgment" ]
  assert_contains "$(jq -r '.text' <<<"$item")" "commit template {ref} {summary}: Ref first."
  assert_contains "$(jq -r '.text' <<<"$item")" "only when the project sets apply_to_board_commits to true"
  [ -z "$(reg_item conv-commit-trace)" ]
  # the same variant comes out of the generator's --print, for the file the entry script wrote
  gen_print
  [ "$status" -eq 0 ]
  [ "$(jq -r '.[] | select(.id == "conv-commit-format") | .enforcement' <<<"$output")" = "advisory" ]
  assert_contains "$(jq -r '.[] | select(.id == "conv-commit-format") | .text' <<<"$output")" "commit template {ref} {summary}"
  # nothing generated is stronger than confirm
  [ "$(jq -r '[.items[] | select(.id | startswith("conv-")) | .enforcement] | map(select(. == "block")) | length' "$REG")" = "0" ]
}

@test "A5: commit-template.sh match accepts ASD-001 add retry using the effective template and ref_pattern from show" {
  build_a
  local tpl pat
  run --separate-stderr bash "$SETTINGS" show
  [ "$status" -eq 0 ]
  tpl="$(printf '%s\n' "$output" | sed -n 's/^template=//p')"
  pat="$(printf '%s\n' "$output" | sed -n 's/^ref_pattern=//p')"
  [ "$tpl" = "{ref} {summary}" ]
  [ -n "$pat" ]
  run --separate-stderr bash "$TEMPLATE" match "$tpl" "ASD-001 add retry" --ref-pattern "$pat"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  # a subject with no ref, and an EST-form subject, do not fit the template
  run --separate-stderr bash "$TEMPLATE" match "$tpl" "add retry" --ref-pattern "$pat"
  [ "$status" -eq 1 ]
  [ "$output" = "no-match" ]
  run --separate-stderr bash "$TEMPLATE" match "$tpl" "task(E01_S01_T01): add retry" --ref-pattern "$pat"
  [ "$status" -eq 1 ]
  [ "$output" = "no-match" ]
}

# --- Scenario B: explicit trace setting ------------------------------------------------------------------------

@test "B1: an explicit commit-trace mode=trailer resolves to the same settings as the defaults and validates" {
  build_a
  run --separate-stderr bash "$SETTINGS" show
  [ "$status" -eq 0 ]
  local defaults="$output"
  add_trace
  run bash "$VALIDATE_CONV" "$CONV"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.categories["commit-trace"].values.mode' "$CONV")" = "trailer" ]
  run --separate-stderr bash "$SETTINGS" opted-in
  [ "$status" -eq 0 ]
  run --separate-stderr bash "$SETTINGS" show
  [ "$status" -eq 0 ]
  [ "$output" = "$defaults" ]
  [ "$(printf '%s\n' "$output" | sed -n 's/^trace_mode=//p')" = "trailer" ]
  [ "$(printf '%s\n' "$output" | sed -n 's/^trailer_key=//p')" = "Jenga-Task" ]
}

@test "B2: with an explicit commit-trace the digest keeps both opt-in lines and match still accepts the subject" {
  build_a
  add_trace
  digest --agent developer
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | wc -l | tr -d ' ')" -le 30 ]
  assert_output_contains "$OPT_COMMIT_LINE"
  assert_output_contains "$TRACE_WORDING"
  assert_output_contains "$OPT_EST_PREFIX"
  local tpl pat
  run --separate-stderr bash "$SETTINGS" show
  tpl="$(printf '%s\n' "$output" | sed -n 's/^template=//p')"
  pat="$(printf '%s\n' "$output" | sed -n 's/^ref_pattern=//p')"
  run --separate-stderr bash "$TEMPLATE" match "$tpl" "ASD-001 add retry" --ref-pattern "$pat"
  [ "$status" -eq 0 ]
}

@test "B3: the generator now also emits conv-commit-trace at advisory, and the template variant is unchanged" {
  build_a
  add_trace
  local item
  item="$(reg_item conv-commit-trace)"
  [ -n "$item" ]
  [ "$(jq -r '.enforcement + "/" + .kind + "/" + (.situations | join(","))' <<<"$item")" = "advisory/judgment/pre-commit" ]
  assert_contains "$(jq -r '.text' <<<"$item")" "Jenga-Task trailer"
  item="$(reg_item conv-commit-format)"
  [ "$(jq -r '.enforcement' <<<"$item")" = "advisory" ]
  assert_contains "$(jq -r '.text' <<<"$item")" "commit template {ref} {summary}"
  [ "$(jq -r '[.items[] | select(.id | startswith("conv-")) | .enforcement] | map(select(. == "block")) | length' "$REG")" = "0" ]
}

@test "B4: every reserved trace mode is refused by draft-set, by check and by the validator, and nothing changes" {
  build_a
  local m before_conv before_draft
  DRAFT="$(bash "$ENTRY" draft-init 2>/dev/null)"
  before_conv="$(cksum < "$CONV")"
  before_draft="$(cksum < "$DRAFT")"
  for m in external-key topology ledger; do
    entry draft-set commit-trace --draft "$DRAFT" --source custom --summary "reserved" --value "mode=$m"
    [ "$status" -eq 1 ]
    assert_contains "$stderr" "$RESERVED_WORDING"
    assert_contains "$stderr" "$m"
    [ "$(cksum < "$DRAFT")" = "$before_draft" ]
    [ "$(cksum < "$CONV")" = "$before_conv" ]
    entry check commit-trace mode "$m"
    [ "$status" -eq 0 ]
    [ "$(jq -r '.valid' <<<"$output")" = "false" ]
    assert_contains "$(jq -r '.reason' <<<"$output")" "$RESERVED_WORDING"
  done
  # a hand-written file that records a reserved mode fails validation too, and the settings script refuses it
  jq '.categories["commit-trace"] = {source: "custom", summary: "ledger", values: {mode: "ledger"}}' "$CONV" > "$BATS_TEST_TMPDIR/ledger.json"
  run --separate-stderr bash "$VALIDATE_CONV" "$BATS_TEST_TMPDIR/ledger.json"
  [ "$status" -eq 1 ]
  assert_contains "$stderr" "$RESERVED_WORDING"
  run --separate-stderr bash "$SETTINGS" --conventions "$BATS_TEST_TMPDIR/ledger.json" show
  [ "$status" -eq 3 ]
  # the recorded project is still the opted-in one it was
  [ "$(cksum < "$CONV")" = "$before_conv" ]
  run --separate-stderr bash "$SETTINGS" opted-in
  [ "$status" -eq 0 ]
}

# --- Scenario C: default off -----------------------------------------------------------------------------------

@test "C1: nine legacy categories plus a commit-trace entry and no opt-in flag is not opted in and prints no commit settings" {
  legacy_nine
  edit_conv '.categories["commit-trace"] = {source: "custom", summary: "Jenga-Task trailer", values: {mode: "trailer", trailer_key: "Jenga-Task"}}'
  run bash "$VALIDATE_CONV" "$CONV"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.categories["commit-format"].values | has("apply_to_board_commits")' "$CONV")" = "false" ]
  run --separate-stderr bash "$SETTINGS" opted-in
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  run --separate-stderr bash "$SETTINGS" show
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  local a
  for a in developer tester scrum-master commit; do
    digest --agent "$a"
    [ "$status" -eq 0 ]
    assert_output_not_contains "$OPT_COMMIT_LINE"
    assert_output_not_contains "$OPT_EST_PREFIX"
    assert_output_not_contains "trace:"
  done
}

@test "C2: the digest of that project is byte-identical to the digest without the commit-trace entry" {
  legacy_nine
  digest
  [ "$status" -eq 0 ]
  local without="$output"
  edit_conv '.categories["commit-trace"] = {source: "custom", summary: "Jenga-Task trailer", values: {mode: "trailer", trailer_key: "Jenga-Task"}}'
  digest
  [ "$status" -eq 0 ]
  [ "$output" = "$without" ]
}

@test "C3: the generator adds exactly one item for the recorded commit-trace entry and leaves the nine legacy items as they were" {
  legacy_nine
  gen_print
  [ "$status" -eq 0 ]
  local legacy="$output" legacy_ids
  legacy_ids="$(jq -c '[.[].id]' <<<"$legacy")"
  [ "$(jq 'length' <<<"$legacy")" = "9" ]
  # the legacy commit-format item is the non-board-only one
  assert_contains "$(jq -r '.[] | select(.id == "conv-commit-format") | .text' <<<"$legacy")" "This applies to non-board commits only"
  edit_conv '.categories["commit-trace"] = {source: "custom", summary: "Jenga-Task trailer", values: {mode: "trailer", trailer_key: "Jenga-Task"}}'
  gen_print
  [ "$status" -eq 0 ]
  [ "$(jq -c '[.[].id]' <<<"$output")" = "$(jq -c '. + ["conv-commit-trace"]' <<<"$legacy_ids")" ]
  # the nine legacy items are byte-identical (compact JSON), the added one is advisory
  [ "$(jq -c '.[0:9]' <<<"$output")" = "$(jq -c '.' <<<"$legacy")" ]
  [ "$(jq -r '.[9] | .id + "/" + .enforcement' <<<"$output")" = "conv-commit-trace/advisory" ]
}

@test "C4: a template without the flag, and the flag set to false, are not opted in either" {
  legacy_nine
  edit_conv '.categories["commit-format"].values = {style: "ref-first", template: "{ref} {summary}"}'
  run bash "$VALIDATE_CONV" "$CONV"
  [ "$status" -eq 0 ]
  run --separate-stderr bash "$SETTINGS" opted-in
  [ "$status" -eq 1 ]
  digest --agent developer
  [ "$status" -eq 0 ]
  assert_output_not_contains "$OPT_COMMIT_LINE"
  assert_output_not_contains "$OPT_EST_PREFIX"
  edit_conv '.categories["commit-format"].values = {style: "ref-first", template: "{ref} {summary}", apply_to_board_commits: false}'
  run --separate-stderr bash "$SETTINGS" opted-in
  [ "$status" -eq 1 ]
  run --separate-stderr bash "$SETTINGS" show
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  digest --agent developer
  assert_output_not_contains "$OPT_COMMIT_LINE"
  assert_output_not_contains "$OPT_EST_PREFIX"
}

# --- Scenario D: hostile inputs --------------------------------------------------------------------------------

@test "D1: the entry script refuses each hostile commit-format input with a reason, leaves the draft unchanged and writes nothing" {
  local orig="$PWD"
  cd "$PROJ"
  refuse_draft_set "invalid template" --value 'template=$(touch PWNED)'
  refuse_draft_set "single line" --value $'template={ref} {summary}\nx'
  refuse_draft_set "Phase 1 accepts only \"fail\"" --value 'template={ref} {summary}' --value on_unresolved=park
  refuse_draft_set "ref_source" --value 'template={ref} {summary}' --value ref_source=prompt
  refuse_draft_set "$RESERVED_WORDING" --value 'template={ref} {summary}' --value ref_source=prompt
  # nothing was recorded, so a commit has nothing hostile to write
  [ ! -f "$CONV" ]
  [ ! -e "$PROJ/PWNED" ]
  [ ! -e "$orig/PWNED" ]
  [ ! -e "$REPO_ROOT/PWNED" ]
  [ -z "$(find "$BATS_TEST_TMPDIR" -name PWNED)" ]
}

@test "D2: commit-template.sh refuses the hostile templates with exit 3 and never evaluates them" {
  cd "$PROJ"
  run --separate-stderr bash "$TEMPLATE" validate '$(touch PWNED)'
  [ "$status" -eq 3 ]
  assert_contains "$stderr" "not allowed in a template literal"
  run --separate-stderr bash "$TEMPLATE" derive '$(touch PWNED)'
  [ "$status" -eq 3 ]
  run --separate-stderr bash "$TEMPLATE" match '$(touch PWNED)' 'ASD-001 add retry'
  [ "$status" -eq 3 ]
  run --separate-stderr bash "$TEMPLATE" validate $'{ref} {summary}\nx'
  [ "$status" -eq 3 ]
  assert_contains "$stderr" "0x0a"
  [ ! -e "$PROJ/PWNED" ]
  [ -z "$(find "$BATS_TEST_TMPDIR" -name PWNED)" ]
}

@test "D3: a hand-written file with each hostile input is refused by the validator, the settings script, the digest and the generator" {
  local orig="$PWD"
  cd "$PROJ"
  local hostile=()
  hostile+=("$(jq -nc '{style: "s", template: "$(touch PWNED)", apply_to_board_commits: true}')")
  hostile+=("$(jq -nc --arg t $'{ref} {summary}\nx' '{style: "s", template: $t, apply_to_board_commits: true}')")
  hostile+=("$(jq -nc '{style: "s", template: "{ref} {summary}", apply_to_board_commits: true, on_unresolved: "park"}')")
  hostile+=("$(jq -nc '{style: "s", template: "{ref} {summary}", apply_to_board_commits: true, ref_source: "prompt"}')")
  local v
  for v in "${hostile[@]}"; do
    write_hostile "$v"
    run --separate-stderr bash "$VALIDATE_CONV" "$CONV"
    [ "$status" -eq 1 ]
    run --separate-stderr bash "$SETTINGS" opted-in
    [ "$status" -eq 3 ]
    run --separate-stderr bash "$SETTINGS" show
    [ "$status" -eq 3 ]
    [ -z "$output" ]
    digest --agent developer
    [ "$status" -eq 1 ]
    [ -z "$output" ]
    gen_print
    [ "$status" -eq 1 ]
    [ -z "$output" ]
  done
  [ ! -e "$PROJ/PWNED" ]
  [ ! -e "$orig/PWNED" ]
  [ ! -e "$REPO_ROOT/PWNED" ]
  [ -z "$(find "$BATS_TEST_TMPDIR" -name PWNED)" ]
}

@test "D4: a command-substitution ref_pattern is data: if it is accepted it is only ever matched, never executed" {
  local orig="$PWD"
  cd "$PROJ"
  entry draft-set commit-format --draft "$DRAFT" --source custom --summary hostile --value style=custom \
    --value 'template={ref} {summary}' --value 'ref_pattern=$(touch PWNED)' --value apply_to_board_commits=true
  if [ "$status" -eq 0 ]; then
    commit_draft
    run --separate-stderr bash "$SETTINGS" show
    local pat
    pat="$(printf '%s\n' "$output" | sed -n 's/^ref_pattern=//p')"
    [ "$pat" = '$(touch PWNED)' ]
    run --separate-stderr bash "$TEMPLATE" match '{ref} {summary}' 'ASD-001 add retry' --ref-pattern "$pat"
    [ "$status" -ne 0 ]
    digest --agent developer
    gen_print
  fi
  [ ! -e "$PROJ/PWNED" ]
  [ ! -e "$orig/PWNED" ]
  [ ! -e "$REPO_ROOT/PWNED" ]
  [ -z "$(find "$BATS_TEST_TMPDIR" -name PWNED)" ]
}
