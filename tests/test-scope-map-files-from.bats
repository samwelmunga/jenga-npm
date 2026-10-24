#!/usr/bin/env bats
#
# Coverage for map-scope.sh's additive --files-from <file> change source (E72_S06_T03).
#
# Contract under test: the script's header. `--files-from <f>` takes the changed files from a list (one root-relative path
# per line, blank lines ignored) instead of from git, so a caller that unioned several commits (scope-test-gate.sh) can map
# them in a single call. It is one more change source: the at-most-one rule covers it, a missing file is exit 3, an empty
# list is the usual `No changed files` result, and the other four sources are unaffected (their own suites stay green).
#
# Every repository is built inside BATS_TEST_TMPDIR with git isolated from the host; discovery is an inline JSON fixture
# handed to --suites, so the real discover-tests.sh never runs. Assertions use `[ ]` and tests/helpers/assertions.bash.

bats_require_minimum_version 1.5.0

load helpers/assertions

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd -P)"
MAPPER="$REPO_ROOT/skills/j-test/scripts/map-scope.sh"

SUITES='{"suites":[
  {"id":"bats:alpha","command":"echo alpha","paths":["alpha/*.bats"]},
  {"id":"bats:beta","command":"echo beta","paths":["beta/*.bats"]}]}'
MAP_JSON='{"map_version":1,"rules":[
  {"source":"src/alpha/*.sh","tests":["alpha/*.bats"]},
  {"source":"src/beta/*.sh","tests":["beta/*.bats"]}]}'

setup() {
  export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null GIT_CONFIG_NOSYSTEM=1
  unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE
  REPO="$BATS_TEST_TMPDIR/repo"
  SUITES_FILE="$BATS_TEST_TMPDIR/suites.json"
  MAP="$BATS_TEST_TMPDIR/map.json"
  LIST="$BATS_TEST_TMPDIR/files.txt"
  printf '%s' "$SUITES" > "$SUITES_FILE"
  printf '%s' "$MAP_JSON" > "$MAP"
  mkdir -p "$REPO/alpha" "$REPO/beta" "$REPO/src/alpha" "$REPO/src/beta"
  git -C "$REPO" init -q
  git -C "$REPO" config user.name "Fixture"
  git -C "$REPO" config user.email "fixture@example.invalid"
  git -C "$REPO" config commit.gpgsign false
  for f in alpha/a.bats beta/b.bats src/alpha/a.sh src/beta/b.sh README.md; do
    printf 'x\n' > "$REPO/$f"
  done
  git -C "$REPO" add -A
  git -C "$REPO" commit -q -m seed
}

# map_files [args...]: map-scope.sh over $LIST; sets status, output, stderr.
map_files() {
  run --separate-stderr bash "$MAPPER" --root "$REPO" --suites "$SUITES_FILE" --map "$MAP" --files-from "$LIST" "$@"
}

@test "the listed files are mapped without any git change" {
  printf 'src/alpha/a.sh\n' > "$LIST"
  map_files
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -c .mapped_suites)" = '["bats:alpha"]' ]
  [ "$(printf '%s' "$output" | jq -c .unmapped_files)" = '[]' ]
}

@test "files from several areas map to the union of their suites" {
  printf 'src/beta/b.sh\nsrc/alpha/a.sh\nREADME.md\n' > "$LIST"
  map_files
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -c .mapped_suites)" = '["bats:alpha","bats:beta"]' ]
  [ "$(printf '%s' "$output" | jq -c .unmapped_files)" = '["README.md"]' ]
}

@test "blank lines and duplicates are harmless" {
  printf '\nsrc/alpha/a.sh\n\nsrc/alpha/a.sh\n\n' > "$LIST"
  map_files
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -c .mapped_suites)" = '["bats:alpha"]' ]
}

@test "CRLF line endings are tolerated" {
  printf 'src/beta/b.sh\r\n' > "$LIST"
  map_files
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -c .mapped_suites)" = '["bats:beta"]' ]
}

@test "an empty list is the No changed files result" {
  : > "$LIST"
  map_files
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -c .mapped_suites)" = '[]' ]
  [ "$(printf '%s' "$output" | jq -c .warnings)" = '["No changed files"]' ]
}

@test "a list of files that map to nothing carries the zero-mapped warning" {
  printf 'README.md\n' > "$LIST"
  map_files
  [ "$status" -eq 0 ]
  assert_output_contains "No tests found for the changed files"
}

@test "a missing list file is exit 3" {
  rm -f "$LIST"
  map_files
  [ "$status" -eq 3 ]
  assert_contains "$stderr" "--files-from"
  [ "$output" = "" ]
}

@test "--files-from needs an argument (exit 2)" {
  run --separate-stderr bash "$MAPPER" --root "$REPO" --suites "$SUITES_FILE" --map "$MAP" --files-from
  [ "$status" -eq 2 ]
  assert_contains "$stderr" "--files-from requires a file argument"
}

@test "--files-from counts as a change source: combining it with another is exit 2" {
  printf 'src/alpha/a.sh\n' > "$LIST"
  map_files --staged
  [ "$status" -eq 2 ]
  assert_contains "$stderr" "at most one of"
}

@test "--help documents --files-from" {
  run bash "$MAPPER" --help
  [ "$status" -eq 0 ]
  assert_output_contains "--files-from"
}

@test "the other change sources still work next to it" {
  printf 'changed\n' >> "$REPO/src/beta/b.sh"
  git -C "$REPO" add -A
  git -C "$REPO" commit -q -m "edit beta"
  run --separate-stderr bash "$MAPPER" --root "$REPO" --suites "$SUITES_FILE" --map "$MAP" --rev HEAD
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -c .mapped_suites)" = '["bats:beta"]' ]
}
