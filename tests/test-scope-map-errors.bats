#!/usr/bin/env bats
#
# Failure, degradation and stability coverage for skills/j-test/scripts/map-scope.sh (E72_S03_T04).
#
# The script is built by E72_S03_T02 and reads the discovery `paths` field added by E72_S03_T01. What a rule maps to
# is E72_S03_T03's file (tests/test-scope-map-mapping.bats) and is deliberately not repeated here. This file covers
# how the script FAILS (exit codes, empty stdout, the message naming the file and the 1-based rule index), how it
# DEGRADES (an unreadable test-config.json, no suites, deleted files, unusual names), that it is STABLE (byte-identical
# output across runs and locales, sorted arrays, no absolute path), that it is READ-ONLY and never EXECUTES project
# code, that the shipped templates/test-scope-map.json still passes its validation, and one end-to-end run through the
# real discover-tests.sh.
#
# How the cases are written
#   - Every repository is built inside BATS_TEST_TMPDIR by this file's own make_repo; nothing is written elsewhere and
#     the repository under test is never touched. The host's git config, hooks and signing are kept out of the
#     fixtures (GIT_CONFIG_GLOBAL, GIT_CONFIG_NOSYSTEM, `git init --template=`, a fixed identity).
#   - Output that has a shape is checked with `jq -e`, never as a substring of the raw text. Where byte stability is
#     the claim, two runs are written to files and compared with `cmp`.
#   - Mapping files are written outside the fixture repository, so they never show up in its git status.
#   - The script is run as `bash <path>`, never directly.

bats_require_minimum_version 1.5.0

load helpers/assertions

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd -P)"
MAP_SCOPE="$REPO_ROOT/skills/j-test/scripts/map-scope.sh"
TEMPLATE="$REPO_ROOT/templates/test-scope-map.json"
BASH_BIN="$(command -v bash)"

# One valid rule, used as rule 1 of every invalid-map fixture so a failing rule is always rule 2 (a wrong index of 1
# or 0 would be caught).
GOOD_RULE='{"source":"scripts/*.sh","tests":["tests/*.bats"]}'
EMPTY_SHAPE='{"mapped_suites":[],"mapped_tests":{},"unmapped_files":[],"warnings":["No changed files"]}'
# The fragment of the message for a glob using any of [ ] { } and a backslash.
BRACKET_MSG="uses one of [ ] { } \\"

setup() {
  export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
  export GIT_AUTHOR_NAME=fixture GIT_AUTHOR_EMAIL=fixture@example.invalid
  export GIT_COMMITTER_NAME=fixture GIT_COMMITTER_EMAIL=fixture@example.invalid
  REPO="$BATS_TEST_TMPDIR/repo"
  SUITES="$BATS_TEST_TMPDIR/suites.json"
  OK_MAP="$BATS_TEST_TMPDIR/ok-map.json"
  LOCKED_FILE=""
  printf '%s\n' '{"suites":[{"id":"bats:tests","command":"bats tests/*.bats","paths":["tests/*.bats"]},{"id":"npm:test","command":"npm test"}]}' > "$SUITES"
  write_map "$OK_MAP" "{\"map_version\":1,\"rules\":[$GOOD_RULE]}"
}

# An unreadable file must never outlive a test: bats removes BATS_TEST_TMPDIR afterwards.
teardown() {
  if [ -n "${LOCKED_FILE:-}" ] && [ -e "$LOCKED_FILE" ]; then
    chmod u+rw "$LOCKED_FILE" || true
  fi
}

# --- helpers -------------------------------------------------------------------------------------------------------

# write_map <file> <json>
write_map() {
  mkdir -p "$(dirname "$1")"
  printf '%s\n' "$2" > "$1"
}

# commit_all <message> [git commit args...]: stage everything in $REPO and commit it.
commit_all() {
  local msg="$1"
  shift
  git -C "$REPO" add -A
  git -C "$REPO" commit -q -m "$msg" "$@"
}

# make_repo: $REPO with two commits. HEAD changes scripts/x.sh; tests/a.bats exists.
make_repo() {
  mkdir -p "$REPO"
  git init -q --template= "$REPO"
  mkdir -p "$REPO/scripts" "$REPO/tests"
  printf '#!/bin/sh\necho one\n' > "$REPO/scripts/x.sh"
  printf '@test "a" { true; }\n' > "$REPO/tests/a.bats"
  commit_all "initial"
  printf 'echo two\n' >> "$REPO/scripts/x.sh"
  commit_all "change x.sh"
}

# write_config <json>: the project's test-config.json (the path discovery and the mapper both read).
write_config() {
  mkdir -p "$REPO/project/configs"
  printf '%s\n' "$1" > "$REPO/project/configs/test-config.json"
}

# with_stdin <file> <command...>: run the command with the file as its standard input.
with_stdin() {
  local f="$1"
  shift
  "$@" < "$f"
}

# map_scope <args...>: run the script; sets $status, $output (stdout) and $stderr.
map_scope() {
  run --separate-stderr "$BASH_BIN" "$MAP_SCOPE" "$@"
}

# scope_norev <args...>: root, suites and map, but no change source, so the caller supplies one.
scope_norev() {
  map_scope --root "$REPO" --suites "$SUITES" --map "$OK_MAP" "$@"
}

# scope_nomap <args...>: root, HEAD and suites but no --map, so mapping-file resolution is what is under test.
scope_nomap() {
  map_scope --root "$REPO" --rev HEAD --suites "$SUITES" "$@"
}

# scope <args...>: the default invocation; a later --map or --suites argument overrides these, and an extra change
# source makes two (exit 2).
scope() {
  scope_nomap --map "$OK_MAP" "$@"
}

# json_check <jq filter> [jq args...]: the filter must be truthy against $output (jq -e).
json_check() {
  local filter="$1"
  shift
  if ! printf '%s' "$output" | jq -e "$@" "$filter" > /dev/null; then
    echo "jq assertion failed: $filter"
    echo "--- output ---"
    echo "$output"
    return 1
  fi
}

# expect_exit3 <stderr fragment>...: exit 3, nothing on stdout, and every fragment in stderr.
expect_exit3() {
  local fragment
  [ "$status" -eq 3 ]
  [ -z "$output" ]
  for fragment in "$@"; do
    assert_contains "$stderr" "$fragment"
  done
}

# invalid_map <json> <rule number, or - for a file-level problem> <message fragment>: a map file named bad-map.json
# holding <json> is rejected with exit 3, empty stdout, and stderr naming the file, the rule index and the problem.
invalid_map() {
  local json="$1" rule="$2" fragment="$3"
  # Map validation runs after the change set is acquired, so a repository with a HEAD must exist first.
  [ -d "$REPO/.git" ] || make_repo
  write_map "$BATS_TEST_TMPDIR/bad-map.json" "$json"
  scope --map "$BATS_TEST_TMPDIR/bad-map.json"
  expect_exit3 "bad-map.json" "$fragment"
  if [ "$rule" != "-" ]; then
    assert_contains "$stderr" "rule $rule:"
  fi
}

# rule2 <rule json>: a two-rule map whose second rule is the one given.
rule2() {
  printf '{"map_version":1,"rules":[%s,%s]}' "$GOOD_RULE" "$1"
}

# glob_case <source|tests> <glob> <message fragment>: the glob placed in rule 2's `source` (or in its `tests`) is
# rejected. The map is built with jq so a backslash or a quote survives into the JSON.
glob_case() {
  local place="$1" glob="$2" fragment="$3" json
  if [ "$place" = "source" ]; then
    json="$(jq -nc --arg g "$glob" --argjson r1 "$GOOD_RULE" \
      '{map_version:1,rules:[$r1,{source:$g,tests:["tests/*.bats"]}]}')"
  else
    json="$(jq -nc --arg g "$glob" --argjson r1 "$GOOD_RULE" \
      '{map_version:1,rules:[$r1,{source:"docs/*.md",tests:["tests/*.bats",$g]}]}')"
  fi
  invalid_map "$json" 2 "$fragment"
}

# lock_file <path>: make the file unreadable (chmod 000), restored by teardown. Skips, with a message, where that
# cannot be done: as root, where chmod is refused, or where the file stays readable. Never passes vacuously.
lock_file() {
  if [ "$(id -u)" -eq 0 ]; then
    skip "running as root: chmod 000 does not make a file unreadable"
  fi
  if ! chmod 000 "$1" 2> /dev/null; then
    skip "chmod was refused in this environment, so the unreadable-file case cannot run"
  fi
  LOCKED_FILE="$1"
  if [ -r "$1" ]; then
    skip "the file is still readable after chmod 000 (ACLs or a permissive filesystem)"
  fi
}

# ===================================================================================================================
# Mapping validation: exit 3, stdout empty, stderr names the file and the 1-based rule index
# ===================================================================================================================

@test "validation: invalid JSON is exit 3 naming the file" {
  invalid_map '{not json' - "not valid JSON"
}

@test "validation: an empty file is not valid JSON" {
  invalid_map '' - "not valid JSON"
}

@test "validation: a top-level array is rejected" {
  invalid_map '[]' - "top-level value is not an object"
}

@test "validation: two JSON documents in one file are rejected" {
  invalid_map '{} {}' - "file must hold exactly one JSON value"
}

@test "validation: map_version missing is rejected" {
  invalid_map "{\"rules\":[$GOOD_RULE]}" - "map_version is missing or not 1"
}

@test "validation: map_version 2 is rejected" {
  invalid_map "{\"map_version\":2,\"rules\":[$GOOD_RULE]}" - "map_version is missing or not 1"
}

@test "validation: map_version as a string is rejected" {
  invalid_map "{\"map_version\":\"1\",\"rules\":[$GOOD_RULE]}" - "map_version is missing or not 1"
}

@test "validation: rules missing is rejected" {
  invalid_map '{"map_version":1}' - "rules is missing or not an array"
}

@test "validation: rules that is not an array is rejected" {
  invalid_map '{"map_version":1,"rules":{"source":"a","tests":["b"]}}' - "rules is missing or not an array"
}

@test "validation: an empty rules array is rejected" {
  invalid_map '{"map_version":1,"rules":[]}' - "rules is empty"
}

@test "validation: a rule that is not an object names its 1-based index" {
  invalid_map "{\"map_version\":1,\"rules\":[$GOOD_RULE,\"scripts/*.sh\"]}" 2 "not an object"
}

@test "validation: an unknown rule key is rejected and named" {
  invalid_map "$(rule2 '{"source":"docs/*.md","tests":["tests/*.bats"],"extra":1}')" 2 'unknown key "extra"'
}

@test "validation: an empty source is rejected" {
  invalid_map "$(rule2 '{"source":"","tests":["tests/*.bats"]}')" 2 "source must be a non-empty string"
}

@test "validation: a non-string source is rejected" {
  invalid_map "$(rule2 '{"source":5,"tests":["tests/*.bats"]}')" 2 "source must be a non-empty string"
}

@test "validation: a missing source is rejected" {
  invalid_map "$(rule2 '{"tests":["tests/*.bats"]}')" 2 "source must be a non-empty string"
}

@test "validation: an empty tests array is rejected" {
  invalid_map "$(rule2 '{"source":"docs/*.md","tests":[]}')" 2 "tests must be a non-empty array of non-empty strings"
}

@test "validation: tests that is not an array is rejected" {
  invalid_map "$(rule2 '{"source":"docs/*.md","tests":"tests/*.bats"}')" 2 "tests must be a non-empty array of non-empty strings"
}

@test "validation: a missing tests key is rejected" {
  invalid_map "$(rule2 '{"source":"docs/*.md"}')" 2 "tests must be a non-empty array of non-empty strings"
}

@test "validation: an empty entry in tests is rejected" {
  invalid_map "$(rule2 '{"source":"docs/*.md","tests":["tests/*.bats",""]}')" 2 "tests must be a non-empty array of non-empty strings"
}

@test "validation: a non-string entry in tests is rejected" {
  invalid_map "$(rule2 '{"source":"docs/*.md","tests":["tests/*.bats",7]}')" 2 "tests must be a non-empty array of non-empty strings"
}

@test "validation: the failing rule's index is reported even when it is the third" {
  invalid_map "{\"map_version\":1,\"rules\":[$GOOD_RULE,$GOOD_RULE,{\"source\":\"a\",\"tests\":[]}]}" 3 "tests must be a non-empty array"
}

@test "validation: an invalid map is rejected even when the change set is empty" {
  make_repo
  commit_all "empty" --allow-empty
  write_map "$BATS_TEST_TMPDIR/bad-map.json" '{not json'
  scope --map "$BATS_TEST_TMPDIR/bad-map.json"
  expect_exit3 "bad-map.json" "not valid JSON"
}

@test "validation: a leading ! is rejected and the message says negation is unsupported in map_version 1" {
  make_repo
  glob_case source '!docs/*.md' 'negation is not supported in map_version 1'
  glob_case tests '!tests/skip.bats' 'negation is not supported in map_version 1'
}

@test "validation: a [a] character class is rejected" {
  make_repo
  glob_case source 'src/[a].js' "$BRACKET_MSG"
  glob_case tests 'tests/[a].bats' "$BRACKET_MSG"
}

@test "validation: a {a,b} brace set is rejected" {
  make_repo
  glob_case source 'src/{a,b}.js' "$BRACKET_MSG"
  glob_case tests 'tests/{a,b}.bats' "$BRACKET_MSG"
}

@test "validation: a backslash is rejected" {
  make_repo
  glob_case source 'src\a.js' "$BRACKET_MSG"
  glob_case tests 'tests\a.bats' "$BRACKET_MSG"
}

@test "validation: a leading / is rejected" {
  make_repo
  glob_case source '/abs/x.js' 'begins with "/"'
  glob_case tests '/abs/x.bats' 'begins with "/"'
}

@test "validation: a leading ./ is rejected" {
  make_repo
  glob_case source './src/a.js' 'begins with "./"'
  glob_case tests './tests/a.bats' 'begins with "./"'
}

@test "validation: a .. segment is rejected" {
  make_repo
  glob_case source 'src/../a.js' 'has a ".." segment'
  glob_case tests 'tests/../a.bats' 'has a ".." segment'
}

@test "validation: ** inside a segment is rejected" {
  make_repo
  glob_case source 'src/a**b.js' 'uses "**" inside a segment'
  glob_case tests 'tests/a**b.bats' 'uses "**" inside a segment'
}

@test "validation: a literal path with no wildcard is accepted" {
  make_repo
  write_map "$BATS_TEST_TMPDIR/literal-map.json" '{"map_version":1,"rules":[{"source":"scripts/x.sh","tests":["tests/a.bats"]}]}'
  scope --map "$BATS_TEST_TMPDIR/literal-map.json"
  [ "$status" -eq 0 ]
  [ -z "$stderr" ]
  json_check '.mapped_suites == ["bats:tests"] and .mapped_tests == {"bats:tests":["tests/a.bats"]}'
}

# ===================================================================================================================
# Mapping file resolution failures
# ===================================================================================================================

@test "resolution: --map naming a nonexistent file is exit 3 naming that file" {
  make_repo
  scope --map "$BATS_TEST_TMPDIR/nope.json"
  expect_exit3 "nope.json" "missing or unreadable"
}

@test "resolution: commit_scope_map_file naming a nonexistent file is exit 3 and never falls back to the template" {
  make_repo
  write_config '{"commit_scope_map_file":"maps/missing.json"}'
  scope_nomap
  expect_exit3 "maps/missing.json" "commit_scope_map_file"
  assert_not_contains "$stderr" "default scope map"
  # Control: with the key removed the same repository maps through the default table, so the exit 3 above was the
  # configured file's doing and not a repository that cannot map at all.
  write_config '{}'
  scope_nomap
  [ "$status" -eq 0 ]
  json_check '.mapped_suites == ["bats:tests"]'
}

@test "resolution: commit_scope_map_file is read from test-config.json and resolves against the root" {
  make_repo
  write_map "$REPO/maps/ok.json" "{\"map_version\":1,\"rules\":[$GOOD_RULE]}"
  write_config '{"commit_scope_map_file":"maps/ok.json"}'
  scope_nomap
  [ "$status" -eq 0 ]
  json_check '.mapped_suites == ["bats:tests"] and .warnings == []'
}

@test "resolution: an absolute path in commit_scope_map_file is rejected even when the file exists" {
  make_repo
  write_config "{\"commit_scope_map_file\":\"$OK_MAP\"}"
  scope_nomap
  expect_exit3 "commit_scope_map_file" "relative to the root"
}

@test "resolution: a .. path in commit_scope_map_file is rejected even when the target exists" {
  make_repo
  write_config '{"commit_scope_map_file":"../ok-map.json"}'
  scope_nomap
  expect_exit3 "commit_scope_map_file" "must not contain '..' segments"
  write_config '{"commit_scope_map_file":"maps/../../ok-map.json"}'
  scope_nomap
  expect_exit3 "commit_scope_map_file" "must not contain '..' segments"
}

@test "resolution: a non-.json value in commit_scope_map_file is rejected" {
  make_repo
  write_map "$REPO/maps/map.txt" "{\"map_version\":1,\"rules\":[$GOOD_RULE]}"
  write_config '{"commit_scope_map_file":"maps/map.txt"}'
  scope_nomap
  expect_exit3 "commit_scope_map_file" "must end in .json"
}

@test "resolution: a non-string commit_scope_map_file is rejected" {
  make_repo
  write_config '{"commit_scope_map_file":5}'
  scope_nomap
  expect_exit3 "commit_scope_map_file" "must be a string path"
}

@test "resolution: an unreadable map file is exit 3 (chmod 000)" {
  make_repo
  write_map "$BATS_TEST_TMPDIR/locked-map.json" "{\"map_version\":1,\"rules\":[$GOOD_RULE]}"
  lock_file "$BATS_TEST_TMPDIR/locked-map.json"
  scope --map "$BATS_TEST_TMPDIR/locked-map.json"
  expect_exit3 "locked-map.json" "unreadable"
}

@test "resolution: an unreadable test-config.json degrades to the shipped template with a warning, exit 0 (chmod 000)" {
  make_repo
  # If the config were readable, this nonexistent target would be exit 3; reaching exit 0 proves it was not read.
  write_config '{"commit_scope_map_file":"maps/other.json"}'
  lock_file "$REPO/project/configs/test-config.json"
  scope_nomap
  [ "$status" -eq 0 ]
  [ -z "$stderr" ]
  json_check '.mapped_suites == ["bats:tests"] and (.warnings | index("test-config.json could not be read; using the default scope map")) != null'
}

@test "resolution: an invalid or non-object test-config.json degrades the same way" {
  make_repo
  write_config 'not json'
  scope_nomap
  [ "$status" -eq 0 ]
  json_check '.mapped_suites == ["bats:tests"] and (.warnings | index("test-config.json could not be read; using the default scope map")) != null'
  write_config '[]'
  scope_nomap
  [ "$status" -eq 0 ]
  json_check '.mapped_suites == ["bats:tests"] and (.warnings | index("test-config.json could not be read; using the default scope map")) != null'
}

# ===================================================================================================================
# --suites input
# ===================================================================================================================

@test "suites: a nonexistent --suites file is exit 3" {
  make_repo
  scope --suites "$BATS_TEST_TMPDIR/no-suites.json"
  expect_exit3 "--suites" "no-suites.json"
}

@test "suites: invalid JSON in --suites is exit 3" {
  make_repo
  printf '%s\n' '{not json' > "$BATS_TEST_TMPDIR/bad-suites.json"
  scope --suites "$BATS_TEST_TMPDIR/bad-suites.json"
  expect_exit3 "--suites" "not valid JSON"
}

@test "suites: a document with no suites array is exit 3" {
  make_repo
  local body
  for body in '{}' '{"suites":{}}' '[]' '{"suites":"npm:test"}'; do
    printf '%s\n' "$body" > "$BATS_TEST_TMPDIR/no-array.json"
    scope --suites "$BATS_TEST_TMPDIR/no-array.json"
    expect_exit3 "--suites" 'a "suites" array'
  done
}

@test "suites: a suite object without paths is accepted and read as empty" {
  make_repo
  mkdir -p "$REPO/src" "$REPO/test"
  printf 'one\n' > "$REPO/src/a.js"
  printf 'one\n' > "$REPO/test/a.test.js"
  commit_all "add js"
  printf 'two\n' >> "$REPO/src/a.js"
  commit_all "change js"
  write_map "$BATS_TEST_TMPDIR/js-map.json" '{"map_version":1,"rules":[{"source":"src/**/*.js","tests":["test/**/*.test.js"]}]}'
  printf '%s\n' '{"suites":[{"id":"npm:test","command":"npm test"}]}' > "$BATS_TEST_TMPDIR/no-paths.json"
  scope --map "$BATS_TEST_TMPDIR/js-map.json" --suites "$BATS_TEST_TMPDIR/no-paths.json"
  [ "$status" -eq 0 ]
  [ -z "$stderr" ]
  # The empty `paths` is what lets the JS ecosystem fallback resolve test/a.test.js to the npm suite.
  [ "$output" = '{"mapped_suites":["npm:test"],"mapped_tests":{"npm:test":["test/a.test.js"]},"unmapped_files":[],"warnings":[]}' ]
}

@test "suites: --suites - reads the suites JSON from standard input" {
  make_repo
  scope
  [ "$status" -eq 0 ]
  local from_file="$output"
  run --separate-stderr with_stdin "$SUITES" \
    "$BASH_BIN" "$MAP_SCOPE" --root "$REPO" --rev HEAD --map "$OK_MAP" --suites -
  [ "$status" -eq 0 ]
  [ -z "$stderr" ]
  [ "$output" = "$from_file" ]
  json_check '.mapped_suites == ["bats:tests"]'
}

# ===================================================================================================================
# Usage and environment errors
# ===================================================================================================================

@test "usage: an unknown flag is exit 2" {
  map_scope --bogus
  [ "$status" -eq 2 ]
  [ -z "$output" ]
  assert_contains "$stderr" "unknown argument: --bogus"
}

@test "usage: every flag that takes a value is exit 2 when its argument is missing" {
  local flag
  for flag in --root --map --suites --rev --range; do
    map_scope "$flag"
    [ "$status" -eq 2 ]
    [ -z "$output" ]
    assert_contains "$stderr" "$flag requires"
  done
}

@test "usage: two change sources at once are exit 2" {
  make_repo
  scope --staged --working
  [ "$status" -eq 2 ]
  [ -z "$output" ]
  assert_contains "$stderr" "at most one of"
  scope --staged
  [ "$status" -eq 2 ]
  scope --range 'HEAD~1..HEAD'
  [ "$status" -eq 2 ]
  [ -z "$output" ]
}

@test "usage: a --range without .. is exit 2" {
  make_repo
  scope_norev --range HEAD
  [ "$status" -eq 2 ]
  [ -z "$output" ]
  assert_contains "$stderr" "--range expects"
}

@test "usage: a --root that is not a directory is exit 2" {
  map_scope --root "$BATS_TEST_TMPDIR/does-not-exist" --suites "$SUITES" --map "$OK_MAP"
  [ "$status" -eq 2 ]
  [ -z "$output" ]
  assert_contains "$stderr" "--root is not a directory"
}

@test "environment: a directory that is not a git repository is exit 4" {
  mkdir -p "$BATS_TEST_TMPDIR/plain"
  # No parent repository may be discovered above the temp directory, wherever TMPDIR happens to live.
  GIT_CEILING_DIRECTORIES="$(cd "$BATS_TEST_TMPDIR" && pwd -P)"
  export GIT_CEILING_DIRECTORIES
  map_scope --root "$BATS_TEST_TMPDIR/plain" --suites "$SUITES" --map "$OK_MAP"
  [ "$status" -eq 4 ]
  [ -z "$output" ]
  assert_contains "$stderr" "not a git repository"
}

@test "environment: an unknown --rev is exit 4" {
  make_repo
  scope_norev --rev does-not-exist
  [ "$status" -eq 4 ]
  [ -z "$output" ]
  assert_contains "$stderr" "unknown revision: does-not-exist"
}

@test "environment: an unknown --range side is exit 4" {
  make_repo
  scope_norev --range 'does-not-exist..HEAD'
  [ "$status" -eq 4 ]
  [ -z "$output" ]
  assert_contains "$stderr" "unknown revision: does-not-exist"
}

@test "usage: --help exits 0 with usage on stdout and nothing on stderr" {
  map_scope --help
  [ "$status" -eq 0 ]
  [ -z "$stderr" ]
  assert_output_contains "Usage: map-scope.sh"
}

# ===================================================================================================================
# Edge cases
# ===================================================================================================================

@test "edge: an empty commit yields exactly No changed files with exit 0, and discovery is not run" {
  make_repo
  commit_all "empty" --allow-empty
  scope
  [ "$status" -eq 0 ]
  [ -z "$stderr" ]
  [ "$output" = "$EMPTY_SHAPE" ]
  # Without --suites the real discovery would add its own warnings; an empty change set never reaches it.
  map_scope --root "$REPO" --rev HEAD --map "$OK_MAP"
  [ "$status" -eq 0 ]
  [ -z "$stderr" ]
  [ "$output" = "$EMPTY_SHAPE" ]
}

@test "edge: no suites yields No test suites discovered next to the zero-mapped warning, exit 0" {
  make_repo
  printf '%s\n' '{"suites":[]}' > "$BATS_TEST_TMPDIR/no-suites.json"
  scope --suites "$BATS_TEST_TMPDIR/no-suites.json"
  [ "$status" -eq 0 ]
  [ -z "$stderr" ]
  json_check '.mapped_suites == [] and .mapped_tests == {} and .unmapped_files == ["scripts/x.sh"]
              and (.warnings | index("No tests found for the changed files")) != null
              and (.warnings | index("No test suites discovered")) != null'
}

@test "edge: deleted files are counted by name, and a deleted source still triggers its rule" {
  make_repo
  mkdir -p "$REPO/docs"
  printf 'gone\n' > "$REPO/docs/gone.md"
  commit_all "add docs/gone.md"
  git -C "$REPO" rm -q scripts/x.sh docs/gone.md
  commit_all "delete a source and a document"
  scope
  [ "$status" -eq 0 ]
  [ -z "$stderr" ]
  [ "$output" = '{"mapped_suites":["bats:tests"],"mapped_tests":{"bats:tests":["tests/a.bats"]},"unmapped_files":["docs/gone.md"],"warnings":[]}' ]
}

@test "edge: a change set of only a deleted test file is handled and nothing maps" {
  make_repo
  git -C "$REPO" rm -q tests/a.bats
  commit_all "delete the test file"
  scope
  [ "$status" -eq 0 ]
  [ -z "$stderr" ]
  [ "$output" = '{"mapped_suites":[],"mapped_tests":{},"unmapped_files":["tests/a.bats"],"warnings":["No tests found for the changed files"]}' ]
}

@test "edge: a change set that deletes every file is handled" {
  make_repo
  git -C "$REPO" rm -q -r scripts tests
  commit_all "delete everything"
  scope
  [ "$status" -eq 0 ]
  [ -z "$stderr" ]
  json_check '.mapped_suites == [] and .unmapped_files == ["scripts/x.sh","tests/a.bats"]
              and (.warnings | index("No tests found for the changed files")) != null'
}

@test "edge: file names with a space and non-ASCII characters survive -z handling unquoted" {
  make_repo
  mkdir -p "$REPO/src" "$REPO/test" "$REPO/docs"
  printf 'one\n' > "$REPO/test/spaced name.test.js"
  printf 'one\n' > "$REPO/src/ünï code.js"
  printf 'one\n' > "$REPO/docs/with space.md"
  printf 'one\n' > "$REPO/docs/naïve ünï.md"
  commit_all "add unusual names"
  printf 'two\n' >> "$REPO/src/ünï code.js"
  printf 'two\n' >> "$REPO/docs/with space.md"
  printf 'two\n' >> "$REPO/docs/naïve ünï.md"
  commit_all "change them"
  write_map "$BATS_TEST_TMPDIR/js-map.json" '{"map_version":1,"rules":[{"source":"src/**/*.js","tests":["test/**/*.test.js"]}]}'
  scope --map "$BATS_TEST_TMPDIR/js-map.json"
  [ "$status" -eq 0 ]
  [ -z "$stderr" ]
  # The source rule matched src/ünï code.js (so its name was not git-quoted), and the test file with a space was
  # resolved to the npm suite; the two unmapped documents come back intact and in byte order.
  [ "$output" = '{"mapped_suites":["npm:test"],"mapped_tests":{"npm:test":["test/spaced name.test.js"]},"unmapped_files":["docs/naïve ünï.md","docs/with space.md"],"warnings":[]}' ]
}

# ===================================================================================================================
# Determinism
# ===================================================================================================================

# make_rich_repo: HEAD changes twelve files whose names sort differently under C and under a UTF-8 locale, against
# three suites and a three-rule map, so ordering and the warning set are actually exercised.
make_rich_repo() {
  local f
  make_repo
  mkdir -p "$REPO/docs" "$REPO/src" "$REPO/test"
  for f in Zeta.md _under.md alpha.md éclair.md docs/z.md tests/B.bats tests/_c.bats scripts/y.sh src/a.js test/a.test.js; do
    printf 'one\n' > "$REPO/$f"
  done
  commit_all "add the rich tree"
  for f in Zeta.md _under.md alpha.md éclair.md docs/z.md tests/B.bats tests/_c.bats tests/a.bats scripts/x.sh scripts/y.sh src/a.js test/a.test.js; do
    printf 'two\n' >> "$REPO/$f"
  done
  commit_all "change every file"
  RICH_MAP="$BATS_TEST_TMPDIR/rich-map.json"
  RICH_SUITES="$BATS_TEST_TMPDIR/rich-suites.json"
  write_map "$RICH_MAP" '{"map_version":1,"rules":[{"source":"src/**/*.js","tests":["test/**/*.test.js"]},{"source":"scripts/*.sh","tests":["tests/*.bats"]},{"source":"docs/**","tests":["nothing/*.x"]}]}'
  write_map "$RICH_SUITES" '{"suites":[{"id":"npm:test","command":"npm test"},{"id":"bats:tests","command":"bats tests/*.bats","paths":["tests/*.bats"]},{"id":"Zed:suite","command":"zed run","paths":["tests/*.bats"]}]}'
}

# The exact output the rich repository must produce, in C byte order.
RICH_EXPECTED='{"mapped_suites":["Zed:suite","bats:tests","npm:test"],"mapped_tests":{"Zed:suite":["tests/B.bats","tests/_c.bats","tests/a.bats"],"bats:tests":["tests/B.bats","tests/_c.bats","tests/a.bats"],"npm:test":["test/a.test.js"]},"unmapped_files":["Zeta.md","_under.md","alpha.md","docs/z.md","éclair.md"],"warnings":["rule 3 (docs/**): 1 changed file(s) matched but no existing test file matched its tests globs"]}'

# rich_to_file <outfile> [VAR=value...]: stdout of one run to a file, byte for byte, stderr discarded (a missing
# locale makes bash itself complain on stderr). The assignments become the run's environment.
rich_to_file() {
  local out="$1"
  shift
  env "$@" "$BASH_BIN" "$MAP_SCOPE" --root "$REPO" --rev HEAD --suites "$RICH_SUITES" --map "$RICH_MAP" > "$out" 2> /dev/null
}

@test "determinism: two runs on the same input are byte-identical (cmp)" {
  make_rich_repo
  rich_to_file "$BATS_TEST_TMPDIR/run1.out"
  rich_to_file "$BATS_TEST_TMPDIR/run2.out"
  [ -s "$BATS_TEST_TMPDIR/run1.out" ]
  jq -e '(.mapped_suites | length) == 3 and (.unmapped_files | length) == 5' "$BATS_TEST_TMPDIR/run1.out" > /dev/null
  cmp "$BATS_TEST_TMPDIR/run1.out" "$BATS_TEST_TMPDIR/run2.out"
}

@test "determinism: LC_ALL=C and a UTF-8 locale produce byte-identical output (cmp)" {
  make_rich_repo
  rich_to_file "$BATS_TEST_TMPDIR/c.out" LC_ALL=C
  rich_to_file "$BATS_TEST_TMPDIR/utf8.out" LC_ALL=en_US.UTF-8
  rich_to_file "$BATS_TEST_TMPDIR/de.out" LC_ALL=de_DE.UTF-8 LANG=de_DE.UTF-8
  [ -s "$BATS_TEST_TMPDIR/c.out" ]
  cmp "$BATS_TEST_TMPDIR/c.out" "$BATS_TEST_TMPDIR/utf8.out"
  cmp "$BATS_TEST_TMPDIR/c.out" "$BATS_TEST_TMPDIR/de.out"
}

@test "determinism: every output array is sorted in C byte order, whatever the caller's locale" {
  make_rich_repo
  run --separate-stderr env LC_ALL=en_US.UTF-8 "$BASH_BIN" "$MAP_SCOPE" --root "$REPO" --rev HEAD \
    --suites "$RICH_SUITES" --map "$RICH_MAP"
  [ "$status" -eq 0 ]
  json_check '.mapped_suites == (.mapped_suites | sort)
              and .unmapped_files == (.unmapped_files | sort)
              and .warnings == (.warnings | sort | unique)
              and all(.mapped_tests[]; . == (. | sort))
              and (.mapped_tests | keys_unsorted) == .mapped_suites'
  # The literal order is C order: capitals first, then "_", then lower case, then non-ASCII bytes.
  [ "$output" = "$RICH_EXPECTED" ]
}

@test "determinism: the output carries no absolute path" {
  make_rich_repo
  scope_norev --suites "$RICH_SUITES" --map "$RICH_MAP" --rev HEAD
  [ "$status" -eq 0 ]
  assert_not_contains "$output" "$BATS_TEST_TMPDIR"
  assert_not_contains "$output" "$REPO"
  assert_not_contains "$output" "$(cd "$REPO" && pwd -P)"
  assert_not_contains "$output" "$REPO_ROOT"
  json_check '[.. | strings | select(startswith("/"))] == []'
}

# ===================================================================================================================
# Read-only and non-executing
# ===================================================================================================================

# make_dirty_repo: make_repo plus a staged new file, an unstaged edit, an untracked file, and a tracked file whose
# content is unchanged but whose recorded stat data is stale (so a plain `git status` would refresh and rewrite the
# index).
make_dirty_repo() {
  make_repo
  mkdir -p "$REPO/docs"
  printf 'staged\n' > "$REPO/docs/staged.md"
  git -C "$REPO" add docs/staged.md
  printf 'edited\n' >> "$REPO/tests/a.bats"
  printf 'new\n' > "$REPO/untracked.txt"
  touch -t 200001010000 "$REPO/scripts/x.sh"
}

# snapshot_repo <dir>: everything a read-only run must leave alone: the porcelain status (taken without the optional
# index refresh, so taking the snapshot changes nothing), a checksum of every working-tree file, and a checksum of
# every file under .git (the index, HEAD, refs, objects, config), plus the names under .git.
snapshot_repo() {
  local dir="$1"
  GIT_OPTIONAL_LOCKS=0 git -C "$dir" status --porcelain
  echo "--- working tree"
  (cd "$dir" && find . -path ./.git -prune -o -type f -print0 | LC_ALL=C sort -z | xargs -0 cksum)
  echo "--- .git"
  (cd "$dir" && find .git -type f -print0 | LC_ALL=C sort -z | xargs -0 cksum)
}

# assert_same_snapshot <before> <after>
assert_same_snapshot() {
  if [ "$1" != "$2" ]; then
    echo "the repository changed during the run (< before, > after):"
    diff <(printf '%s\n' "$1") <(printf '%s\n' "$2") || true
    return 1
  fi
}

@test "read-only precondition: on the dirty fixture a plain git status does rewrite the index" {
  make_dirty_repo
  local before after
  before="$(cksum < "$REPO/.git/index")"
  git -C "$REPO" status --porcelain > /dev/null
  after="$(cksum < "$REPO/.git/index")"
  # If this ever stops holding, the read-only case below could pass without proving anything.
  [ "$before" != "$after" ]
}

@test "read-only: no change source touches the working tree, the index or anything under .git" {
  make_dirty_repo
  local before after
  before="$(snapshot_repo "$REPO")"
  scope_norev --working
  [ "$status" -eq 0 ]
  json_check '.mapped_suites == ["bats:tests"] and (.unmapped_files | index("untracked.txt")) != null and (.unmapped_files | index("docs/staged.md")) != null'
  scope_norev --staged
  [ "$status" -eq 0 ]
  scope_norev --rev HEAD
  [ "$status" -eq 0 ]
  scope_norev --range 'HEAD~1..HEAD'
  [ "$status" -eq 0 ]
  after="$(snapshot_repo "$REPO")"
  assert_same_snapshot "$before" "$after"
  # The untracked and staged files really were part of the snapshot (the comparison was not over an empty repo).
  assert_contains "$before" "?? untracked.txt"
  assert_contains "$before" "A  docs/staged.md"
}

@test "never-executes: a mapped suite whose command is touch CANARY is never run, with --suites or real discovery" {
  make_repo
  mkdir -p "$REPO/src" "$REPO/test"
  printf 'one\n' > "$REPO/src/a.js"
  printf 'one\n' > "$REPO/test/a.test.js"
  printf '{"scripts":{"test":"touch CANARY"}}\n' > "$REPO/package.json"
  printf '@test "canary" { touch CANARY; }\n' > "$REPO/tests/canary.bats"
  commit_all "add js, package.json and a canary bats file"
  printf 'two\n' >> "$REPO/src/a.js"
  printf 'echo three\n' >> "$REPO/scripts/x.sh"
  commit_all "change a source and a script"
  write_map "$BATS_TEST_TMPDIR/canary-map.json" '{"map_version":1,"rules":[{"source":"scripts/*.sh","tests":["tests/*.bats"]},{"source":"src/*.js","tests":["test/*.test.js"]}]}'
  printf '%s\n' '{"suites":[{"id":"bats:tests","command":"touch CANARY","paths":["tests/*.bats"]},{"id":"npm:test","command":"touch ./CANARY"}]}' > "$BATS_TEST_TMPDIR/canary-suites.json"
  # Run from inside the fixture so a relative `touch CANARY` would land there.
  cd "$REPO"
  map_scope --root "$REPO" --rev HEAD --suites "$BATS_TEST_TMPDIR/canary-suites.json" --map "$BATS_TEST_TMPDIR/canary-map.json"
  [ "$status" -eq 0 ]
  # Both suites are mapped, so the commands were available to run; they were not.
  json_check '.mapped_suites == ["bats:tests","npm:test"]'
  [ ! -e "$REPO/CANARY" ]
  [ ! -e "$PWD/CANARY" ]
  map_scope --root "$REPO" --rev HEAD --map "$BATS_TEST_TMPDIR/canary-map.json"
  [ "$status" -eq 0 ]
  json_check '(.mapped_suites | index("bats:tests")) != null and (.mapped_suites | index("npm:test")) != null'
  [ ! -e "$REPO/CANARY" ]
  [ -z "$(find "$BATS_TEST_TMPDIR" -name 'CANARY*' -print)" ]
}

# ===================================================================================================================
# Shipped-template drift guard
# ===================================================================================================================

@test "template: the shipped templates/test-scope-map.json passes the script's validation" {
  [ -f "$TEMPLATE" ]
  make_repo
  scope --map "$TEMPLATE"
  [ "$status" -eq 0 ]
  [ -z "$stderr" ]
  json_check 'keys == ["mapped_suites","mapped_tests","unmapped_files","warnings"]
              and (.mapped_suites | type) == "array" and (.warnings | type) == "array"'
}

# ===================================================================================================================
# Real-discovery integration
# ===================================================================================================================

@test "integration: without --suites the real discover-tests.sh supplies the suites and their paths" {
  make_repo
  printf '{"scripts":{"test":"echo ok"}}\n' > "$REPO/package.json"
  commit_all "add package.json"
  printf 'echo three\n' >> "$REPO/scripts/x.sh"
  commit_all "change scripts/x.sh"
  local before after
  before="$(snapshot_repo "$REPO")"
  # The host PATH still has git, jq and every tool discovery needs. The map is the shipped template (the fixture
  # has no templates/ of its own, so the script falls back to the shipped copy).
  map_scope --root "$REPO" --rev HEAD
  [ "$status" -eq 0 ]
  json_check '(.mapped_suites | index("bats:tests")) != null'
  json_check '(.mapped_tests["bats:tests"] | index("tests/a.bats")) != null'
  # Discovery warnings, if any, are carried with the prefix. The exact object is not asserted, because the tools
  # installed on the host (a linter, say) are not controlled.
  json_check 'all(.warnings[]; startswith("discovery: "))'
  after="$(snapshot_repo "$REPO")"
  assert_same_snapshot "$before" "$after"
}
