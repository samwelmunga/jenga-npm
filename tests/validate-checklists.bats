#!/usr/bin/env bats
#
# Coverage for scripts/validate-checklists.sh (E67_S01_T04).
#
# Contract under test: project/documentation/preflight-checklists.md (section 3 lists the rejection
# classes) and the header comment of the script itself.
#
# Every fixture is generated at test time into $BATS_TEST_TMPDIR, which bats removes after each test.
# No invalid registry file exists anywhere in the repository as a standalone data file; the only
# repository files read here are the two real registries, which must validate clean.
#
# Streams: the script writes one verdict line per file (PASS/FAIL <file>) to stdout and one
# "<file>: <message>" line per problem to stderr. Tests that care which stream carries what use
# `run --separate-stderr`; the rest merge both into $output.
#
# Exit codes pinned here: 0 every file clean, 1 any file invalid or unreadable, 2 no arguments.
# Exit code 3 (python3 missing) is deliberately NOT tested: reproducing it needs a PATH stripped of
# python3 that still resolves bash and dirname, and the branch is a single command -v guard with no
# logic worth pinning. If that guard ever grows behaviour, add a test then.
#
# E67_S05_T01 added the "Provenance" section at the end of the file; it supersedes this suite's earlier
# "unknown item keys are tolerated" stance for an item's `provenance` key only.
#
# Tests named "(pinned judgment call)" assert behaviour the validator's author chose rather than one
# the schema document dictates. They are named that way so a future change to the behaviour is a
# conscious decision, not a silent one.

bats_require_minimum_version 1.5.0
load helpers/assertions

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
VALIDATE="$REPO_ROOT/scripts/validate-checklists.sh"

setup() {
  F="$BATS_TEST_TMPDIR/checklists.json"
}

# A fully valid file, written to $F. Item 0 is a machine item, item 1 a judgment item, and item 2 uses a
# phase ("pre-deploy") that the file declares through its own top-level "situations".
write_valid() {
  cat > "$F" <<'JSON'
{
  "checklist_version": 1,
  "situations": ["pre-deploy"],
  "items": [
    {
      "id": "lint-clean",
      "text": "The linter reports no errors.",
      "situations": ["pre-commit", "pre-task"],
      "kind": "machine",
      "verify": "true",
      "enforcement": "block",
      "tick_scope": "run"
    },
    {
      "id": "criteria-reread",
      "text": "I have re-read the acceptance criteria.",
      "situations": ["pre-task"],
      "kind": "judgment",
      "enforcement": "advisory",
      "tick_scope": "persistent"
    },
    {
      "id": "staging-green",
      "text": "Staging is green.",
      "situations": ["pre-deploy"],
      "kind": "judgment",
      "enforcement": "confirm",
      "tick_scope": "run"
    }
  ]
}
JSON
}

# Rewrites $F by applying a jq filter to the valid file.
mutate() {
  write_valid
  jq "$1" "$F" > "$F.new" && mv "$F.new" "$F"
}

# Writes the valid file with checklist_version replaced by the given raw JSON literal.
write_with_version() {
  write_valid
  sed "s/\"checklist_version\": 1,/\"checklist_version\": $1,/" "$F" > "$F.new" && mv "$F.new" "$F"
}

# -----------------------------------------------------------------------------
# Clean files
# -----------------------------------------------------------------------------

@test "a clean file exits 0 and prints a PASS verdict naming the file" {
  write_valid
  run --separate-stderr bash "$VALIDATE" "$F"
  [ "$status" -eq 0 ]
  assert_contains "$output" "PASS $F"
  [ -z "$stderr" ]
}

@test "templates/checklists.json (the shipped default) validates clean" {
  run bash "$VALIDATE" "$REPO_ROOT/templates/checklists.json"
  [ "$status" -eq 0 ]
  assert_output_contains "PASS $REPO_ROOT/templates/checklists.json"
}

@test "project/configs/checklists.json (this project's instance) validates clean" {
  run bash "$VALIDATE" "$REPO_ROOT/project/configs/checklists.json"
  [ "$status" -eq 0 ]
  assert_output_contains "PASS $REPO_ROOT/project/configs/checklists.json"
}

@test "an empty items array is valid" {
  mutate '.items = []'
  run bash "$VALIDATE" "$F"
  [ "$status" -eq 0 ]
}

@test "every base situation is accepted without being declared" {
  mutate '.situations = [] | .items[1].situations = ["pre-commit", "pre-task", "pre-release", "pre-reconcile"] | .items[2].situations = ["pre-release"]'
  run bash "$VALIDATE" "$F"
  [ "$status" -eq 0 ]
}

# -----------------------------------------------------------------------------
# One test per rejection class (schema section 3)
# -----------------------------------------------------------------------------

@test "unknown situation: exits 1 and names the situation and the item" {
  mutate '.items[0].situations = ["pre-deplyo"]'
  run --separate-stderr bash "$VALIDATE" "$F"
  [ "$status" -eq 1 ]
  assert_contains "$stderr" 'unknown situation "pre-deplyo" in item "lint-clean"'
  assert_contains "$output" "FAIL $F"
}

@test "unknown situation: a phase that the file does not declare is rejected" {
  mutate '.situations = [] | .items[2].situations = ["pre-deploy"]'
  run bash "$VALIDATE" "$F"
  [ "$status" -eq 1 ]
  assert_output_contains 'unknown situation "pre-deploy" in item "staging-green"'
}

@test "unknown kind: exits 1 and names the value and the item" {
  mutate '.items[1].kind = "automatic"'
  run bash "$VALIDATE" "$F"
  [ "$status" -eq 1 ]
  assert_output_contains 'unknown kind "automatic" in item "criteria-reread"'
}

@test "missing verify: a machine item with no verify key exits 1" {
  mutate 'del(.items[0].verify)'
  run bash "$VALIDATE" "$F"
  [ "$status" -eq 1 ]
  assert_output_contains 'missing verify: item "lint-clean" has kind "machine" but no non-empty verify command'
}

@test "missing verify: a null, empty, whitespace-only or non-string verify counts as missing" {
  local v
  for v in 'null' '""' '"   "' '42' '["true"]'; do
    mutate ".items[0].verify = $v"
    run bash "$VALIDATE" "$F"
    [ "$status" -eq 1 ] || { echo "verify $v accepted" >&2; return 1; }
    assert_output_contains 'missing verify: item "lint-clean"'
  done
}

@test "verify on a judgment item: exits 1 and names the item" {
  mutate '.items[1].verify = "true"'
  run bash "$VALIDATE" "$F"
  [ "$status" -eq 1 ]
  assert_output_contains 'verify on a judgment item: item "criteria-reread" has kind "judgment" but carries a verify key'
}

@test "verify on a judgment item: the key is rejected whatever its value, even empty or null" {
  local v
  for v in '""' 'null' '"true"'; do
    mutate ".items[1].verify = $v"
    run bash "$VALIDATE" "$F"
    [ "$status" -eq 1 ] || { echo "judgment verify $v accepted" >&2; return 1; }
    assert_output_contains 'verify on a judgment item'
  done
}

@test "bad enforcement: exits 1 and names the value and the item" {
  mutate '.items[0].enforcement = "mandatory"'
  run bash "$VALIDATE" "$F"
  [ "$status" -eq 1 ]
  assert_output_contains 'bad enforcement "mandatory" in item "lint-clean"'
}

@test "bad tick_scope: exits 1 and names the value and the item" {
  mutate '.items[0].tick_scope = "forever"'
  run bash "$VALIDATE" "$F"
  [ "$status" -eq 1 ]
  assert_output_contains 'bad tick_scope "forever" in item "lint-clean"'
}

@test "duplicate item id: exits 1 and names the id and its positions" {
  mutate '.items[1].id = "lint-clean"'
  run bash "$VALIDATE" "$F"
  [ "$status" -eq 1 ]
  assert_output_contains 'duplicate item id: "lint-clean" appears 2 times in this file (items[0, 1])'
}

@test "missing required field: each required item field is reported by name" {
  local field
  for field in id text situations kind enforcement tick_scope; do
    mutate "del(.items[1].$field)"
    run bash "$VALIDATE" "$F"
    [ "$status" -eq 1 ] || { echo "item missing $field accepted" >&2; return 1; }
    assert_output_contains "missing required field: $field in"
  done
}

@test "missing required field: a missing item id is reported against the item's index" {
  mutate 'del(.items[1].id)'
  run bash "$VALIDATE" "$F"
  [ "$status" -eq 1 ]
  assert_output_contains "missing required field: id in items[1]"
}

@test "missing required field: a missing item field names the item by id" {
  mutate 'del(.items[0].text)'
  run bash "$VALIDATE" "$F"
  [ "$status" -eq 1 ]
  assert_output_contains 'missing required field: text in item "lint-clean"'
}

@test "missing required field: top-level checklist_version and items" {
  mutate 'del(.checklist_version)'
  run bash "$VALIDATE" "$F"
  [ "$status" -eq 1 ]
  assert_output_contains "missing required field: checklist_version"

  mutate 'del(.items)'
  run bash "$VALIDATE" "$F"
  [ "$status" -eq 1 ]
  assert_output_contains "missing required field: items"
}

@test "malformed JSON: a truncated file exits 1 with a malformed JSON message" {
  printf '{ "checklist_version": 1, "items": [' > "$F"
  run --separate-stderr bash "$VALIDATE" "$F"
  [ "$status" -eq 1 ]
  assert_contains "$stderr" "malformed JSON"
  assert_contains "$output" "FAIL $F"
}

@test "malformed JSON: an empty file exits 1" {
  : > "$F"
  run bash "$VALIDATE" "$F"
  [ "$status" -eq 1 ]
  assert_output_contains "malformed JSON"
}

@test "malformed JSON: a non-object top level exits 1" {
  printf '[]\n' > "$F"
  run bash "$VALIDATE" "$F"
  [ "$status" -eq 1 ]
  assert_output_contains "malformed JSON: top level must be a JSON object"
}

@test "malformed JSON: non-standard constants such as NaN are rejected" {
  printf '{"checklist_version": NaN, "items": []}\n' > "$F"
  run bash "$VALIDATE" "$F"
  [ "$status" -eq 1 ]
  assert_output_contains "malformed JSON"
}

# -----------------------------------------------------------------------------
# Structural classes beyond the nine in schema section 3
# -----------------------------------------------------------------------------

@test "a malformed item id, empty text, empty situations and repeated situation each exit 1" {
  mutate '.items[0].id = "Lint_Clean"'
  run bash "$VALIDATE" "$F"
  [ "$status" -eq 1 ]
  assert_output_contains "malformed id"

  mutate '.items[0].text = "   "'
  run bash "$VALIDATE" "$F"
  [ "$status" -eq 1 ]
  assert_output_contains "empty text"

  mutate '.items[0].situations = []'
  run bash "$VALIDATE" "$F"
  [ "$status" -eq 1 ]
  assert_output_contains "empty situations"

  mutate '.items[0].situations = ["pre-task", "pre-task"]'
  run bash "$VALIDATE" "$F"
  [ "$status" -eq 1 ]
  assert_output_contains 'duplicate situation "pre-task" in item "lint-clean"'
}

@test "an items element that is not an object exits 1" {
  mutate '.items[1] = "just a string"'
  run bash "$VALIDATE" "$F"
  [ "$status" -eq 1 ]
  assert_output_contains "bad item: items[1] must be an object"
}

# -----------------------------------------------------------------------------
# Pinned judgment calls
# -----------------------------------------------------------------------------

@test "every problem in a file is reported in one run, not only the first" {
  mutate '.items[0].situations = ["nope"] | .items[0].enforcement = "maybe" | .items[0].tick_scope = "x" | .items[0].kind = "auto" | del(.items[1].text) | .items[2].id = "lint-clean"'
  run bash "$VALIDATE" "$F"
  [ "$status" -eq 1 ]
  assert_output_contains "unknown situation"
  assert_output_contains "bad enforcement"
  assert_output_contains "bad tick_scope"
  assert_output_contains "unknown kind"
  assert_output_contains "missing required field: text"
  assert_output_contains "duplicate item id"
}

@test "unknown extra keys on an item and at the top level are tolerated (pinned judgment call)" {
  # E67_S05_T01: an ITEM's provenance key is no longer an unknown key (it is validated; see the Provenance
  # section below), so items[0].provenance = "shipped" was removed from this mutation. A TOP-LEVEL
  # provenance key, .note and items[1].owner are still unknown keys and still tolerated.
  mutate '.provenance = {"source": "x"} | .note = 1 | .items[1].owner = "someone"'
  run bash "$VALIDATE" "$F"
  [ "$status" -eq 0 ]
  assert_output_contains "PASS $F"
}

@test "a present-but-wrong-typed kind, enforcement or tick_scope gets that field's own error (pinned judgment call)" {
  mutate '.items[0].kind = 7 | .items[0].enforcement = true | .items[0].tick_scope = ["run"]'
  run bash "$VALIDATE" "$F"
  [ "$status" -eq 1 ]
  assert_output_contains 'unknown kind 7 in item "lint-clean"'
  assert_output_contains 'bad enforcement true in item "lint-clean"'
  assert_output_contains 'bad tick_scope ["run"] in item "lint-clean"'
  assert_output_not_contains "missing required field: kind"
  assert_output_not_contains "missing required field: enforcement"
  assert_output_not_contains "missing required field: tick_scope"
}

@test "a wrong-typed id, text or situations counts as missing required field (pinned judgment call)" {
  mutate '.items[0].id = 3 | .items[0].text = 4 | .items[0].situations = "pre-commit"'
  run bash "$VALIDATE" "$F"
  [ "$status" -eq 1 ]
  assert_output_contains "missing required field: id in items[0] (must be a string"
  assert_output_contains "missing required field: text in items[0] (must be a string"
  assert_output_contains "missing required field: situations in items[0] (must be an array"
}

@test "enum values are case-sensitive (pinned judgment call)" {
  mutate '.items[0].enforcement = "Block"'
  run bash "$VALIDATE" "$F"
  [ "$status" -eq 1 ]
  assert_output_contains 'bad enforcement "Block"'
}

@test "checklist_version other than the integer 1 gives bad checklist_version (pinned judgment call)" {
  local v
  for v in 'true' '1.0' '"1"' '2' '0' 'null'; do
    write_with_version "$v"
    run bash "$VALIDATE" "$F"
    [ "$status" -eq 1 ] || { echo "checklist_version $v accepted" >&2; return 1; }
    assert_output_contains "bad checklist_version"
  done
}

@test "an item may use a phase declared in the file's top-level situations (extension vocabulary)" {
  write_valid
  run bash "$VALIDATE" "$F"
  [ "$status" -eq 0 ]
  assert_output_contains "PASS $F"
}

@test "an extension phase is scoped to its own file and is not inherited by another (pinned judgment call)" {
  local other="$BATS_TEST_TMPDIR/other.json"
  mutate '.situations = []'
  mv "$F" "$other"
  write_valid
  run bash "$VALIDATE" "$F" "$other"
  [ "$status" -eq 1 ]
  assert_output_contains "PASS $F"
  assert_output_contains "FAIL $other"
  assert_output_contains 'unknown situation "pre-deploy"'
}

@test "an invalid top-level extension name is rejected and the item using it also reports unknown situation (pinned judgment call)" {
  mutate '.situations = ["Pre_Deploy"] | .items[2].situations = ["Pre_Deploy"]'
  run bash "$VALIDATE" "$F"
  [ "$status" -eq 1 ]
  assert_output_contains 'bad top-level situations: situations[0] "Pre_Deploy" is not a valid extension name'
  assert_output_contains 'unknown situation "Pre_Deploy" in item "staging-green"'
}

@test "a top-level extension that duplicates a base situation, or repeats, is rejected" {
  mutate '.situations = ["pre-commit"]'
  run bash "$VALIDATE" "$F"
  [ "$status" -eq 1 ]
  assert_output_contains "duplicates a base situation"

  mutate '.situations = ["pre-deploy", "pre-deploy"]'
  run bash "$VALIDATE" "$F"
  [ "$status" -eq 1 ]
  assert_output_contains 'situations[1] "pre-deploy" is repeated'
}

# -----------------------------------------------------------------------------
# Exit codes, usage and multi-file behaviour
# -----------------------------------------------------------------------------

@test "no arguments is a usage error (exit 2)" {
  run bash "$VALIDATE"
  [ "$status" -eq 2 ]
  assert_output_contains "usage:"
}

@test "a non-existent file reports cannot read file and exits 1 (pinned judgment call)" {
  run --separate-stderr bash "$VALIDATE" "$BATS_TEST_TMPDIR/does-not-exist.json"
  [ "$status" -eq 1 ]
  assert_contains "$stderr" "cannot read file"
  assert_contains "$output" "FAIL $BATS_TEST_TMPDIR/does-not-exist.json"
}

@test "a directory given as the file is unreadable and exits 1" {
  run bash "$VALIDATE" "$BATS_TEST_TMPDIR"
  [ "$status" -eq 1 ]
  assert_output_contains "cannot read file"
}

@test "several clean files: one PASS verdict per file and exit 0" {
  local second="$BATS_TEST_TMPDIR/second.json"
  write_valid
  cp "$F" "$second"
  run bash "$VALIDATE" "$F" "$second"
  [ "$status" -eq 0 ]
  assert_output_contains "PASS $F"
  assert_output_contains "PASS $second"
}

@test "several files with one bad: a verdict per file and a non-zero exit, in either order" {
  local good="$BATS_TEST_TMPDIR/good.json" bad="$BATS_TEST_TMPDIR/bad.json"
  write_valid
  cp "$F" "$good"
  mutate '.items[0].enforcement = "nope"'
  mv "$F" "$bad"

  run bash "$VALIDATE" "$good" "$bad"
  [ "$status" -eq 1 ]
  assert_output_contains "PASS $good"
  assert_output_contains "FAIL $bad"

  run bash "$VALIDATE" "$bad" "$good"
  [ "$status" -eq 1 ]
  assert_output_contains "PASS $good"
  assert_output_contains "FAIL $bad"
}

@test "errors are attributed to the file they came from when several files are validated" {
  local bad_a="$BATS_TEST_TMPDIR/a.json" bad_b="$BATS_TEST_TMPDIR/b.json"
  mutate '.items[0].enforcement = "nope"'
  mv "$F" "$bad_a"
  mutate '.items[0].tick_scope = "nope"'
  mv "$F" "$bad_b"
  run --separate-stderr bash "$VALIDATE" "$bad_a" "$bad_b"
  [ "$status" -eq 1 ]
  assert_contains "$stderr" "$bad_a: bad enforcement"
  assert_contains "$stderr" "$bad_b: bad tick_scope"
  assert_not_contains "$stderr" "$bad_a: bad tick_scope"
  assert_not_contains "$stderr" "$bad_b: bad enforcement"
}

@test "the two real registries validate clean together in one invocation" {
  run bash "$VALIDATE" "$REPO_ROOT/templates/checklists.json" "$REPO_ROOT/project/configs/checklists.json"
  [ "$status" -eq 0 ]
  assert_output_contains "PASS $REPO_ROOT/templates/checklists.json"
  assert_output_contains "PASS $REPO_ROOT/project/configs/checklists.json"
}

# -----------------------------------------------------------------------------
# Provenance (E67_S05_T01; schema doc section 9, "Provenance fields")
# -----------------------------------------------------------------------------

# Rewrites $F so item 0 carries a valid suggested provenance, then applies the given jq filter (default none).
mutate_prov() {
  mutate '.items[0].provenance = {"source": "suggested", "suggested_by": "developer", "origin": "precautionary", "evidence": "scripts/release.sh exits 0 when the tag push fails", "accepted_on": "2026-10-03"}'
  if [ -n "${1:-}" ]; then
    jq "$1" "$F" > "$F.new" && mv "$F.new" "$F"
  fi
}

@test "provenance: an authored item with no provenance key is still valid" {
  write_valid
  run bash "$VALIDATE" "$F"
  [ "$status" -eq 0 ]
  assert_output_contains "PASS $F"
}

@test "provenance: source authored is valid on its own, with nothing else required" {
  mutate '.items[0].provenance = {"source": "authored"}'
  run bash "$VALIDATE" "$F"
  [ "$status" -eq 0 ]
}

@test "provenance: a valid precautionary suggested item passes" {
  mutate_prov
  run --separate-stderr bash "$VALIDATE" "$F"
  [ "$status" -eq 0 ]
  assert_contains "$output" "PASS $F"
  [ -z "$stderr" ]
}

@test "provenance: a valid recurrence suggested item passes for each kind of incident (rapport path, SHA, task id)" {
  for ev in \
    "stale mirror shipped, see project/rapports/problems/E50_S07_T07-example.md" \
    "reverted in commit 1a2b3c4 after 2 failed releases" \
    "failed again on E67_S02_T03 with exit 7"; do
    mutate_prov ".items[0].provenance.origin = \"recurrence\" | .items[0].provenance.evidence = \"$ev\""
    run bash "$VALIDATE" "$F"
    [ "$status" -eq 0 ]
  done
}

@test "provenance: an accepted_on with a time part is accepted" {
  mutate_prov '.items[0].provenance.accepted_on = "2026-10-03T16:00:00Z"'
  run bash "$VALIDATE" "$F"
  [ "$status" -eq 0 ]
}

@test "provenance: a recurrence item whose evidence names no incident is rejected with its own message" {
  mutate_prov '.items[0].provenance.origin = "recurrence" | .items[0].provenance.evidence = "this broke before and it was annoying, 3 times"'
  run bash "$VALIDATE" "$F"
  [ "$status" -eq 1 ]
  assert_output_contains "recurrence without incident"
  assert_output_contains 'item "lint-clean"'
  assert_output_contains "FAIL $F"
}

@test "provenance: a recurrence item with no evidence at all reports both the missing field and the missing incident" {
  mutate_prov '.items[0].provenance.origin = "recurrence" | del(.items[0].provenance.evidence)'
  run bash "$VALIDATE" "$F"
  [ "$status" -eq 1 ]
  assert_output_contains "missing provenance field: evidence"
  assert_output_contains "recurrence without incident"
}

@test "provenance: a precautionary item needs no incident, a bare word or short number is not mistaken for a SHA" {
  mutate_prov '.items[0].provenance.evidence = "deadbeef-style naming and 2026 are not incidents but are enough for precautionary"'
  run bash "$VALIDATE" "$F"
  [ "$status" -eq 0 ]
  mutate_prov '.items[0].provenance.origin = "recurrence" | .items[0].provenance.evidence = "deadbeef and 2026 and 123456 are not incidents"'
  run bash "$VALIDATE" "$F"
  [ "$status" -eq 1 ]
  assert_output_contains "recurrence without incident"
}

@test "provenance: a provenance that is not an object is rejected" {
  mutate '.items[0].provenance = "shipped"'
  run bash "$VALIDATE" "$F"
  [ "$status" -eq 1 ]
  assert_output_contains "bad provenance: "
  assert_output_contains 'item "lint-clean"'
}

@test "provenance: a bad or absent source is rejected and names the value" {
  mutate '.items[0].provenance = {"source": "imported"}'
  run bash "$VALIDATE" "$F"
  [ "$status" -eq 1 ]
  assert_output_contains 'bad provenance source "imported"'
  mutate '.items[0].provenance = {"suggested_by": "developer"}'
  run bash "$VALIDATE" "$F"
  [ "$status" -eq 1 ]
  assert_output_contains "bad provenance source (absent)"
}

@test "provenance: source values are case-sensitive" {
  mutate '.items[0].provenance = {"source": "Suggested"}'
  run bash "$VALIDATE" "$F"
  [ "$status" -eq 1 ]
  assert_output_contains "bad provenance source"
}

@test "provenance: a bad or absent origin on a suggested item is rejected" {
  mutate_prov '.items[0].provenance.origin = "hunch"'
  run bash "$VALIDATE" "$F"
  [ "$status" -eq 1 ]
  assert_output_contains 'bad provenance origin "hunch"'
  mutate_prov 'del(.items[0].provenance.origin)'
  run bash "$VALIDATE" "$F"
  [ "$status" -eq 1 ]
  assert_output_contains "bad provenance origin (absent)"
}

@test "provenance: a suggested item missing suggested_by, evidence or accepted_on is rejected, each by name" {
  for field in suggested_by evidence accepted_on; do
    mutate_prov "del(.items[0].provenance.$field)"
    run bash "$VALIDATE" "$F"
    [ "$status" -eq 1 ]
    assert_output_contains "missing provenance field: $field"
  done
}

@test "provenance: an empty, whitespace-only or non-string required field counts as missing" {
  mutate_prov '.items[0].provenance.suggested_by = "" | .items[0].provenance.evidence = "   " | .items[0].provenance.accepted_on = 7'
  run bash "$VALIDATE" "$F"
  [ "$status" -eq 1 ]
  assert_output_contains "missing provenance field: suggested_by"
  assert_output_contains "missing provenance field: evidence"
  assert_output_contains "missing provenance field: accepted_on"
}

@test "provenance: an accepted_on that is not an ISO date is rejected" {
  mutate_prov '.items[0].provenance.accepted_on = "yesterday"'
  run bash "$VALIDATE" "$F"
  [ "$status" -eq 1 ]
  assert_output_contains 'bad accepted_on "yesterday"'
}

@test "provenance: an authored item is not required to carry suggested-only fields, and extra provenance keys are tolerated" {
  mutate '.items[0].provenance = {"source": "authored", "note": "hand written"}'
  run bash "$VALIDATE" "$F"
  [ "$status" -eq 0 ]
}

@test "provenance: a provenance error is attributed to the item and file it came from, and does not hide other errors" {
  mutate_prov '.items[0].provenance.origin = "hunch" | .items[1].kind = "auto"'
  run bash "$VALIDATE" "$F"
  [ "$status" -eq 1 ]
  assert_output_contains "$F: bad provenance origin"
  assert_output_contains "unknown kind"
}

# -----------------------------------------------------------------------------
# Provenance source "convention" (E69_S03_T01; schema doc section 9, "Provenance fields")
# -----------------------------------------------------------------------------

# Rewrites $F so item 0 carries a generated-item provenance for the given category, then applies a jq filter.
mutate_conv() {
  mutate '.items[0].provenance = {"source": "convention", "category": "naming"}'
  if [ -n "${1:-}" ]; then
    jq "$1" "$F" > "$F.new" && mv "$F.new" "$F"
  fi
}

@test "convention provenance: source convention with a non-empty category is valid, with nothing else required" {
  mutate_conv
  run bash "$VALIDATE" "$F"
  [ "$status" -eq 0 ]
  assert_output_contains "PASS $F"
}

@test "convention provenance: extra provenance keys are tolerated and no suggested-only field is required" {
  mutate_conv '.items[0].provenance.note = "generated"'
  run bash "$VALIDATE" "$F"
  [ "$status" -eq 0 ]
}

@test "convention provenance: a missing category is rejected with a message naming the item and the field" {
  mutate_conv 'del(.items[0].provenance.category)'
  run bash "$VALIDATE" "$F"
  [ "$status" -eq 1 ]
  assert_output_contains "missing provenance field: category"
  assert_output_contains 'item "'
}

@test "convention provenance: an empty, whitespace-only or non-string category is rejected" {
  local bad
  for bad in '""' '"   "' '7' 'null' '["naming"]'; do
    mutate_conv ".items[0].provenance.category = $bad"
    run bash "$VALIDATE" "$F"
    [ "$status" -eq 1 ]
    assert_output_contains "missing provenance field: category"
  done
}

@test "convention provenance: a bogus source is still rejected and the message lists all three accepted values" {
  mutate '.items[0].provenance = {"source": "bogus"}'
  run bash "$VALIDATE" "$F"
  [ "$status" -eq 1 ]
  assert_output_contains 'bad provenance source "bogus"'
  assert_output_contains '"authored", "suggested" or "convention"'
}

@test "convention provenance: the source value is case-sensitive" {
  mutate '.items[0].provenance = {"source": "Convention", "category": "naming"}'
  run bash "$VALIDATE" "$F"
  [ "$status" -eq 1 ]
  assert_output_contains "bad provenance source"
}

@test "convention provenance: no enforcement rule applies, a hand-raised block item still validates (pinned judgment call)" {
  mutate_conv '.items[0].enforcement = "block"'
  run bash "$VALIDATE" "$F"
  [ "$status" -eq 0 ]
}

@test "convention provenance: the suggested rules do not leak onto a convention item" {
  mutate_conv '.items[0].provenance.origin = "hunch" | .items[0].provenance.accepted_on = "yesterday"'
  run bash "$VALIDATE" "$F"
  [ "$status" -eq 0 ]
}

@test "convention provenance: scripts/checklist.sh list accepts a registry holding a convention item, unmodified" {
  local proj="$BATS_TEST_TMPDIR/proj"
  mkdir -p "$proj/project/configs"
  echo '{}' > "$proj/project/configs/workflow.json"
  mutate_conv '.items[0].id = "conv-naming"'
  run --separate-stderr env JENGA_PROJECT_ROOT="$proj" JENGA_CHECKLISTS_FILE="$F" \
    JENGA_CHECKLISTS_DEFAULT_FILE="$BATS_TEST_TMPDIR/none.json" \
    JENGA_CHECKLIST_STATE_DIR="$BATS_TEST_TMPDIR/state" \
    bash "$REPO_ROOT/scripts/checklist.sh" list pre-commit
  [ "$status" -eq 0 ]
  assert_output_contains "conv-naming"
}
