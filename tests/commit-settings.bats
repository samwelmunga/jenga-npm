#!/usr/bin/env bats
#
# E79_S03_T06: scripts/commit-settings.sh is the one place that decides whether a project is opted in to the
# commit-format convention and what its effective commit settings are.
#
# What this pins (one named case per acceptance criterion, plus the contract around them):
#   - not opted in is silent on the legacy path: no file, an empty `categories`, a commit-format entry without a
#     template, a template without the flag, a trace entry on its own;
#   - opted in: `opted-in` exits 0 and `show` prints the seven effective settings in a fixed order, taking every
#     unrecorded value from the schema (so an opted-in project with no trace entry resolves to the trailer defaults);
#   - a recorded value wins over the schema default; hostile recorded values stay data;
#   - an invalid or malformed file exits 3 with the validator's lines on stderr and never exits 0 or 1;
#   - the defaults are read from the schema at run time (JENGA_CONVENTIONS_SCHEMA points at a scratch schema) and the
#     script holds no copy of them (grep checks), no quoted category id, no dynamic evaluation, no bash 4 feature;
#   - the schema's subject budget default agrees with the budget commit-template.sh derives with;
#   - usage errors, --help, file location (flag over environment), read-only behaviour and determinism.
#
# The script is always run as `bash <script>`, so these cases do not depend on the file's executable bit.
# Everything the cases create lives under $BATS_TEST_TMPDIR; nothing here writes this repository's project/configs/.

bats_require_minimum_version 1.5.0
load helpers/assertions

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
SCRIPT="$REPO_ROOT/scripts/commit-settings.sh"
TEMPLATE_SCRIPT="$REPO_ROOT/scripts/commit-template.sh"
SCHEMA="$REPO_ROOT/templates/conventions-schema.json"
REAL_CONFIGS="$REPO_ROOT/project/configs"

setup() {
  REAL_SUM="$(find "$REAL_CONFIGS" -type f -exec cksum {} + | sort | cksum)"
  unset JENGA_CONVENTIONS_SCHEMA
  PROJ="$BATS_TEST_TMPDIR/proj"
  CFG="$PROJ/project/configs"
  CONV="$CFG/conventions.json"
  mkdir -p "$CFG"
  printf '{}\n' > "$CFG/workflow.json"
  export JENGA_PROJECT_ROOT="$PROJ"
  cd "$BATS_TEST_TMPDIR" || return 1
}

teardown() {
  [ "$(find "$REAL_CONFIGS" -type f -exec cksum {} + | sort | cksum)" = "$REAL_SUM" ]
}

# --- helpers ---------------------------------------------------------------------------------------------------

# cs <args...>: run the script, keeping stdout in $output and stderr in $stderr.
cs() { run --separate-stderr bash "$SCRIPT" "$@"; }

# base_json: an opted-in conventions.json with only the minimum recorded.
base_json() {
  cat <<'JSON'
{
  "conventions_version": 1,
  "categories": {
    "commit-format": {
      "source": "custom",
      "summary": "ref first",
      "values": { "style": "ref-first", "template": "{ref} {summary}", "apply_to_board_commits": true }
    }
  }
}
JSON
}

# write_conv <jq-filter>: write the base file, transformed by the filter, to $CONV.
write_conv() {
  base_json | jq "$1" > "$CONV"
}

# template_default_budget: the subject budget commit-template.sh derives with when none is given (a template that is
# only {summary} has no prefix, so the summary budget is the whole budget).
template_default_budget() {
  bash "$TEMPLATE_SCRIPT" derive '{summary}' | sed -n 's/^max_summary_length=//p'
}

# kv <key>: the value of key in $output (split at the first "="), or nothing.
kv() {
  printf '%s\n' "$output" | while IFS= read -r line; do
    case "$line" in
      "$1="*) printf '%s' "${line#*=}"; break ;;
    esac
  done
}

# --- not opted in: the silent legacy path ----------------------------------------------------------------------

@test "no conventions.json: opted-in exits 1 and show prints nothing and exits 0" {
  [ ! -e "$CONV" ]
  cs opted-in
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  [ -z "$stderr" ]
  cs show
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ -z "$stderr" ]
}

@test "an empty categories object is not opted in, silently" {
  printf '{"conventions_version":1,"categories":{}}\n' > "$CONV"
  cs opted-in
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  [ -z "$stderr" ]
  cs show
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ -z "$stderr" ]
}

@test "commit-format without a template is not opted in" {
  write_conv 'del(.categories["commit-format"].values.template) | del(.categories["commit-format"].values.apply_to_board_commits)'
  cs opted-in
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  cs show
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "a legacy commit-format entry (style and message_regex only) is not opted in" {
  printf '%s\n' '{"conventions_version":1,"categories":{"commit-format":{"source":"custom","summary":"conventional","values":{"style":"conventional","message_regex":"^(feat|fix): ."}}}}' > "$CONV"
  cs opted-in
  [ "$status" -eq 1 ]
  cs show
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "a template with apply_to_board_commits false is not opted in" {
  write_conv '.categories["commit-format"].values.apply_to_board_commits = false'
  cs opted-in
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  cs show
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "a template with apply_to_board_commits absent is not opted in" {
  write_conv 'del(.categories["commit-format"].values.apply_to_board_commits)'
  cs opted-in
  [ "$status" -eq 1 ]
  cs show
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "a commit-trace entry on its own does not opt a project in" {
  write_conv 'del(.categories["commit-format"].values.apply_to_board_commits)
    | .categories["commit-trace"] = {"source":"custom","summary":"trailer","values":{"mode":"trailer","trailer_key":"Jenga-Task"}}'
  cs opted-in
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  cs show
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "a trace entry beside a template with the flag false is still not opted in" {
  write_conv '.categories["commit-format"].values.apply_to_board_commits = false
    | .categories["commit-trace"] = {"source":"custom","summary":"trailer","values":{"mode":"trailer"}}'
  cs opted-in
  [ "$status" -eq 1 ]
}

@test "the opt-in flag without a template is a file the validator rejects, so exit 3 and never opted in" {
  write_conv 'del(.categories["commit-format"].values.template)'
  cs opted-in
  [ "$status" -eq 3 ]
  assert_contains "$stderr" "requires template"
  [ -z "$output" ]
}

@test "an unresolvable configs path (JENGA_PROJECT_ROOT without a registry) is not opted in, silently" {
  mkdir -p "$BATS_TEST_TMPDIR/empty-root"
  JENGA_PROJECT_ROOT="$BATS_TEST_TMPDIR/empty-root" cs opted-in
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  [ -z "$stderr" ]
  JENGA_PROJECT_ROOT="$BATS_TEST_TMPDIR/empty-root" cs show
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ -z "$stderr" ]
}

# --- opted in --------------------------------------------------------------------------------------------------

@test "opted in with nothing else recorded: opted-in exits 0 with no output" {
  write_conv '.'
  cs opted-in
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ -z "$stderr" ]
}

@test "opted in with no commit-trace entry: show resolves the trailer defaults and every other default from the schema" {
  write_conv '.'
  cs show
  [ "$status" -eq 0 ]
  [ -z "$stderr" ]
  [ "$(kv trace_mode)" = "trailer" ]
  [ "$(kv trailer_key)" = "Jenga-Task" ]
  [ "$(kv template)" = "{ref} {summary}" ]
  [ "$(kv ref_source)" = "$(jq -r '.categories["commit-format"].values.ref_source.default' "$SCHEMA")" ]
  [ "$(kv ref_pattern)" = "$(jq -r '.categories["commit-format"].values.ref_pattern.default' "$SCHEMA")" ]
  [ "$(kv on_unresolved)" = "$(jq -r '.categories["commit-format"].values.on_unresolved.default' "$SCHEMA")" ]
  [ "$(kv subject_max_length)" = "$(template_default_budget)" ]
}

@test "show prints exactly the seven settings, in the documented order, one key=value line each" {
  write_conv '.'
  cs show
  [ "$status" -eq 0 ]
  keys="$(printf '%s\n' "$output" | sed 's/=.*//' | tr '\n' ' ')"
  [ "$keys" = "template ref_source ref_pattern on_unresolved trace_mode trailer_key subject_max_length " ]
  [ "$(printf '%s\n' "$output" | wc -l | tr -d ' ')" = "7" ]
}

@test "a recorded ref_pattern wins over the schema default" {
  write_conv '.categories["commit-format"].values.ref_pattern = "PRJ-[0-9]+"'
  cs show
  [ "$status" -eq 0 ]
  [ "$(kv ref_pattern)" = "PRJ-[0-9]+" ]
  [ "$(kv ref_source)" = "$(jq -r '.categories["commit-format"].values.ref_source.default' "$SCHEMA")" ]
}

@test "recorded ref_source, subject_max_length, on_unresolved, and a recorded trace entry are all reported" {
  write_conv '.categories["commit-format"].values += {"ref_source":"external_refs","subject_max_length":90,"on_unresolved":"fail"}
    | .categories["commit-trace"] = {"source":"custom","summary":"trailer","values":{"mode":"trailer","trailer_key":"Jenga-Task"}}'
  cs show
  [ "$status" -eq 0 ]
  [ "$(kv ref_source)" = "external_refs" ]
  [ "$(kv subject_max_length)" = "90" ]
  [ "$(kv on_unresolved)" = "fail" ]
  [ "$(kv trace_mode)" = "trailer" ]
  [ "$(kv trailer_key)" = "Jenga-Task" ]
}

@test "a commit-trace entry with an empty values object still resolves the trace defaults" {
  write_conv '.categories["commit-trace"] = {"source":"custom","summary":"trailer","values":{}}'
  cs show
  [ "$status" -eq 0 ]
  [ "$(kv trace_mode)" = "trailer" ]
  [ "$(kv trailer_key)" = "Jenga-Task" ]
}

@test "a message_regex recorded beside the template does not change the effective settings" {
  write_conv '.categories["commit-format"].values.message_regex = "^(feat|fix): ."'
  cs show
  [ "$status" -eq 0 ]
  [ "$(kv template)" = "{ref} {summary}" ]
  assert_not_contains "$output" "message_regex"
}

@test "a hostile-looking recorded ref_pattern stays data: it is printed, nothing runs, no file appears" {
  write_conv '.categories["commit-format"].values.ref_pattern = "[A-Z]+=[0-9]+|\\$\\(touch PWNED\\)"'
  cs show
  [ "$status" -eq 0 ]
  [ "$(kv ref_pattern)" = '[A-Z]+=[0-9]+|\$\(touch PWNED\)' ]
  [ ! -e "$BATS_TEST_TMPDIR/PWNED" ]
  [ ! -e "$PROJ/PWNED" ]
  [ ! -e "$REPO_ROOT/PWNED" ]
}

@test "a value containing '=' is split at the first '=' only" {
  write_conv '.categories["commit-format"].values.ref_pattern = "K=[0-9]+"'
  cs show
  [ "$status" -eq 0 ]
  assert_output_contains "ref_pattern=K=[0-9]+"
  [ "$(kv ref_pattern)" = "K=[0-9]+" ]
}

# --- invalid files ---------------------------------------------------------------------------------------------

@test "an invalid conventions file: opted-in exits 3 with the validator's lines on stderr, never 0" {
  write_conv '.categories["commit-format"].values.template = "{ref} {summary} $(id)"'
  cs opted-in
  [ "$status" -eq 3 ]
  [ -z "$output" ]
  assert_contains "$stderr" "invalid template"
  assert_contains "$stderr" "$CONV"
}

@test "an invalid conventions file: show exits 3, prints nothing on stdout, validator lines on stderr" {
  write_conv '.categories["commit-format"].values.on_unresolved = "ignore"'
  cs show
  [ "$status" -eq 3 ]
  [ -z "$output" ]
  assert_contains "$stderr" "on_unresolved"
}

@test "malformed JSON exits 3 for both subcommands" {
  printf '{ not json' > "$CONV"
  cs opted-in
  [ "$status" -eq 3 ]
  cs show
  [ "$status" -eq 3 ]
  [ -z "$output" ]
}

@test "an invalid file is rejected even when it would otherwise be not opted in" {
  printf '%s\n' '{"conventions_version":1,"categories":{"nonsense":{}}}' > "$CONV"
  cs opted-in
  [ "$status" -eq 3 ]
  assert_contains "$stderr" "nonsense"
}

# --- defaults come from the schema -----------------------------------------------------------------------------

@test "defaults are read from JENGA_CONVENTIONS_SCHEMA: a scratch schema with different defaults is reflected" {
  jq '.categories["commit-format"].values.ref_pattern.default = "[a-z]+-[0-9]+"
      | .categories["commit-format"].values.ref_source.default = "external_refs"
      | .categories["commit-format"].values.subject_max_length.default = 64' "$SCHEMA" > "$BATS_TEST_TMPDIR/schema.json"
  write_conv '.'
  JENGA_CONVENTIONS_SCHEMA="$BATS_TEST_TMPDIR/schema.json" cs show
  [ "$status" -eq 0 ]
  [ "$(kv ref_pattern)" = "[a-z]+-[0-9]+" ]
  [ "$(kv ref_source)" = "external_refs" ]
  [ "$(kv subject_max_length)" = "64" ]
  # and the real schema still gives the real defaults
  cs show
  [ "$(kv ref_source)" = "$(jq -r '.categories["commit-format"].values.ref_source.default' "$SCHEMA")" ]
}

@test "the trace defaults follow the schema too (a scratch schema with another allowed mode default)" {
  jq '.opt_in_categories["commit-trace"].values.mode.enum = ["trailer", "note"]
      | .opt_in_categories["commit-trace"].values.mode.default = "note"' "$SCHEMA" > "$BATS_TEST_TMPDIR/schema.json"
  write_conv '.'
  JENGA_CONVENTIONS_SCHEMA="$BATS_TEST_TMPDIR/schema.json" cs show
  [ "$status" -eq 0 ]
  [ "$(kv trace_mode)" = "note" ]
  [ "$(kv trailer_key)" = "Jenga-Task" ]
}

@test "a setting with neither a recorded value nor a schema default fails loudly (exit 3), naming it" {
  jq 'del(.categories["commit-format"].values.ref_pattern.default)' "$SCHEMA" > "$BATS_TEST_TMPDIR/schema.json"
  write_conv '.'
  JENGA_CONVENTIONS_SCHEMA="$BATS_TEST_TMPDIR/schema.json" cs show
  [ "$status" -eq 3 ]
  [ -z "$output" ]
  assert_contains "$stderr" "ref_pattern"
  # the same project with a recorded pattern resolves fine against that schema
  write_conv '.categories["commit-format"].values.ref_pattern = "PRJ-[0-9]+"'
  JENGA_CONVENTIONS_SCHEMA="$BATS_TEST_TMPDIR/schema.json" cs show
  [ "$status" -eq 0 ]
}

@test "subject_max_length has no schema default (its field spec is pinned); the unrecorded value is the template script's own budget" {
  [ "$(jq -c '.categories["commit-format"].values.subject_max_length' "$SCHEMA")" = '{"type":"integer","required":false}' ]
  write_conv '.'
  cs show
  [ "$status" -eq 0 ]
  budget="$(template_default_budget)"
  [ -n "$budget" ]
  [ "$(kv subject_max_length)" = "$budget" ]
  # the same number is what a real template's prefix plus summary budget add up to when no --max-length is given
  run --separate-stderr bash "$TEMPLATE_SCRIPT" derive '{ref} {summary}'
  [ "$status" -eq 0 ]
  prefix="$(printf '%s\n' "$output" | sed -n 's/^prefix_length=//p')"
  summary="$(printf '%s\n' "$output" | sed -n 's/^max_summary_length=//p')"
  [ "$((prefix + summary))" -eq "$budget" ]
}

@test "a recorded subject_max_length wins over the template script's budget" {
  write_conv '.categories["commit-format"].values.subject_max_length = 100'
  cs show
  [ "$(kv subject_max_length)" = "100" ]
}

@test "a schema default for subject_max_length, if one is ever declared, wins over the template script's budget" {
  jq '.categories["commit-format"].values.subject_max_length.default = 64' "$SCHEMA" > "$BATS_TEST_TMPDIR/schema.json"
  write_conv '.'
  JENGA_CONVENTIONS_SCHEMA="$BATS_TEST_TMPDIR/schema.json" cs show
  [ "$status" -eq 0 ]
  [ "$(kv subject_max_length)" = "64" ]
}

@test "the schema's default for every printed setting passes the validator (a project opted in on defaults is valid)" {
  write_conv '.'
  run --separate-stderr bash "$REPO_ROOT/scripts/validate-conventions.sh" "$CONV"
  [ "$status" -eq 0 ]
}

# --- script text -----------------------------------------------------------------------------------------------

@test "the script holds no literal copy of the defaults (trailer key, the default ref source name, the default ref pattern)" {
  run grep -c -E 'Jenga-Task|chain|\[A-Z\]\[A-Z0-9\]' "$SCRIPT"
  [ "$output" = "0" ]
}

@test "the script carries no quoted category id: the categories are found by the schema field they declare" {
  run grep -c -E '"(commit-format|commit-trace|branching|naming|code-comments|formatting-linting|testing|file-layout|language-tooling|documentation-placement)"' "$SCRIPT"
  [ "$output" = "0" ]
}

@test "the script never evaluates or sources anything (comments excluded)" {
  grep -v '^[[:space:]]*#' "$SCRIPT" > "$BATS_TEST_TMPDIR/code.sh"
  run grep -c -E '(^|[^A-Za-z_])(eval|source)([[:space:]]|$)|^[[:space:]]*\.[[:space:]]+[^ ]' "$BATS_TEST_TMPDIR/code.sh"
  [ "$output" = "0" ]
}

@test "the script passes bash -n and uses no bash 4 feature (comments excluded)" {
  run bash -n "$SCRIPT"
  [ "$status" -eq 0 ]
  grep -v '^[[:space:]]*#' "$SCRIPT" > "$BATS_TEST_TMPDIR/code.sh"
  run grep -c -E 'declare -A|typeset -A|mapfile|readarray|,,\}|\^\^\}|\|&|&>>' "$BATS_TEST_TMPDIR/code.sh"
  [ "$output" = "0" ]
}

@test "the script is executable and answers --help on stdout with exit 0" {
  [ -x "$SCRIPT" ]
  cs --help
  [ "$status" -eq 0 ]
  assert_output_contains "opted-in"
  assert_output_contains "show"
  [ -z "$stderr" ]
}

# --- usage -----------------------------------------------------------------------------------------------------

@test "usage errors exit 2: no subcommand, an unknown subcommand, an unknown option, two subcommands, --conventions without a file" {
  cs
  [ "$status" -eq 2 ]
  cs frobnicate
  [ "$status" -eq 2 ]
  cs --bogus show
  [ "$status" -eq 2 ]
  cs show opted-in
  [ "$status" -eq 2 ]
  cs show --conventions
  [ "$status" -eq 2 ]
  cs --conventions "$CONV" --conventions "$CONV" show
  [ "$status" -eq 2 ]
  [ -z "$output" ]
}

# --- file location, read-only, determinism ---------------------------------------------------------------------

@test "--conventions overrides the project's conventions.json" {
  printf '{"conventions_version":1,"categories":{}}\n' > "$CONV"
  base_json > "$BATS_TEST_TMPDIR/other.json"
  cs opted-in
  [ "$status" -eq 1 ]
  cs --conventions "$BATS_TEST_TMPDIR/other.json" opted-in
  [ "$status" -eq 0 ]
  cs --conventions "$BATS_TEST_TMPDIR/other.json" show
  [ "$status" -eq 0 ]
  [ "$(kv trace_mode)" = "trailer" ]
}

@test "--conventions naming an absent file is not opted in" {
  cs --conventions "$BATS_TEST_TMPDIR/does-not-exist.json" opted-in
  [ "$status" -eq 1 ]
  cs --conventions "$BATS_TEST_TMPDIR/does-not-exist.json" show
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "JENGA_PROJECT_ROOT selects the project when no --conventions is given" {
  write_conv '.'
  mkdir -p "$BATS_TEST_TMPDIR/other/project/configs"
  printf '{}\n' > "$BATS_TEST_TMPDIR/other/project/configs/workflow.json"
  JENGA_PROJECT_ROOT="$BATS_TEST_TMPDIR/other" cs opted-in
  [ "$status" -eq 1 ]
  cs opted-in
  [ "$status" -eq 0 ]
}

@test "the script is read-only (the project tree is unchanged) and deterministic" {
  write_conv '.'
  before="$(find "$PROJ" -type f -exec cksum {} + | sort | cksum)"
  cs show
  first="$output"
  cs show
  [ "$output" = "$first" ]
  cs opted-in
  after="$(find "$PROJ" -type f -exec cksum {} + | sort | cksum)"
  [ "$before" = "$after" ]
  [ "$(find "$PROJ" -type f | wc -l | tr -d ' ')" = "2" ]
}
