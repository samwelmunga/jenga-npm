#!/usr/bin/env bats
#
# Opt-in category support in skills/j-conventions/scripts/conventions-entry.sh (the write path of conventions.json).
#
# The schema's top-level `opt_in_categories` (today `commit-trace`) is recorded at categories.<id> like a core category,
# validated by the real validator before anything is written, and kept AFTER the core categories in written files. The
# listings (`categories`, `presets` for core ids) are unchanged. tests/conventions-entry.bats is deliberately not edited:
# this file only adds cases. The script's subcommands are draft-set / draft-skip / draft-show / draft-diff / commit and
# `show --category` (the board task calls them set / remove / show / diff).
#
# Every test works in a scratch project under $BATS_TEST_TMPDIR (JENGA_PROJECT_ROOT) with TMPDIR redirected; setup and
# teardown prove by checksum that this repository's project/configs/ is untouched.

bats_require_minimum_version 1.5.0
load helpers/assertions

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
ENTRY="$REPO_ROOT/skills/j-conventions/scripts/conventions-entry.sh"
VALIDATE_CONV="$REPO_ROOT/scripts/validate-conventions.sh"
SCHEMA="$REPO_ROOT/templates/conventions-schema.json"
PRESETS="$REPO_ROOT/templates/conventions-presets.json"
REAL_CONFIGS="$REPO_ROOT/project/configs"

setup() {
  REAL_SUM="$(find "$REAL_CONFIGS" -type f -exec cksum {} + | sort | cksum)"
  unset JENGA_CONVENTIONS_SCHEMA JENGA_CONVENTIONS_PRESETS JENGA_CONVENTIONS_GENERATOR JENGA_CONVENTIONS_CHECKLIST_MAP
  unset JENGA_CHECKLISTS_DEFAULT_FILE JENGA_CHECKLISTS_FILE
  SCRATCH_TMP="$BATS_TEST_TMPDIR/tmp"
  mkdir -p "$SCRATCH_TMP"
  export TMPDIR="$SCRATCH_TMP"
  PROJ="$BATS_TEST_TMPDIR/proj"
  CFG="$PROJ/project/configs"
  CONV="$CFG/conventions.json"
  mkdir -p "$CFG"
  printf '{}\n' > "$CFG/workflow.json"
  export JENGA_PROJECT_ROOT="$PROJ"
  DRAFT="$(bash "$ENTRY" draft-init 2>/dev/null)"
  [ -f "$DRAFT" ]
}

teardown() {
  [ "$(find "$REAL_CONFIGS" -type f -exec cksum {} + | sort | cksum)" = "$REAL_SUM" ]
}

entry() { run --separate-stderr bash "$ENTRY" "$@"; }

# set_trace [field=value...]: record commit-trace in the draft (must succeed).
set_trace() {
  local args=() v
  for v in "$@"; do args+=(--value "$v"); done
  bash "$ENTRY" draft-set commit-trace --draft "$DRAFT" --source custom --summary "Trailer trace" "${args[@]}" >/dev/null
}

set_branching() {
  bash "$ENTRY" draft-set branching --draft "$DRAFT" --source preset \
    --preset "$(jq -r '.categories.branching[0].id' "$PRESETS")" >/dev/null
}

@test "commit-trace: draft-set, commit, validate, show --category and draft-skip + commit remove it" {
  set_trace mode=trailer trailer_key=Jenga-Task
  entry draft-show --draft "$DRAFT" --category commit-trace
  [ "$status" -eq 0 ]
  [ "$(jq -r '.values.mode' <<<"$output")" = "trailer" ]
  entry commit --draft "$DRAFT"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.ok' <<<"$output")" = "true" ]
  run bash "$VALIDATE_CONV" "$CONV"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.categories["commit-trace"].values.trailer_key' "$CONV")" = "Jenga-Task" ]
  entry show --category commit-trace
  [ "$status" -eq 0 ]
  [ "$(jq -r '.summary' <<<"$output")" = "Trailer trace" ]
  # remove: seed a draft from the recorded file, skip the category, commit
  DRAFT="$(bash "$ENTRY" draft-init 2>/dev/null)"
  entry draft-skip commit-trace --draft "$DRAFT"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.changed' <<<"$output")" = "true" ]
  bash "$ENTRY" draft-set branching --draft "$DRAFT" --source preset --preset "$(jq -r '.categories.branching[0].id' "$PRESETS")" >/dev/null
  entry commit --draft "$DRAFT"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.categories | has("commit-trace")' "$CONV")" = "false" ]
  entry show --category commit-trace
  [ "$status" -eq 1 ]
}

@test "commit-trace: a reserved mode and a foreign trailer key are refused with the validator's message and the draft is unchanged" {
  local before
  before="$(cksum < "$DRAFT")"
  entry draft-set commit-trace --draft "$DRAFT" --source custom --summary x --value mode=ledger
  [ "$status" -eq 1 ]
  assert_contains "$stderr" "reserved"
  [ "$(cksum < "$DRAFT")" = "$before" ]
  entry draft-set commit-trace --draft "$DRAFT" --source custom --summary x --value trailer_key=Task-Id
  [ "$status" -eq 1 ]
  assert_contains "$stderr" "Jenga-Task"
  [ "$(cksum < "$DRAFT")" = "$before" ]
}

@test "commit-trace: check validates its fields through the real validator" {
  entry check commit-trace mode trailer
  [ "$status" -eq 0 ]
  [ "$(jq -r '.valid' <<<"$output")" = "true" ]
  entry check commit-trace mode topology
  [ "$status" -eq 0 ]
  [ "$(jq -r '.valid' <<<"$output")" = "false" ]
  assert_contains "$(jq -r '.reason' <<<"$output")" "reserved"
}

@test "commit-format: template fields are typed from the schema (a JSON boolean) and written" {
  entry draft-set commit-format --draft "$DRAFT" --source custom --summary "Ref first" \
    --value style=custom --value 'template={ref} {summary}' --value 'ref_pattern=[A-Z]+-[0-9]+' \
    --value apply_to_board_commits=true --value on_unresolved=fail
  [ "$status" -eq 0 ]
  [ "$(jq -r '.categories["commit-format"].values.apply_to_board_commits | type' "$DRAFT")" = "boolean" ]
  [ "$(jq -r '.categories["commit-format"].values.template' "$DRAFT")" = "{ref} {summary}" ]
  entry commit --draft "$DRAFT"
  [ "$status" -eq 0 ]
  run bash "$VALIDATE_CONV" "$CONV"
  [ "$status" -eq 0 ]
}

@test "commit-format: an invalid template, on_unresolved=park and a non-boolean flag are refused and nothing changes" {
  local before
  before="$(cksum < "$DRAFT")"
  entry draft-set commit-format --draft "$DRAFT" --source custom --summary x --value style=custom --value 'template={ref}'
  [ "$status" -eq 1 ]
  assert_contains "$stderr" "refused"
  [ "$(cksum < "$DRAFT")" = "$before" ]
  entry draft-set commit-format --draft "$DRAFT" --source custom --summary x --value style=custom \
    --value 'template={ref} {summary}' --value on_unresolved=park
  [ "$status" -eq 1 ]
  assert_contains "$stderr" "Phase 1"
  [ "$(cksum < "$DRAFT")" = "$before" ]
  entry draft-set commit-format --draft "$DRAFT" --source custom --summary x --value style=custom \
    --value 'template={ref} {summary}' --value apply_to_board_commits=yes
  [ "$status" -eq 1 ]
  [ "$(cksum < "$DRAFT")" = "$before" ]
  [ ! -f "$CONV" ]
}

@test "listings: categories (both formats) still list only the 9 core ids" {
  entry categories
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | wc -l | tr -d ' ')" = "9" ]
  case "$output" in *commit-trace*) return 1 ;; esac
  entry categories --format json
  [ "$status" -eq 0 ]
  [ "$(jq 'length' <<<"$output")" = "9" ]
  [ "$(jq '[.[].id] | index("commit-trace")' <<<"$output")" = "null" ]
}

@test "listings: presets for an opt-in category reports no presets without an error exit; a core id is unchanged" {
  entry presets commit-trace
  [ "$status" -eq 0 ]
  [ "$output" = "[]" ]
  assert_contains "$stderr" "no presets"
  entry presets branching
  [ "$status" -eq 0 ]
  [ "$(jq 'length' <<<"$output")" -ge 2 ]
}

@test "ordering: commit-trace follows the core categories in the written file, whichever was set first" {
  set_trace mode=trailer
  set_branching
  bash "$ENTRY" draft-set naming --draft "$DRAFT" --source preset --preset "$(jq -r '.categories.naming[0].id' "$PRESETS")" >/dev/null
  [ "$(jq -c '.categories | keys_unsorted' "$DRAFT")" = '["branching","naming","commit-trace"]' ]
  entry commit --draft "$DRAFT"
  [ "$status" -eq 0 ]
  [ "$(jq -c '.categories | keys_unsorted' "$CONV")" = '["branching","naming","commit-trace"]' ]
  [ "$(jq -r '.categories["commit-trace"].values.mode' "$CONV")" = "trailer" ]
  # exactly the recorded categories produce conv- items: the two core ones and, since the generator learned the opt-in entry, commit-trace
  [ "$(jq -r '[.items[] | select(.id | startswith("conv-")) | .id] | sort | join(",")' "$CFG/checklists.json")" = "conv-branching,conv-commit-trace,conv-naming" ]
}

@test "draft-diff reports an opt-in category after the core ones" {
  set_trace mode=trailer
  set_branching
  entry draft-diff --draft "$DRAFT" --format text
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | sed -n '1p' | cut -c1-12)" = "+ branching:" ]
  [ "$(printf '%s\n' "$output" | sed -n '2p' | cut -c1-16)" = "+ commit-trace: " ]
  entry draft-diff --draft "$DRAFT"
  [ "$(jq -c '.added' <<<"$output")" = '["branching","commit-trace"]' ]
}

@test "scripts over inline logic: bash 3.2 compatible, bash -n clean, no category id hardcoded" {
  run bash -n "$ENTRY"
  [ "$status" -eq 0 ]
  # code lines only: the script's own header comment names these constructs to say it avoids them
  run bash -c 'grep -vE "^[[:space:]]*#" "$1" | grep -nE "declare -A|mapfile|readarray|\$\{[A-Za-z_]+(,,|\^\^)"' _ "$ENTRY"
  [ "$status" -eq 1 ]
  run grep -c '"commit-trace"' "$ENTRY"
  [ "$output" = "0" ]
}

@test "unknown category: the message lists the core ids and then the opt-in id, on every path that reports it" {
  local core opt want
  core="$(jq -r '.categories | keys_unsorted | join(", ")' "$SCHEMA")"
  opt="$(jq -r '.opt_in_categories | keys_unsorted | join(", ")' "$SCHEMA")"
  want="(allowed: $core, $opt)"
  entry presets not-a-category
  [ "$status" -eq 1 ]
  assert_contains "$stderr" "$want"
  entry draft-set not-a-category --draft "$DRAFT" --source custom --summary x
  [ "$status" -eq 1 ]
  assert_contains "$stderr" "$want"
  entry check not-a-category field value
  [ "$status" -eq 0 ]
  assert_contains "$(jq -r '.reason' <<<"$output")" "$want"
  # the opt-in id comes last, after documentation-placement
  case "$want" in *"documentation-placement, commit-trace)") ;; *) return 1 ;; esac
}
