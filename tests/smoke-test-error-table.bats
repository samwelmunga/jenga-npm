#!/usr/bin/env bats
#
# Coverage for the critical-error table (E64_S01_T02): the `error_table` type registered in
# templates/playbook-types.json, the template asset templates/CRITICAL_ERROR_TABLE_TEMPLATE.md, and the renderer
# skills/j-smoke-test/scripts/render-error-table.sh that turns smoke-test-skills.sh's findings into rows.
#
# The registered per_line regex is validated here against rows the renderer really produced (from fabricated findings
# and from the live catalog), through scripts/validate-typed-object.sh, not against hand-typed strings alone.

# shellcheck disable=SC2016
# SC2016: jq programs and Markdown fixtures hold literal $ and backticks, single-quoted on purpose.

bats_require_minimum_version 1.5.0

load helpers/assertions

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
SCRIPTS="$REPO_ROOT/skills/j-smoke-test/scripts"
RENDER="$SCRIPTS/render-error-table.sh"
HARNESS="$SCRIPTS/smoke-test-skills.sh"
VALIDATE="$REPO_ROOT/scripts/validate-typed-object.sh"
REGISTRY="$REPO_ROOT/templates/playbook-types.json"
TEMPLATE="$REPO_ROOT/templates/CRITICAL_ERROR_TABLE_TEMPLATE.md"
SKILL_MD="$REPO_ROOT/skills/j-smoke-test/SKILL.md"
AUTHORING="$REPO_ROOT/project/documentation/skill-authoring.md"
BASH_BIN="$(command -v bash)"

# --- helpers -------------------------------------------------------------------------------------------------------

# finding <severity> <feature> <error> <consequences>: one JSON line.
finding() {
  jq -nc --arg s "$1" --arg f "$2" --arg e "$3" --arg c "$4" \
    '{skill:"j-x", check:"x", severity:$s, feature:$f, error:$e, consequences:$c}'
}

# render [args]: runs the renderer with stdin from $FINDINGS (a file the test wrote); sets $status, $output, $stderr.
render() {
  run --separate-stderr "$BASH_BIN" "$RENDER" "$@"
}

# validate_rows: pipes $output through the real validator as an error_table; sets status/output.
validate_rows() {
  run --separate-stderr "$BASH_BIN" "$VALIDATE" error_table "$1"
}

setup() {
  FINDINGS="$BATS_TEST_TMPDIR/findings.jsonl"
  {
    finding critical "j-alpha: agent delegation" 'prefered_agent is "ghost" but agents/ghost.md does not exist' "Delegation fails when the skill runs."
    finding minor "j-alpha: skill description" "description is a placeholder" "Listings show a meaningless description."
    finding critical "j-beta: script scripts/x.sh" "SKILL.md references scripts/x.sh, which does not exist" "The step that calls it fails."
  } > "$FINDINGS"
}

# --- the registered type -------------------------------------------------------------------------------------------

@test "error_table is registered with a per_line verify and a trim, drop_empty normalize" {
  run jq -e '.types.error_table | (.verify | keys) == ["per_line"] and (.normalize == ["trim","drop_empty"])' "$REGISTRY"
  [ "$status" -eq 0 ]
  run jq -r '.types.error_table.verify.per_line' "$REGISTRY"
  [ "$output" = '^[^|]+ [|] [^|]+ [|] .+$' ]
}

@test "the type is snake_case and the registry's rule and transform vocabularies are unchanged (no new rule kind or transform)" {
  run jq -e '.types | keys | all(test("^[a-z][a-z0-9_]*$"))' "$REGISTRY"
  [ "$status" -eq 0 ]
  run jq -c '.verify_rules' "$REGISTRY"
  [ "$output" = '["per_line"]' ]
  run jq -c '.normalize_vocabulary' "$REGISTRY"
  [ "$output" = '["split_on_comma","trim","drop_empty"]' ]
  run jq -e '[.types[] | .verify // {} | keys[]] | all(. == "per_line")' "$REGISTRY"
  [ "$status" -eq 0 ]
}

@test "scripts/validate-typed-object.sh is data-driven: it never names error_table and needed no change" {
  run grep -n 'error_table' "$VALIDATE"
  [ "$status" -eq 1 ]
  # The existing types are not named in its code either (the same data-only property its own suite pins).
  run "$BASH_BIN" -n "$VALIDATE"
  [ "$status" -eq 0 ]
}

@test "the validator accepts rows the renderer really produced, and a registry-driven run reports them conforming" {
  render --rows-only "$FINDINGS"
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | grep -c '')" -eq 2 ]
  validate_rows "$output"
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r .outcome)" = "conforming" ]
}

@test "the validator rejects rows with too few fields, an empty field, or unspaced pipes" {
  validate_rows "only one field"
  [ "$status" -eq 3 ]
  validate_rows "feature | error"
  [ "$status" -eq 3 ]
  validate_rows "feature |  | consequences"
  [ "$status" -eq 3 ]
  validate_rows " | error | consequences"
  [ "$status" -eq 3 ]
  validate_rows "feature|error|consequences"
  [ "$status" -eq 3 ]
  validate_rows "feature | error | "
  [ "$status" -eq 3 ]
}

@test "normalize: surrounding whitespace and a blank line are mechanical noise, not a failure" {
  validate_rows "   a | b | c

d | e | f"
  [ "$status" -eq 2 ]
  [ "$(printf '%s' "$output" | jq -r .outcome)" = "normalized" ]
}

# --- the template asset --------------------------------------------------------------------------------------------

@test "the template exists, has a {{ROWS}} line, and defines exactly the Feature | Error | Consequences header" {
  [ -f "$TEMPLATE" ]
  run grep -cx '{{ROWS}}' "$TEMPLATE"
  [ "$output" = "1" ]
  run grep -x 'Feature | Error | Consequences' "$TEMPLATE"
  [ "$status" -eq 0 ]
  run grep -x -- '--- | --- | ---' "$TEMPLATE"
  [ "$status" -eq 0 ]
}

# --- the renderer --------------------------------------------------------------------------------------------------

@test "renders the heading, header and separator from the template and one row per critical finding" {
  render "$FINDINGS"
  [ "$status" -eq 0 ]
  local expected
  expected="$(printf '%s\n' \
    '## Critical errors (2)' \
    '' \
    'Feature | Error | Consequences' \
    '--- | --- | ---' \
    'j-alpha: agent delegation | prefered_agent is "ghost" but agents/ghost.md does not exist | Delegation fails when the skill runs.' \
    'j-beta: script scripts/x.sh | SKILL.md references scripts/x.sh, which does not exist | The step that calls it fails.')"
  [ "$output" = "$expected" ]
}

@test "only critical findings become rows: a minor finding never appears" {
  render "$FINDINGS"
  assert_output_not_contains "skill description"
  assert_output_not_contains "placeholder"
}

@test "the table has exactly the columns Feature, Error, Consequences, and every row has the same shape as the header" {
  render "$FINDINGS"
  local header rows line
  header="$(printf '%s\n' "$output" | sed -n '3p')"
  [ "$header" = "Feature | Error | Consequences" ]
  rows="$(printf '%s\n' "$output" | sed -n '5,$p')"
  while IFS= read -r line; do
    [ "$(printf '%s' "$line" | tr -cd '|' | wc -c | tr -d ' ')" -eq 2 ]
  done <<< "$rows"
}

@test "stdin and a file argument give byte-identical output, and so do two runs (deterministic)" {
  render "$FINDINGS"
  local from_file="$output"
  run --separate-stderr "$BASH_BIN" "$RENDER" < "$FINDINGS"
  [ "$status" -eq 0 ]
  [ "$output" = "$from_file" ]
  render "$FINDINGS"
  [ "$output" = "$from_file" ]
}

@test "no table when there are no critical findings: empty input prints nothing and exits 0" {
  : > "$BATS_TEST_TMPDIR/empty.jsonl"
  render "$BATS_TEST_TMPDIR/empty.jsonl"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ -z "$stderr" ]
}

@test "no table when every finding is minor: no heading, no header, no empty table" {
  finding minor "j-a: skill description" "no description" "blank listing" > "$BATS_TEST_TMPDIR/minor.jsonl"
  render "$BATS_TEST_TMPDIR/minor.jsonl"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  render --rows-only "$BATS_TEST_TMPDIR/minor.jsonl"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "--rows-only prints just the rows, with no heading, header or separator" {
  render --rows-only "$FINDINGS"
  [ "$status" -eq 0 ]
  assert_output_not_contains "Critical errors"
  assert_output_not_contains "---"
  assert_starts_with "$output" "j-alpha: agent delegation | "
}

@test "a pipe inside a field becomes a broken bar so it cannot split the row, and the row still validates" {
  finding critical "j-p: a|b" "error with | a pipe" "consequence | too" > "$BATS_TEST_TMPDIR/pipe.jsonl"
  render --rows-only "$BATS_TEST_TMPDIR/pipe.jsonl"
  [ "$status" -eq 0 ]
  [ "$output" = "j-p: a¦b | error with ¦ a pipe | consequence ¦ too" ]
  validate_rows "$output"
  [ "$status" -eq 0 ]
}

@test "newlines and tabs are flattened to one line, and an empty field becomes unspecified (the row still validates)" {
  jq -nc '{severity:"critical", feature:"j-n: multi\nline", error:"tab\there", consequences:""}' > "$BATS_TEST_TMPDIR/ws.jsonl"
  render --rows-only "$BATS_TEST_TMPDIR/ws.jsonl"
  [ "$status" -eq 0 ]
  [ "$output" = "j-n: multi line | tab here | unspecified" ]
  validate_rows "$output"
  [ "$status" -eq 0 ]
}

@test "the layout comes from the template: a custom template changes the heading and header without touching the script" {
  printf '%s\n' '<!-- comment -->' '# Problems found: {{COUNT}}' '' 'What | Why | Impact' '--- | --- | ---' '{{ROWS}}' 'end' > "$BATS_TEST_TMPDIR/custom.md"
  render --template "$BATS_TEST_TMPDIR/custom.md" "$FINDINGS"
  [ "$status" -eq 0 ]
  assert_starts_with "$output" "# Problems found: 2"
  assert_output_contains "What | Why | Impact"
  assert_output_not_contains "comment"
  assert_output_not_contains "Feature | Error | Consequences"
  [ "$(printf '%s\n' "$output" | tail -n 1)" = "end" ]
}

@test "errors: a template with no {{ROWS}} line, a missing template, a missing file and invalid JSON all exit 2" {
  printf '%s\n' '## no rows placeholder' > "$BATS_TEST_TMPDIR/bad.md"
  render --template "$BATS_TEST_TMPDIR/bad.md" "$FINDINGS"
  [ "$status" -eq 2 ]
  assert_contains "$stderr" "no {{ROWS}} line"
  render --template "$BATS_TEST_TMPDIR/absent.md" "$FINDINGS"
  [ "$status" -eq 2 ]
  assert_contains "$stderr" "template not found"
  render "$BATS_TEST_TMPDIR/absent.jsonl"
  [ "$status" -eq 2 ]
  assert_contains "$stderr" "not found"
  printf 'this is not json\n' > "$BATS_TEST_TMPDIR/garbage.jsonl"
  render "$BATS_TEST_TMPDIR/garbage.jsonl"
  [ "$status" -eq 2 ]
  assert_contains "$stderr" "not valid JSON lines"
  render --bogus
  [ "$status" -eq 2 ]
}

# --- the harness feeding the renderer ------------------------------------------------------------------------------

@test "harness to renderer on a tree with a critical defect prints the table, and the rows validate as error_table" {
  local root="$BATS_TEST_TMPDIR/root"
  mkdir -p "$root/skills/j-ghost" "$root/agents"
  printf '%s\n' '---' 'name: j.ghost' 'description: Delegates to a missing agent.' 'metadata:' '  prefered_agent: nobody' '---' > "$root/skills/j-ghost/SKILL.md"
  run --separate-stderr "$BASH_BIN" "$HARNESS" --root "$root"
  [ "$status" -eq 1 ]
  local findings="$output"
  render <<< "$findings"
  [ "$status" -eq 0 ]
  assert_output_contains "## Critical errors (1)"
  assert_output_contains "j-ghost: agent delegation | metadata.prefered_agent is \"nobody\" but agents/nobody.md does not exist | "
  render --rows-only <<< "$findings"
  validate_rows "$output"
  [ "$status" -eq 0 ]
}

@test "harness to renderer on a healthy tree prints no table at all" {
  local root="$BATS_TEST_TMPDIR/root"
  mkdir -p "$root/skills/j-fine" "$root/agents"
  printf '%s\n' '---' 'name: j.fine' 'description: Perfectly healthy.' '---' > "$root/skills/j-fine/SKILL.md"
  run --separate-stderr "$BASH_BIN" "$HARNESS" --root "$root"
  [ "$status" -eq 0 ]
  render <<< "$output"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "live catalog: whatever the harness reports as critical renders as rows that all validate as error_table" {
  local findings
  findings="$("$BASH_BIN" "$HARNESS" 2> /dev/null || true)"
  render --rows-only <<< "$findings"
  [ "$status" -eq 0 ]
  if [ -z "$output" ]; then
    skip "the live catalog currently has no critical finding"
  fi
  local critical rows
  critical="$(printf '%s\n' "$findings" | jq -s '[.[] | select(.severity == "critical")] | length')"
  rows="$(printf '%s\n' "$output" | grep -c '')"
  [ "$critical" -eq "$rows" ]
  validate_rows "$output"
  [ "$status" -eq 0 ]
}

# --- the skill and the documentation -------------------------------------------------------------------------------

@test "SKILL.md renders the table through the script and prints nothing when no finding is critical" {
  local body
  body="$(cat "$SKILL_MD")"
  assert_contains "$body" "render-error-table.sh"
  assert_contains "$body" "CRITICAL_ERROR_TABLE_TEMPLATE.md"
  assert_contains "$body" "error_table"
  assert_contains "$body" "print no table"
}

@test "skill-authoring.md lists error_table in the vocabulary and documents it in the ranked_list subsection's style" {
  run grep -c '`error_table`' "$AUTHORING"
  [ "$output" -ge 4 ]
  run grep -n '^#### The `error_table` type' "$AUTHORING"
  [ "$status" -eq 0 ]
  local section
  section="$(sed -n '/^#### The `error_table` type/,/^## Threat Model/p' "$AUTHORING")"
  assert_contains "$section" '- **`verify`**'
  assert_contains "$section" '- **`normalize`**'
  assert_contains "$section" '- **Naming**'
  assert_contains "$section" "^[^|]+ [|] [^|]+ [|] .+\$"
  assert_contains "$section" "validate-typed-object.sh"
  # The doc quotes the same regex the registry holds.
  assert_contains "$section" "$(jq -r '.types.error_table.verify.per_line' "$REGISTRY")"
}

@test "the renderer passes bash -n" {
  run "$BASH_BIN" -n "$RENDER"
  [ "$status" -eq 0 ]
}
