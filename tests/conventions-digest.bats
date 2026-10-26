#!/usr/bin/env bats
#
# Coverage for scripts/conventions-digest.sh (E69_S05_T01/T02): the compact conventions digest that the developer,
# tester, scrum-master and j-commit consume instead of parsing conventions.json themselves.
#
# Contract under test: the script's own header comment. Cases: nothing recorded prints nothing and exits 0; the
# 30-line cap and the omission note; --agent ordering; an invalid file exits 1 with empty stdout; determinism;
# a <placeholder>-only value is never printed; the script writes nothing.
#
# EST proof (the story's required "test or documented check", data level): a hostile commit-format convention
# cannot remove or contradict the digest's EST line, and the generated conv-commit-format checklist text states the
# non-board-only scope and the EST exception. The instruction-level half is asserted in conventions-commit.bats.
#
# Every test builds its own scratch project under $BATS_TEST_TMPDIR (a project/configs/workflow.json and its own
# conventions.json) and aims the code at it with JENGA_PROJECT_ROOT. Nothing here writes this repository's own
# project/configs/; teardown proves it by checksum.

bats_require_minimum_version 1.5.0
load helpers/assertions

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
DIGEST="$REPO_ROOT/scripts/conventions-digest.sh"
GENERATOR="$REPO_ROOT/scripts/generate-convention-checklist.sh"
REAL_CONFIGS="$REPO_ROOT/project/configs"

setup() {
  REAL_SUM="$(find "$REAL_CONFIGS" -type f -exec cksum {} + | sort | cksum)"
  unset JENGA_CONVENTIONS_SCHEMA JENGA_CONVENTIONS_CHECKLIST_MAP JENGA_CONVENTIONS_DIGEST_MAX_LINES
  PROJ="$BATS_TEST_TMPDIR/proj"
  CFG="$PROJ/project/configs"
  CONV="$CFG/conventions.json"
  mkdir -p "$CFG"
  printf '{}\n' > "$CFG/workflow.json"
  export JENGA_PROJECT_ROOT="$PROJ"
}

teardown() {
  [ "$(find "$REAL_CONFIGS" -type f -exec cksum {} + | sort | cksum)" = "$REAL_SUM" ]
}

# --- fixtures --------------------------------------------------------------------------------------------------

# all_nine: a valid conventions.json recording every one of the 9 categories.
all_nine() {
  cat > "$CONV" <<'JSON'
{
  "conventions_version": 1,
  "categories": {
    "commit-format": { "source": "custom", "summary": "conventional commits", "values": { "style": "conventional" } },
    "branching": { "source": "custom", "summary": "trunk based", "values": { "model": "trunk" } },
    "naming": { "source": "custom", "summary": "camelCase identifiers", "values": { "identifier_case": "camelCase" } },
    "code-comments": { "source": "custom", "summary": "comment the why", "values": { "policy": "why-only" } },
    "formatting-linting": { "source": "custom", "summary": "eslint and prettier", "values": { "approach": "eslint", "lint_command": "npx eslint ." } },
    "testing": { "source": "custom", "summary": "unit tests required", "values": { "expectation": "unit" } },
    "file-layout": { "source": "custom", "summary": "src and tests dirs", "values": { "layout": "src-tests" } },
    "language-tooling": { "source": "custom", "summary": "node 20 with npm", "values": { "version_policy": "pinned" } },
    "documentation-placement": { "source": "custom", "summary": "docs in docs/", "values": { "policy": "docs-dir" } }
  }
}
JSON
}

# hostile_commit_format: a commit-format convention that, taken literally, would reject EST board commit subjects.
hostile_commit_format() {
  cat > "$CONV" <<'JSON'
{
  "conventions_version": 1,
  "categories": {
    "commit-format": {
      "source": "custom",
      "summary": "all commits must look like feat: x",
      "values": { "style": "no prefixes", "message_regex": "^(feat|fix): [a-z]" }
    }
  }
}
JSON
}

digest() { run --separate-stderr bash "$DIGEST" "$@"; }

line_count() { printf '%s\n' "$1" | wc -l | tr -d ' '; }

# --- nothing recorded ------------------------------------------------------------------------------------------

@test "no conventions.json prints nothing and exits 0" {
  [ ! -e "$CONV" ]
  digest
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ -z "$stderr" ]
}

@test "an empty categories object prints nothing and exits 0" {
  printf '{"conventions_version":1,"categories":{}}\n' > "$CONV"
  digest
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "every --agent value prints nothing when nothing is recorded" {
  for a in developer tester scrum-master commit; do
    run --separate-stderr bash "$DIGEST" --agent "$a"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
  done
}

@test "an unresolvable explicit --conventions path (absent file) prints nothing and exits 0" {
  digest --conventions "$BATS_TEST_TMPDIR/does-not-exist.json"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# --- the cap ---------------------------------------------------------------------------------------------------

@test "all 9 categories fit in at most 30 lines and drop nothing by default" {
  all_nine
  digest
  [ "$status" -eq 0 ]
  n="$(line_count "$output")"
  [ "$n" -le 30 ]
  assert_output_not_contains "omitted"
  for c in commit-format branching naming code-comments formatting-linting testing file-layout language-tooling documentation-placement; do
    assert_output_contains "$c: "
    assert_output_contains "conv-$c"
  done
}

@test "a lowered cap truncates lowest-priority categories first and ends with the omission note" {
  all_nine
  export JENGA_CONVENTIONS_DIGEST_MAX_LINES=8
  digest --agent developer
  [ "$status" -eq 0 ]
  n="$(line_count "$output")"
  [ "$n" -le 8 ]
  last="$(printf '%s\n' "$output" | tail -n 1)"
  assert_starts_with "$last" "... "
  assert_contains "$last" "more categories omitted"
  # header + 4 category lines + 2 fixed + the note; 9 recorded, so 5 are omitted
  assert_contains "$last" "... 5 more"
  # the developer's first categories survive; a low-priority one is the first to go
  assert_output_contains "naming: "
  assert_output_contains "code-comments: "
  assert_output_not_contains "documentation-placement: "
  # the fixed lines are never what gets truncated
  assert_output_contains "Precedence:"
  assert_output_contains "EST:"
}

@test "lines are capped in length and a long summary ends in an ellipsis" {
  long="$(printf 'x%.0s' $(seq 1 400))"
  jq -n --arg s "$long" '{conventions_version:1,categories:{naming:{source:"custom",summary:$s,values:{identifier_case:"camelCase"}}}}' > "$CONV"
  digest
  [ "$status" -eq 0 ]
  while IFS= read -r l; do
    [ "${#l}" -le 220 ]
  done <<EOF
$output
EOF
  assert_output_contains "..."
}

# --- --agent ordering ------------------------------------------------------------------------------------------

# position <category>: 1-based line number of "<category>: " in $output.
position() { printf '%s\n' "$output" | grep -n "^$1: " | head -n 1 | cut -d: -f1; }

@test "--agent developer lists naming, code-comments, formatting-linting before the others" {
  all_nine
  digest --agent developer
  [ "$status" -eq 0 ]
  pn="$(position naming)"; pc="$(position code-comments)"; pf="$(position formatting-linting)"
  [ "$pn" -lt "$pc" ]
  [ "$pc" -lt "$pf" ]
  [ "$pf" -lt "$(position commit-format)" ]
  [ "$pf" -lt "$(position testing)" ]
  [ "$pf" -lt "$(position branching)" ]
}

@test "--agent tester lists testing and formatting-linting first" {
  all_nine
  digest --agent tester
  [ "$status" -eq 0 ]
  [ "$(position testing)" -lt "$(position formatting-linting)" ]
  [ "$(position formatting-linting)" -lt "$(position commit-format)" ]
  [ "$(position formatting-linting)" -lt "$(position naming)" ]
}

@test "--agent scrum-master lists documentation-placement, file-layout, branching first" {
  all_nine
  digest --agent scrum-master
  [ "$status" -eq 0 ]
  [ "$(position documentation-placement)" -lt "$(position file-layout)" ]
  [ "$(position file-layout)" -lt "$(position branching)" ]
  [ "$(position branching)" -lt "$(position commit-format)" ]
}

@test "--agent commit lists commit-format and branching first" {
  all_nine
  digest --agent commit
  [ "$status" -eq 0 ]
  [ "$(position commit-format)" -lt "$(position branching)" ]
  [ "$(position branching)" -lt "$(position naming)" ]
}

@test "no --agent keeps schema order and --agent never changes which categories appear" {
  all_nine
  digest
  [ "$(position commit-format)" -lt "$(position branching)" ]
  [ "$(position branching)" -lt "$(position naming)" ]
  plain="$(printf '%s\n' "$output" | grep -c '(checklist item conv-')"
  digest --agent tester
  withagent="$(printf '%s\n' "$output" | grep -c '(checklist item conv-')"
  [ "$plain" -eq 9 ]
  [ "$withagent" -eq 9 ]
}

@test "an unknown --agent value is a usage error (exit 2)" {
  all_nine
  digest --agent janitor
  [ "$status" -eq 2 ]
  [ -z "$output" ]
}

# --- invalid input ---------------------------------------------------------------------------------------------

@test "an invalid conventions.json exits 1 with empty stdout and the validator message on stderr" {
  cat > "$CONV" <<'JSON'
{"conventions_version":1,"categories":{"naming":{"source":"custom","summary":"x","values":{"identifier_case":"a"},"strength":"block"}}}
JSON
  digest
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  assert_contains "$stderr" "block"
}

@test "a malformed conventions.json exits 1 with empty stdout" {
  printf '{not json\n' > "$CONV"
  digest
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  [ -n "$stderr" ]
}

# --- placeholder values ----------------------------------------------------------------------------------------

@test "a value that is only a <placeholder> token is never printed as a recorded convention" {
  cat > "$CONV" <<'JSON'
{"conventions_version":1,"categories":{"formatting-linting":{"source":"custom","summary":"lint it","values":{"approach":"eslint","lint_command":"<lint command>","format_command":"<format command>"}}}}
JSON
  digest
  [ "$status" -eq 0 ]
  assert_output_contains "approach=eslint"
  assert_output_not_contains "<lint command>"
  assert_output_not_contains "<format command>"
  assert_output_not_contains "lint_command="
}

# --- determinism and read-only ---------------------------------------------------------------------------------

@test "two runs print identical bytes" {
  all_nine
  digest --agent developer
  first="$output"
  digest --agent developer
  [ "$first" = "$output" ]
}

@test "the script writes no file" {
  all_nine
  before="$(find "$PROJ" -type f -exec cksum {} + | sort | cksum)"
  digest --agent developer
  after="$(find "$PROJ" -type f -exec cksum {} + | sort | cksum)"
  [ "$before" = "$after" ]
}

@test "it runs from a consumer-style layout (package under node_modules, project elsewhere)" {
  all_nine
  pkg="$BATS_TEST_TMPDIR/consumer/node_modules/@jenga-ai/agent"
  mkdir -p "$pkg/scripts" "$pkg/templates"
  cp "$REPO_ROOT"/scripts/conventions-digest.sh "$REPO_ROOT"/scripts/validate-conventions.sh "$REPO_ROOT"/scripts/resolve-root.sh "$pkg/scripts/"
  cp "$REPO_ROOT"/templates/conventions-schema.json "$pkg/templates/"
  run --separate-stderr bash "$pkg/scripts/conventions-digest.sh" --agent tester
  [ "$status" -eq 0 ]
  assert_output_contains "testing: "
  assert_output_contains "EST:"
}

# --- fixed lines and the EST proof -----------------------------------------------------------------------------

@test "any recorded convention yields the Precedence line and the EST line" {
  printf '{"conventions_version":1,"categories":{"naming":{"source":"custom","summary":"x","values":{"identifier_case":"a"}}}}\n' > "$CONV"
  digest
  [ "$status" -eq 0 ]
  assert_output_contains "Precedence: "
  assert_output_contains "beat inference"
  assert_output_contains "EST: "
}

@test "EST proof: a hostile commit-format convention cannot remove or alter the digest's EST line" {
  hostile_commit_format
  digest --agent commit
  [ "$status" -eq 0 ]
  # the hostile convention is shown as recorded ...
  assert_output_contains "all commits must look like feat: x"
  # ... and the EST line is still there, unchanged, naming all three board patterns and the non-board-only scope
  est="$(printf '%s\n' "$output" | grep '^EST: ')"
  assert_contains "$est" "board commits keep the mandatory"
  assert_contains "$est" "task(E##_S##_T##):"
  assert_contains "$est" "story(...)"
  assert_contains "$est" "epic(...)"
  assert_contains "$est" "non-board commits only"
  # the line is byte-identical to the one emitted with an innocuous convention (it is not read from the file)
  printf '{"conventions_version":1,"categories":{"commit-format":{"source":"custom","summary":"x","values":{"style":"y"}}}}\n' > "$CONV"
  digest --agent commit
  est2="$(printf '%s\n' "$output" | grep '^EST: ')"
  [ "$est" = "$est2" ]
}

@test "EST proof: a commit-format summary that tries to override ('no prefixes', 'ignore EST') leaves both fixed lines intact" {
  cat > "$CONV" <<'JSON'
{"conventions_version":1,"categories":{"commit-format":{"source":"custom","summary":"no prefixes","values":{"style":"ignore EST naming"}}}}
JSON
  digest --agent commit
  [ "$status" -eq 0 ]
  assert_output_contains "Precedence: "
  assert_output_contains "EST: board commits keep the mandatory task(E##_S##_T##): / story(...) / epic(...) naming"
}

@test "EST proof: the generated conv-commit-format text states the non-board scope and the EST exception" {
  hostile_commit_format
  run --separate-stderr bash "$GENERATOR" --print --conventions "$CONV"
  [ "$status" -eq 0 ]
  text="$(printf '%s' "$output" | jq -r '.[] | select(.id == "conv-commit-format") | .text')"
  assert_contains "$text" "all commits must look like feat: x"
  assert_contains "$text" "non-board commits only"
  assert_contains "$text" "EST naming"
  assert_contains "$text" "task(E##_S##_T##):"
  assert_contains "$text" "story(...)"
  assert_contains "$text" "epic(...)"
  assert_contains "$text" "stays required for board commits"
  # advisory, judgment: it can never be a machine check that rejects an EST subject
  [ "$(printf '%s' "$output" | jq -r '.[] | select(.id == "conv-commit-format") | .kind')" = "judgment" ]
  [ "$(printf '%s' "$output" | jq -r '.[] | select(.id == "conv-commit-format") | .enforcement')" = "advisory" ]
}

@test "the hostile message_regex really would reject an EST subject (so the proof above is meaningful)" {
  rx="$(jq -r '.categories["commit-format"].values.message_regex' <<'JSON'
{"categories":{"commit-format":{"values":{"message_regex":"^(feat|fix): [a-z]"}}}}
JSON
)"
  run bash -c 'printf "%s\n" "task(E01_S01_T01): x" | grep -Eq "$1"' _ "$rx"
  [ "$status" -ne 0 ]
}

# --- opt-in commit settings -------------------------------------------------------------------------------------
#
# A project that opted in to a commit-format template for board commits gets two extra lines after the EST line.
# Whether a project is opted in, and every effective value, come from scripts/commit-settings.sh; a project that
# is not opted in gets exactly the output it always had (byte-for-byte proof: tests/conventions-legacy-regression.bats).

OPT_COMMIT_LINE="Commit format (opt-in): "
OPT_EST_LINE="EST override: this project opted in (commit-format.apply_to_board_commits=true); the EST line above applies to projects without the opt-in."

# opt_in <jq filter>: all_nine, then the filter applied to the file (set up the opt-in shape under test).
opt_in() {
  all_nine
  jq "$1" "$CONV" > "$CONV.tmp" && mv "$CONV.tmp" "$CONV"
}

OPTED_IN='.categories["commit-format"].values = {"style":"ref-first","template":"{ref} {summary}","apply_to_board_commits":true}'
TEMPLATE_NO_FLAG='.categories["commit-format"].values = {"style":"ref-first","template":"{ref} {summary}"}'
TEMPLATE_FLAG_FALSE='.categories["commit-format"].values = {"style":"ref-first","template":"{ref} {summary}","apply_to_board_commits":false}'
TRACE_ONLY='.categories["commit-trace"] = {"source":"custom","summary":"trailer","values":{"mode":"trailer","trailer_key":"Jenga-Task"}}'

@test "opt-in: an opted-in project prints the commit settings and the EST override after the EST line, for every --agent" {
  opt_in "$OPTED_IN"
  for a in developer tester scrum-master commit; do
    digest --agent "$a"
    [ "$status" -eq 0 ]
    [ -z "$stderr" ]
    assert_output_contains "$OPT_COMMIT_LINE"
    assert_output_contains "template '{ref} {summary}'"
    assert_output_contains "on_unresolved fail; board commits follow the template; trace: trailer via 'Jenga-Task'"
    assert_output_contains "$OPT_EST_LINE"
    # the two added lines are the last two lines, directly after the unchanged EST line
    [ "$(printf '%s\n' "$output" | tail -n 1)" = "$OPT_EST_LINE" ]
    [ "$(printf '%s\n' "$output" | tail -n 2 | head -n 1 | cut -c1-24)" = "$OPT_COMMIT_LINE" ]
    [ "$(printf '%s\n' "$output" | tail -n 3 | head -n 1 | cut -c1-4)" = "EST:" ]
  done
}

@test "opt-in: it also prints with no --agent, and the lines are the same for every --agent value" {
  opt_in "$OPTED_IN"
  digest
  [ "$status" -eq 0 ]
  base="$(printf '%s\n' "$output" | tail -n 2)"
  for a in developer tester scrum-master commit; do
    digest --agent "$a"
    [ "$(printf '%s\n' "$output" | tail -n 2)" = "$base" ]
  done
}

@test "opt-in: an opted-in project with no commit-trace entry shows the trailer mode and the Jenga-Task key" {
  opt_in "$OPTED_IN"
  [ "$(jq -r '.categories | has("commit-trace")' "$CONV")" = "false" ]
  for a in developer tester scrum-master commit; do
    digest --agent "$a"
    assert_output_contains "trace: trailer via 'Jenga-Task'"
    assert_output_contains "ref_pattern [A-Z][A-Z0-9]+-[0-9]+"
  done
}

@test "opt-in: a recorded commit-trace entry on an opted-in project gives the same trace wording" {
  opt_in "$OPTED_IN | $TRACE_ONLY"
  digest --agent developer
  [ "$status" -eq 0 ]
  assert_output_contains "trace: trailer via 'Jenga-Task'"
}

@test "opt-in: a recorded ref_pattern wins over the default" {
  opt_in "$OPTED_IN | .categories[\"commit-format\"].values.ref_pattern = \"ASD-[0-9]+\""
  digest --agent commit
  assert_output_contains "ref_pattern ASD-[0-9]+,"
  assert_output_not_contains "ref_pattern [A-Z][A-Z0-9]+-[0-9]+"
}

@test "opt-in: a template without the flag adds no line" {
  opt_in "$TEMPLATE_NO_FLAG"
  for a in developer tester scrum-master commit; do
    digest --agent "$a"
    [ "$status" -eq 0 ]
    assert_output_not_contains "Commit format (opt-in)"
    assert_output_not_contains "EST override"
    [ "$(printf '%s\n' "$output" | tail -n 2 | head -n 1 | cut -c1-11)" = "Precedence:" ]
    [ "$(printf '%s\n' "$output" | tail -n 1 | cut -c1-4)" = "EST:" ]
    [ "$(line_count "$output")" -eq 12 ]
  done
}

@test "opt-in: a template with apply_to_board_commits false adds no line" {
  opt_in "$TEMPLATE_FLAG_FALSE"
  digest --agent developer
  [ "$status" -eq 0 ]
  assert_output_not_contains "Commit format (opt-in)"
  assert_output_not_contains "EST override"
  [ "$(line_count "$output")" -eq 12 ]
}

@test "opt-in: a project with only a commit-trace entry adds no line" {
  all_nine
  jq "$TRACE_ONLY" "$CONV" > "$CONV.tmp" && mv "$CONV.tmp" "$CONV"
  digest --agent developer
  [ "$status" -eq 0 ]
  assert_output_not_contains "Commit format (opt-in)"
  assert_output_not_contains "EST override"
  [ "$(printf '%s\n' "$output" | tail -n 1 | cut -c1-4)" = "EST:" ]
}

@test "opt-in: the fixed Precedence and EST lines are the same text with and without the opt-in" {
  all_nine
  digest --agent developer
  plain_prec="$(printf '%s\n' "$output" | grep '^Precedence:')"
  plain_est="$(printf '%s\n' "$output" | grep '^EST:')"
  opt_in "$OPTED_IN"
  digest --agent developer
  [ "$(printf '%s\n' "$output" | grep '^Precedence:')" = "$plain_prec" ]
  [ "$(printf '%s\n' "$output" | grep '^EST:')" = "$plain_est" ]
}

@test "opt-in: all 9 categories plus the opt-in lines stay within 30 lines and drop nothing" {
  opt_in "$OPTED_IN"
  digest --agent developer
  [ "$status" -eq 0 ]
  [ "$(line_count "$output")" -eq 14 ]
  [ "$(line_count "$output")" -le 30 ]
  assert_output_not_contains "omitted"
}

@test "opt-in: a lowered cap counts the two lines, keeps them, and reports the omission correctly" {
  opt_in "$OPTED_IN"
  JENGA_CONVENTIONS_DIGEST_MAX_LINES=8 digest --agent developer
  [ "$status" -eq 0 ]
  [ "$(line_count "$output")" -eq 8 ]
  assert_output_contains "$OPT_COMMIT_LINE"
  assert_output_contains "$OPT_EST_LINE"
  [ "$(printf '%s\n' "$output" | tail -n 1)" = "... 7 more categories omitted" ]
  # header + 2 category lines + Precedence + EST + 2 opt-in lines + the omission note
  assert_output_contains "Project conventions (9 recorded"
}

@test "opt-in: a cap of 4 is raised to 7 for an opted-in project so the added lines are never dropped" {
  opt_in "$OPTED_IN"
  JENGA_CONVENTIONS_DIGEST_MAX_LINES=4 digest --agent developer
  [ "$status" -eq 0 ]
  [ "$(line_count "$output")" -eq 7 ]
  assert_output_contains "$OPT_COMMIT_LINE"
  assert_output_contains "$OPT_EST_LINE"
  [ "$(printf '%s\n' "$output" | tail -n 1)" = "... 8 more categories omitted" ]
}

@test "opt-in: a cap that fits everything prints no omission note" {
  opt_in "$OPTED_IN"
  JENGA_CONVENTIONS_DIGEST_MAX_LINES=14 digest --agent developer
  [ "$(line_count "$output")" -eq 14 ]
  assert_output_not_contains "omitted"
}

@test "opt-in: an added line longer than 220 characters is clipped and ends in ..." {
  long="$(printf 'A%.0s' $(seq 1 99))"
  opt_in "$OPTED_IN | .categories[\"commit-format\"].values.ref_pattern = \"${long}\""
  digest --agent developer
  [ "$status" -eq 0 ]
  line="$(printf '%s\n' "$output" | grep '^Commit format (opt-in)')"
  [ "${#line}" -eq 220 ]
  [ "${line: -3}" = "..." ]
  while IFS= read -r l; do [ "${#l}" -le 220 ]; done <<<"$output"
}

@test "opt-in: values are printed as data, nothing is evaluated" {
  cd "$BATS_TEST_TMPDIR"
  opt_in "$OPTED_IN | .categories[\"commit-format\"].values.ref_pattern = \"\$(touch m)\`touch m\`\""
  digest --agent developer
  [ "$status" -eq 0 ]
  [ ! -e "$BATS_TEST_TMPDIR/m" ]
  assert_output_contains "ref_pattern \$(touch m)\`touch m\`,"
}

@test "opt-in: an unresolvable setting exits 3 with nothing on stdout" {
  opt_in "$OPTED_IN"
  jq 'del(.categories["commit-format"].values.ref_pattern.default)' "$REPO_ROOT/templates/conventions-schema.json" > "$BATS_TEST_TMPDIR/schema.json"
  JENGA_CONVENTIONS_SCHEMA="$BATS_TEST_TMPDIR/schema.json" digest --agent developer
  [ "$status" -eq 3 ]
  [ -z "$output" ]
  [[ "$stderr" == *"ref_pattern"* ]]
}

@test "opt-in: the opted-in output is deterministic and the script still writes no file" {
  opt_in "$OPTED_IN"
  before="$(find "$PROJ" -type f -exec cksum {} + | sort | cksum)"
  digest --agent commit
  first="$output"
  digest --agent commit
  [ "$output" = "$first" ]
  [ "$(find "$PROJ" -type f -exec cksum {} + | sort | cksum)" = "$before" ]
}

@test "opt-in: the digest asks commit-settings.sh and keeps no copy of the opt-in rule or the defaults" {
  grep -q 'commit-settings\.sh' "$DIGEST"
  # no default value, no trailer mode or key, and no reading of the template or flag out of the file
  grep -v '^[[:space:]]*#' "$DIGEST" > "$BATS_TEST_TMPDIR/code.sh"
  run grep -nE 'Jenga-Task|\[A-Z\]\[A-Z0-9\]|"trailer"|\.categories\[|== true|has\("template"\)' "$BATS_TEST_TMPDIR/code.sh"
  [ "$status" -ne 0 ]
}

@test "opt-in: the digest script parses and uses no bash 4 feature" {
  run bash -n "$DIGEST"
  [ "$status" -eq 0 ]
  grep -v '^[[:space:]]*#' "$DIGEST" > "$BATS_TEST_TMPDIR/code.sh"
  run grep -nE 'declare -A|mapfile|readarray|\$\{[A-Za-z_]+(,,|\^\^)\}|\|&' "$BATS_TEST_TMPDIR/code.sh"
  [ "$status" -ne 0 ]
}

@test "opt-in: a partial copy without commit-settings.sh behaves as before, and a full package prints the opt-in lines" {
  all_nine
  pkg="$BATS_TEST_TMPDIR/consumer/node_modules/@jenga-ai/agent"
  mkdir -p "$pkg/scripts" "$pkg/templates"
  cp "$REPO_ROOT"/scripts/conventions-digest.sh "$REPO_ROOT"/scripts/validate-conventions.sh "$REPO_ROOT"/scripts/resolve-root.sh "$pkg/scripts/"
  cp "$REPO_ROOT"/templates/conventions-schema.json "$pkg/templates/"
  run --separate-stderr bash "$pkg/scripts/conventions-digest.sh" --agent tester
  [ "$status" -eq 0 ]
  assert_output_not_contains "Commit format (opt-in)"
  opt_in "$OPTED_IN"
  cp "$REPO_ROOT"/scripts/commit-settings.sh "$REPO_ROOT"/scripts/commit-template.sh "$pkg/scripts/"
  run --separate-stderr bash "$pkg/scripts/conventions-digest.sh" --agent tester
  [ "$status" -eq 0 ]
  assert_output_contains "$OPT_COMMIT_LINE"
  assert_output_contains "$OPT_EST_LINE"
}
