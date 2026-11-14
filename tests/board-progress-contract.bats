#!/usr/bin/env bats
#
# E92_S01_T05: the contract drift guard of scripts/board-progress.sh. Four things must not drift apart silently:
#   1. the statuses the board may carry (templates/SCRUM_BOARD_SCHEMA.md "Status Values" and project/configs/
#      workflow.json "statuses") and the script's status table: a status added there later must not fall into `unknown`;
#   2. the documented status table (project/documentation/progress-visualisation.md section 4) and the script's table;
#   3. the JSON keys the script prints and the keys of the documented example (section 3), compared with jq;
#   4. the schema_version the script prints and the version the document states.
#
# Inputs: the script, the two status sources above, the contract document and a throwaway fixture board built under
# $BATS_FILE_TMPDIR / $BATS_TEST_TMPDIR. The live project/board/ and the live project/todo.md are never read. The bucket
# of a status is always found by running the script, never by parsing its table, so a table row that is removed or
# renamed makes these tests fail.

bats_require_minimum_version 1.5.0

load helpers/progress-fixture

REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
SCHEMA="$REPO_ROOT/templates/SCRUM_BOARD_SCHEMA.md"
WORKFLOW="$REPO_ROOT/project/configs/workflow.json"
CONTRACT_DOC="$REPO_ROOT/project/documentation/progress-visualisation.md"

# ---- extraction helpers -----------------------------------------------------------------------------------------

# schema_statuses: the status names of the "Status Values" table, one per line, in table order.
schema_statuses() {
  awk '/^## Status Values/ { f = 1; next } f && /^##/ { exit } f && /^\| `/ { s = $0; sub(/^\| `/, "", s); sub(/`.*/, "", s); print s }' "$SCHEMA"
}

# workflow_statuses: workflow.json "statuses", one per line.
workflow_statuses() {
  jq -r '.statuses[]' "$WORKFLOW"
}

# doc_table: "<status>|<bucket>" for every row of the documented status table (section 4); the "any other string" row
# has no backticked status and is not a row of statuses.
doc_table() {
  awk '/^## 4\. / { f = 1; next } f && /^## / { exit } f { print }' "$CONTRACT_DOC" \
    | sed -n 's/^| `\([^`]*\)` | `\([^`]*\)` |.*/\1|\2/p'
}

# doc_json: the first ```json block of the contract document (the example of section 3).
doc_json() {
  awk '/^```json/ { f = 1; next } f && /^```/ { exit } f { print }' "$CONTRACT_DOC"
}

# doc_schema_version: the version stated in the heading of section 3.
doc_schema_version() {
  sed -n 's/^## 3\..*schema_version: \([0-9][0-9]*\).*/\1/p' "$CONTRACT_DOC"
}

# ---- script-side helpers ----------------------------------------------------------------------------------------

# status_board <root> <status>...: epic E01, story E01_S01 and one task E01_S01_T<nn> per status, on a throwaway root.
status_board() {
  local root="$1" n=0 s
  shift
  PF_ROOT="$root"
  mkdir -p "$PF_ROOT/project/configs"
  printf '{}\n' > "$PF_ROOT/project/configs/workflow.json"
  pf_item E01 Pending
  pf_item E01_S01 Pending
  for s in "$@"; do
    n=$((n + 1))
    pf_item "E01_S01_T$(printf '%02d' "$n")" "$s"
  done
}

# unmapped_statuses <script> <status>...: the statuses that land in the `unknown` bucket of <script>, one per line,
# found by one run over a board that carries one task for each of them.
unmapped_statuses() {
  local script="$1" root="$BATS_TEST_TMPDIR/unmapped-board"
  shift
  rm -rf "$root"
  status_board "$root" "$@"
  bash "$script" --root "$root" --story E01_S01 --items \
    | jq -r '(.levels.tasks.items | map({(.id): .status}) | add) as $m
             | .warnings[] | select(.kind == "unknown_status") | $m[.id]'
}

# bucket_of <status>: the bucket the script gives the status, from the map made once in setup_file.
bucket_of() {
  awk -F'|' -v s="$1" '$1 == s { print $2 }' "$BUCKET_MAP"
}

# all_statuses: the union of the schema's, workflow.json's and the document's statuses, one per line, first seen first.
all_statuses() {
  { schema_statuses; workflow_statuses; doc_table | cut -d'|' -f1; } | awk '!seen[$0]++'
}

setup_file() {
  command -v jq >/dev/null 2>&1 || return 0
  local statuses=() s n=0 root="$BATS_FILE_TMPDIR/bucket-board"
  while IFS= read -r s; do statuses+=("$s"); done < <(all_statuses)
  export BUCKET_MAP="$BATS_FILE_TMPDIR/buckets.txt"
  : > "$BUCKET_MAP"
  # One board, one task per status; each status is then counted on its own through --ids.
  rm -rf "$root"
  status_board "$root" "${statuses[@]}"
  for s in "${statuses[@]}"; do
    n=$((n + 1))
    printf '%s|%s\n' "$s" "$(bash "$PF_SCRIPT" --root "$root" --ids "E01_S01_T$(printf '%02d' "$n")" \
      | jq -r '.levels.tasks.totals | to_entries | map(select(.key != "denominator" and .value > 0)) | .[0].key')" >> "$BUCKET_MAP"
  done
}

setup() {
  command -v jq >/dev/null 2>&1 || skip "jq is required for the contract drift guard"
  BUCKET_MAP="$BATS_FILE_TMPDIR/buckets.txt"
}

# ---- 1. every status the board may carry has a bucket ------------------------------------------------------------

@test "the schema's Status Values and workflow.json statuses are read (the guard is not vacuous)" {
  [ "$(schema_statuses | wc -l | tr -d ' ')" -ge 14 ]
  [ "$(workflow_statuses | wc -l | tr -d ' ')" -ge 14 ]
  [ "$(doc_table | wc -l | tr -d ' ')" -ge 14 ]
  [ "$(wc -l < "$BUCKET_MAP" | tr -d ' ')" -ge 14 ]
}

@test "every status of the schema's Status Values maps to a bucket other than unknown" {
  local s b
  while IFS= read -r s; do
    b="$(bucket_of "$s")"
    [ -n "$b" ] && [ "$b" != "unknown" ] || { echo "schema status '$s' has bucket '${b:-<none>}'"; return 1; }
  done < <(schema_statuses)
}

@test "every status of workflow.json statuses maps to a bucket other than unknown" {
  local s b
  while IFS= read -r s; do
    b="$(bucket_of "$s")"
    [ -n "$b" ] && [ "$b" != "unknown" ] || { echo "workflow status '$s' has bucket '${b:-<none>}'"; return 1; }
  done < <(workflow_statuses)
}

@test "the schema's statuses and workflow.json statuses are the same set" {
  diff <(schema_statuses | LC_ALL=C sort) <(workflow_statuses | LC_ALL=C sort)
}

@test "one run over a board with every status reports no unknown_status warning" {
  local all=() s
  while IFS= read -r s; do all+=("$s"); done < <(all_statuses)
  [ -z "$(unmapped_statuses "$PF_SCRIPT" "${all[@]}")" ]
}

@test "removing a row from the script's status table makes the guard fail" {
  local copy="$BATS_TEST_TMPDIR/mutated/scripts" all=() s out
  mkdir -p "$BATS_TEST_TMPDIR/mutated"
  cp -R "$REPO_ROOT/scripts" "$copy"
  # drop the Backlog row from the copy's table; the live script is untouched
  sed '/^Backlog|pending$/d' "$REPO_ROOT/scripts/board-progress.sh" > "$copy/board-progress.sh"
  ! diff -q "$REPO_ROOT/scripts/board-progress.sh" "$copy/board-progress.sh" >/dev/null
  while IFS= read -r s; do all+=("$s"); done < <(all_statuses)
  out="$(unmapped_statuses "$copy/board-progress.sh" "${all[@]}")"
  [ "$out" = "Backlog" ]
}

# ---- 2. the documented table matches the script's table ----------------------------------------------------------

@test "the documented status table has the same statuses as the schema, in the schema's order" {
  diff <(schema_statuses) <(doc_table | cut -d'|' -f1)
}

@test "every row of the documented status table has the bucket the script gives that status" {
  local row s b got
  while IFS= read -r row; do
    s="${row%%|*}"; b="${row#*|}"
    got="$(bucket_of "$s")"
    [ "$got" = "$b" ] || { echo "status '$s': documented bucket '$b', script bucket '${got:-<none>}'"; return 1; }
  done < <(doc_table)
}

# ---- 3. the printed JSON keys equal the documented JSON keys ----------------------------------------------------

# key_shape: the sets of keys the contract fixes, read from stdin (a progress JSON document).
key_shape() {
  jq -c '[ (keys),
           (.scope | keys),
           (.levels.tasks | keys),
           (.levels.tasks.totals | keys),
           (.levels.tasks.items[0] | keys),
           (.warnings[0] | keys) ]'
}

@test "the documented JSON example is valid JSON and carries the keys the shape needs" {
  doc_json | jq -e '.schema_version and .scope.type and .levels.tasks.counts and .levels.tasks.totals and .levels.tasks.items[0].id and .warnings[0].kind' >/dev/null
}

@test "the top-level, scope, per-level, totals, item and warning keys the script prints equal the documented ones" {
  local fixture="$BATS_TEST_TMPDIR/fixture-board" printed documented
  pf_build "$fixture"
  printed="$(JENGA_TODO_FILE="$BATS_TEST_TMPDIR/none.md" bash "$PF_SCRIPT" --root "$fixture" --all --items | key_shape)"
  documented="$(doc_json | key_shape)"
  echo "script:   $printed"
  echo "document: $documented"
  [ "$printed" = "$documented" ]
}

@test "the levels the script prints for --all are exactly the levels the document names" {
  local fixture="$BATS_TEST_TMPDIR/fixture-board"
  pf_build "$fixture"
  [ "$(JENGA_TODO_FILE="$BATS_TEST_TMPDIR/none.md" bash "$PF_SCRIPT" --root "$fixture" --all | jq -c '.levels | keys')" = '["epics","stories","tasks"]' ]
  grep -q 'one block per item level: `tasks`, `stories`, `epics`' <(tr '\n' ' ' < "$CONTRACT_DOC" | sed 's/  */ /g')
}

@test "every warning kind the script emits is a kind the document lists" {
  local fixture="$BATS_TEST_TMPDIR/fixture-board" kinds k todo="$BATS_TEST_TMPDIR/todo.md"
  pf_build "$fixture"
  printf 'Do a task: E01_S01_T01\nNo id at all\nGhost: E77_S01_T01\n' > "$todo"
  kinds="$( { JENGA_TODO_FILE="$todo" bash "$PF_SCRIPT" --root "$fixture" --all
              JENGA_TODO_FILE="$todo" bash "$PF_SCRIPT" --root "$fixture" --backlog; } | jq -r '.warnings[].kind' | LC_ALL=C sort -u)"
  # the four kinds this fixture can provoke; a kind that is not provoked here cannot be asserted, a missing one is a failure
  for k in orphan_task unknown_status todo_unresolved_entry todo_unknown_id; do
    printf '%s\n' "$kinds" | grep -qx "$k" || { echo "fixture no longer provokes warning kind '$k'"; return 1; }
  done
  for k in $kinds; do
    grep -q "\`$k\`" "$CONTRACT_DOC" || { echo "warning kind '$k' is not documented"; return 1; }
  done
}

# ---- 4. the schema_version the script prints is the version the document states ---------------------------------

@test "schema_version printed by the script equals the version stated in the document" {
  local fixture="$BATS_TEST_TMPDIR/fixture-board" printed stated example
  pf_build "$fixture"
  printed="$(JENGA_TODO_FILE="$BATS_TEST_TMPDIR/none.md" bash "$PF_SCRIPT" --root "$fixture" --all | jq -r '.schema_version')"
  stated="$(doc_schema_version)"
  example="$(doc_json | jq -r '.schema_version')"
  [ -n "$stated" ]
  echo "script $printed, heading $stated, example $example"
  [ "$printed" = "$stated" ]
  [ "$printed" = "$example" ]
  # the script's own header and usage text state the same version
  grep -q "schema_version $printed" "$REPO_ROOT/scripts/board-progress.sh"
}

# ---- 5. prose that once described a script behaviour that has since changed -------------------------------------

@test "the document no longer calls --backlog unavailable, and the script really accepts it" {
  ! grep -qi 'not available' "$CONTRACT_DOC"
  local fixture="$BATS_TEST_TMPDIR/fixture-board"
  pf_build "$fixture"
  # a missing todo file is the empty scope (exit 3), not a usage error (exit 2)
  run -3 env JENGA_TODO_FILE="$BATS_TEST_TMPDIR/absent.md" bash "$PF_SCRIPT" --root "$fixture" --backlog
}
