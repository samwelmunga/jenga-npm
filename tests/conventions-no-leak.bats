#!/usr/bin/env bats
#
# No project-specific convention may leak into a file shipped through /j-mirror-public (E69_S06_T05).
#
# Why: project/configs/ and templates/ ship downstream (E67 section 8 of project/documentation/preflight-checklists.md),
# so a shipped default must be generic. This suite checks the root tree:
#   1. the five shipped convention files carry none of THIS repository's identifying content (a denylist built here
#      from this repo's own values) and no absolute path;
#   2. this repository records no conventions.json instance (or, if one is ever added, .publicignore blocks it);
#   3. the shipped checklist default has no conv- item and no provenance.source "convention";
#   4. .publicignore does not block any new shipped file, skills/j-conventions/, or the subject (script or skill)
#      of any tests/conventions-*.bats file, which would trip mirror.sh's check_test_subject_invariant (see
#      tests/mirror-test-subject-invariant.bats and the header of .publicignore).
#
# Board ids: a shipped file may cite the task that created it in a `_comment` or `note` metadata string; that is
# provenance, not a convention, and is the only place a concrete board id is tolerated (the documented EST
# placeholder E##_S##_T## has no digits and never matches). No test here writes anything outside $BATS_TEST_TMPDIR.

bats_require_minimum_version 1.5.0
load helpers/assertions

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
MATCH="$REPO_ROOT/scripts/check-publicignore-match.sh"
PUBLICIGNORE="$REPO_ROOT/.publicignore"

SHIPPED_FILES="templates/conventions.json templates/conventions-presets.json templates/conventions-checklist-map.json templates/conventions-schema.json templates/config-descriptors/conventions.json"

# --- helpers ---------------------------------------------------------------------------------------------------

# denylist: this repository's own identifying values, one per line. Built from the repo itself so it follows it:
# the maintainer handle, private paths, the package name, every package.json script command and key, and the id of every project checklist item that is not in the shipped default.
denylist() {
  printf '%s\n' "samwelmunga" "project/board" "project/queue" "project/rapports" "project/logs"
  if [ -f "$REPO_ROOT/package.json" ]; then
    jq -r '.name // empty' "$REPO_ROOT/package.json"
    jq -r '(.scripts // {}) | to_entries[] | .value, "npm run \(.key)"' "$REPO_ROOT/package.json"
  fi
  if [ -f "$REPO_ROOT/project/configs/checklists.json" ] && [ -f "$REPO_ROOT/templates/checklists.json" ]; then
    jq -r --slurpfile d "$REPO_ROOT/templates/checklists.json" \
      '[.items[].id] - [$d[0].items[].id] | .[]' "$REPO_ROOT/project/configs/checklists.json"
  fi
}

# leaks <file>: print every denylist entry (at least 6 characters, to avoid matching short common words) found in
# the file's text.
leaks() {
  local entry
  denylist | sort -u | while IFS= read -r entry; do
    [ "${#entry}" -ge 6 ] || continue
    if grep -qF -- "$entry" "$1"; then
      printf 'denylist entry %s\n' "$entry"
    fi
  done
}

# abs_paths <file>: print absolute-path occurrences (POSIX home/temp roots and Windows drive paths).
abs_paths() {
  grep -nE '(^|[^A-Za-z0-9_.:/-])(/Users/|/home/|/var/folders/|/private/|/tmp/|[A-Za-z]:\\)' "$1" || true
}

# board_ids_outside_metadata <file>: concrete board ids found in any string whose key is not _comment or note.
board_ids_outside_metadata() {
  jq -r '[paths(strings) as $p | {k: ($p | map(tostring) | last), v: getpath($p)}
          | select(.k != "_comment" and .k != "note")
          | .v | scan("E[0-9]{2}_S[0-9]{2}(_T[0-9]{2})?")] | unique | .[]' "$1"
}

need_publicignore() {
  [ -f "$PUBLICIGNORE" ] || skip ".publicignore is not present in this tree"
  [ -f "$MATCH" ] || skip "scripts/check-publicignore-match.sh is not present in this tree"
  command -v rsync >/dev/null 2>&1 || skip "rsync is not installed"
}

# classify <path>...: "PUBLIC<TAB>path" / "BLOCKED<TAB>path" lines.
classify() { (cd "$REPO_ROOT" && bash "$MATCH" "$@"); }

# --- 1. shipped files carry nothing project-specific -------------------------------------------------------------

@test "no-leak 1: all five shipped convention files exist and are valid JSON" {
  local f
  for f in $SHIPPED_FILES; do
    [ -f "$REPO_ROOT/$f" ]
    jq -e . "$REPO_ROOT/$f" >/dev/null
  done
}

@test "no-leak 2: the denylist is non-empty and built from this repository's own values" {
  run denylist
  [ "$status" -eq 0 ]
  assert_contains "$output" "samwelmunga"
  assert_contains "$output" "project/board"
  assert_contains "$output" "$(jq -r '.name' "$REPO_ROOT/package.json")"
  [ "$(printf '%s\n' "$output" | wc -l | tr -d ' ')" -ge 8 ]
}

@test "no-leak 3: the leak scanner is live (a planted entry and a planted absolute path are both caught)" {
  local planted="$BATS_TEST_TMPDIR/planted.json"
  printf '{"note_text": "see samwelmunga and %s", "path": "/Users/someone/project"}\n' \
    "$(jq -r '.name' "$REPO_ROOT/package.json")" > "$planted"
  run leaks "$planted"
  assert_contains "$output" "samwelmunga"
  assert_contains "$output" "$(jq -r '.name' "$REPO_ROOT/package.json")"
  run abs_paths "$planted"
  assert_contains "$output" "/Users/someone"
  local clean="$BATS_TEST_TMPDIR/clean.json"
  printf '{"text": "a generic convention"}\n' > "$clean"
  run leaks "$clean"
  [ -z "$output" ]
  run abs_paths "$clean"
  [ -z "$output" ]
}

@test "no-leak 4: none of the five shipped files contains an entry from this repository's denylist" {
  local f found=""
  for f in $SHIPPED_FILES; do
    found="$found$(leaks "$REPO_ROOT/$f" | sed "s#^#$f: #")
"
  done
  found="$(printf '%s\n' "$found" | sed '/^$/d')"
  if [ -n "$found" ]; then
    printf '%s\n' "$found" >&2
    return 1
  fi
}

@test "no-leak 5: none of the five shipped files contains an absolute path" {
  local f found=""
  for f in $SHIPPED_FILES; do
    found="$found$(abs_paths "$REPO_ROOT/$f" | sed "s#^#$f: #")
"
  done
  found="$(printf '%s\n' "$found" | sed '/^$/d')"
  if [ -n "$found" ]; then
    printf '%s\n' "$found" >&2
    return 1
  fi
}

@test "no-leak 6: concrete board ids appear in the shipped files only inside _comment or note metadata" {
  local f ids
  for f in $SHIPPED_FILES; do
    ids="$(board_ids_outside_metadata "$REPO_ROOT/$f")"
    if [ -n "$ids" ]; then
      printf '%s: board id outside metadata: %s\n' "$f" "$ids" >&2
      return 1
    fi
  done
}

@test "no-leak 7: the shipped default conventions.json records nothing" {
  [ "$(jq -S -c . "$REPO_ROOT/templates/conventions.json")" = '{"categories":{},"conventions_version":1}' ]
}

@test "no-leak 8: no shipped preset carries a command that could run blindly (placeholders only)" {
  [ "$(jq -r '[.categories[][].values | to_entries[] | select(.key | test("_command$")) | .value
               | select(test("^<[^<>]*>$") | not)] | length' "$REPO_ROOT/templates/conventions-presets.json")" = "0" ]
}

# --- 2. this repository holds no instance ------------------------------------------------------------------------

@test "no-leak 9: this repository has no project/configs/conventions.json (or .publicignore blocks it)" {
  if [ ! -e "$REPO_ROOT/project/configs/conventions.json" ]; then
    # case A: no instance exists, which is what the epic requires
    return 0
  fi
  need_publicignore
  run classify project/configs/conventions.json
  if ! printf '%s' "$output" | grep -q '^BLOCKED'; then
    echo "case B failed: project/configs/conventions.json exists and .publicignore does not block it" >&2
    return 1
  fi
}

# --- 3. the shipped checklist default has no generated item ------------------------------------------------------

@test "no-leak 10: templates/checklists.json has no conv- item and no convention provenance" {
  local reg="$REPO_ROOT/templates/checklists.json"
  [ "$(jq -r '[.items[] | select(.id | startswith("conv-"))] | length' "$reg")" = "0" ]
  [ "$(jq -r '[.items[] | select(.provenance.source == "convention")] | length' "$reg")" = "0" ]
}

# --- 4. .publicignore lets the feature ship, and strands no test -------------------------------------------------

@test "no-leak 11: .publicignore blocks none of the shipped convention files or skills/j-conventions/" {
  need_publicignore
  local paths="$SHIPPED_FILES scripts/validate-conventions.sh scripts/generate-convention-checklist.sh scripts/conventions-digest.sh scripts/conventions-suggest.sh skills/j-commit/scripts/commit-subject-check.sh"
  local p
  for p in skills/j-conventions/SKILL.md skills/j-conventions/scripts/detect-conventions.sh skills/j-conventions/scripts/conventions-entry.sh; do
    paths="$paths $p"
  done
  # shellcheck disable=SC2086
  run classify $paths
  [ "$status" -eq 0 ]
  assert_not_contains "$output" "BLOCKED"
  [ "$(printf '%s\n' "$output" | grep -c '^PUBLIC')" -eq 13 ]
}

@test "no-leak 12: the conventions documentation ships, while the private plans and summaries do not" {
  need_publicignore
  run classify project/documentation/project-conventions.md project/documentation/preflight-checklists.md
  assert_not_contains "$output" "BLOCKED"
  # sanity for the classifier itself: a path the file does block is reported as blocked
  run classify project/board
  assert_contains "$output" "BLOCKED"
}

@test "no-leak 13: every tests/conventions-*.bats file ships and so does every file it executes (no stranded test)" {
  need_publicignore
  local t refs ref blocked=""
  for t in "$REPO_ROOT"/tests/conventions-*.bats; do
    run classify "tests/$(basename "$t")"
    assert_not_contains "$output" "BLOCKED"
    # repo files the test refers to through $REPO_ROOT, which exist and are files
    refs="$(grep -oE 'REPO_ROOT"?/[A-Za-z0-9_./-]+' "$t" | sed -e 's#^REPO_ROOT"\{0,1\}/##' | sort -u)"
    for ref in $refs; do
      [ -f "$REPO_ROOT/$ref" ] || continue
      run classify "$ref"
      if printf '%s' "$output" | grep -q '^BLOCKED'; then
        blocked="$blocked $(basename "$t"): $ref"
      fi
    done
  done
  if [ -n "$blocked" ]; then
    printf 'tests whose subject is blocklisted in .publicignore:%s\n' "$blocked" >&2
    return 1
  fi
}

@test "no-leak 14: this test file and the e2e test ship" {
  need_publicignore
  run classify tests/conventions-no-leak.bats tests/conventions-e2e.bats
  assert_not_contains "$output" "BLOCKED"
}
