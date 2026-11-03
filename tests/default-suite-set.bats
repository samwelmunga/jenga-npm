#!/usr/bin/env bats
#
# The bounded default suite set: its config surface, its resolver and the shared
# strict-subset guard (E72_S08_T06).
#
# WHAT IS UNDER TEST. `E72_S07_T03` dropped the shipped scope map's `**/*.sh`
# catch-all, so a change in an area no rule covers maps to nothing, and
# scope-test-gate.sh answered that by running the ENTIRE runnable catalog --
# exactly what story E72_S08 exists to stop. `E72_S08_T02` removes that fallback;
# this task supplies the replacement for the `no-mapped-suites` case:
#   project/configs/test-config.json  test_default_suite_set (the membership)
#   skills/j-test/scripts/resolve-default-suites.sh   (value -> runnable suites)
#   skills/j-test/scripts/assert-bounded-subset.sh    (the strict-subset guard,
#                                                      shared with E72_S08_T03)
#
# ASSERT THE BEHAVIOUR, NEVER AN IMPLICIT DEFAULT. `E72_S08_T01` found two cases
# in tests/scope-test-gate.bats that had gone VACUOUS -- they exited 0 through the
# `policy none` path and so covered nothing. The guards this file covers are what
# those cases were supposed to protect, so every case below states the condition
# it exercises explicitly: the configured value is always passed with --set or
# written into a scratch config, never left to a default, and every refusal is
# asserted on BOTH its exit code and its message.
#
# `run --separate-stderr` throughout, so $output is stdout alone (the JSON object
# or the guard's one verdict line) and $stderr carries the messages. Mixing them
# would make a stray warning break every jq assertion in the file.
#
# ISOLATION. Every case but the three marked "live" builds its own git repository
# under $BATS_TEST_TMPDIR, so the catalog it compares against is small, known and
# cannot be shifted by this repository's own 272 test files. The three live cases
# are READ-ONLY against $REPO_ROOT: they run discovery and the resolver, which
# write nothing outside ${TMPDIR}, and they run NO suite.

bats_require_minimum_version 1.5.0
load helpers/assertions

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd -P)"
RESOLVE="$REPO_ROOT/skills/j-test/scripts/resolve-default-suites.sh"
GUARD="$REPO_ROOT/skills/j-test/scripts/assert-bounded-subset.sh"
DISCOVER="$REPO_ROOT/skills/j-test/scripts/discover-tests.sh"
DESCRIPTOR="$REPO_ROOT/templates/config-descriptors/test-config.json"
LIVE_CONFIG="$REPO_ROOT/project/configs/test-config.json"
INIT_TEMPLATE="$REPO_ROOT/skills/j-init/assets/test-config_template.json"
KEY="test_default_suite_set"

setup() {
  ROOT="$BATS_TEST_TMPDIR/root"
  mkdir -p "$ROOT/tests" "$ROOT/project/configs"
  git -C "$ROOT" init -q
  git -C "$ROOT" config user.email t@example.com
  git -C "$ROOT" config user.name T
  cd "$BATS_TEST_TMPDIR"
}

# --- helpers --------------------------------------------------------------------------------------------------

# fixture_tests <name>...: create tests/<name> files holding one inert bats case each.
fixture_tests() {
  local n
  for n in "$@"; do
    printf '@test "inert %s" { true; }\n' "$n" > "$ROOT/tests/$n"
  done
}

# discovery: write the scratch root's discovery JSON once per test, and echo its path.
discovery() {
  if [ ! -f "$BATS_TEST_TMPDIR/discovery.json" ]; then
    bash "$DISCOVER" --root "$ROOT" > "$BATS_TEST_TMPDIR/discovery.json" 2>/dev/null
  fi
  printf '%s' "$BATS_TEST_TMPDIR/discovery.json"
}

# live_discovery: the real repository's discovery JSON, once per test.
live_discovery() {
  if [ ! -f "$BATS_TEST_TMPDIR/live-discovery.json" ]; then
    bash "$DISCOVER" --root "$REPO_ROOT" > "$BATS_TEST_TMPDIR/live-discovery.json" 2>/dev/null
  fi
  printf '%s' "$BATS_TEST_TMPDIR/live-discovery.json"
}

# resolve <args>...: the resolver against the scratch root and its cached discovery.
resolve() {
  run --separate-stderr bash "$RESOLVE" --root "$ROOT" --suites "$(discovery)" "$@"
}

# guard <files-file> <args>...: the guard against the scratch root.
guard() {
  local sel="$1"; shift
  run --separate-stderr bash "$GUARD" --root "$ROOT" --suites "$(discovery)" --files "$sel" "$@"
}

# cfg <value>: write a scratch test-config.json carrying the key at <value>.
cfg() {
  jq -n --arg v "$1" --arg k "$KEY" '{tools: [], ($k): $v}' > "$ROOT/project/configs/test-config.json"
}

# =================================================================================================================
# The config surface: three declaration sites, and jenga config can read and write it
# =================================================================================================================

@test "the key is declared in the live config, the descriptor and the j.init scaffold template" {
  [ "$(jq -r --arg k "$KEY" 'has($k)' "$LIVE_CONFIG")" = "true" ]
  [ "$(jq -r --arg k "$KEY" 'has($k)' "$INIT_TEMPLATE")" = "true" ]
  [ "$(jq -r --arg k "$KEY" '[.keys[] | select(.key == $k)] | length' "$DESCRIPTOR")" = "1" ]
}

@test "the descriptor key is an editable string whose default is empty, with a pattern, and no bump rule" {
  run jq -c --arg k "$KEY" '.keys[] | select(.key == $k) | [.type, .editable, .default]' "$DESCRIPTOR"
  [ "$output" = '["string",true,""]' ]
  [ "$(jq --arg k "$KEY" '.keys[] | select(.key == $k) | has("pattern")' "$DESCRIPTOR")" = "true" ]
  # test-config.json carries no version counter by E72_S01_T04's deliberate
  # design, so no key of it may declare a bump rule. This one included.
  [ "$(jq --arg k "$KEY" '.keys[] | select(.key == $k) | has("bump_on_change")' "$DESCRIPTOR")" = "false" ]
  [ "$(jq 'has("test_config_version")' "$LIVE_CONFIG")" = "false" ]
}

@test "the scaffold template's value equals the descriptor default, so a fresh project inherits the documented safe default" {
  [ "$(jq -r --arg k "$KEY" '.[$k]' "$INIT_TEMPLATE")" = "$(jq -r --arg k "$KEY" '.keys[] | select(.key == $k) | .default' "$DESCRIPTOR")" ]
  [ "$(jq -r --arg k "$KEY" '.[$k]' "$INIT_TEMPLATE")" = "" ]
}

@test "the descriptor pattern accepts a comma-separated glob list and rejects a space, a bracket and a doubled comma" {
  local pat ok bad
  pat="$(jq -r --arg k "$KEY" '.keys[] | select(.key == $k) | .pattern' "$DESCRIPTOR")"
  for ok in "" "tests/a.bats" "tests/a.bats,tests/b.bats" "tests/**/*.bats" "tests/a-b_c.bats"; do
    run node -e 'process.exit(new RegExp(process.argv[1]).test(process.argv[2]) ? 0 : 1)' "$pat" "$ok"
    [ "$status" -eq 0 ] || { echo "pattern rejected a valid value: $ok" >&2; return 1; }
  done
  for bad in "tests/a.bats, tests/b.bats" "tests/[a].bats" "tests/a.bats,,tests/b.bats" "tests/a.bats," ",tests/a.bats"; do
    run node -e 'process.exit(new RegExp(process.argv[1]).test(process.argv[2]) ? 0 : 1)' "$pat" "$bad"
    [ "$status" -eq 1 ] || { echo "pattern accepted an invalid value: $bad" >&2; return 1; }
  done
}

@test "jenga config get and set both work against the key, against a scratch copy of the configs" {
  local proj="$BATS_TEST_TMPDIR/proj"
  mkdir -p "$proj/project/configs"
  cp "$REPO_ROOT"/project/configs/*.json "$proj/project/configs/"
  case "$proj" in "$BATS_TEST_TMPDIR"/*) ;; *) echo "scratch root escaped the temp dir" >&2; return 1 ;; esac

  run env JENGA_PROJECT_ROOT="$proj" node "$REPO_ROOT/bin/jenga.js" config get "test-config.$KEY"
  [ "$status" -eq 0 ]
  [ "$output" = "$(jq -r --arg k "$KEY" '.[$k]' "$LIVE_CONFIG")" ]

  run env JENGA_PROJECT_ROOT="$proj" node "$REPO_ROOT/bin/jenga.js" config set "test-config.$KEY" "tests/a.bats,tests/b.bats"
  [ "$status" -eq 0 ]
  [ "$(jq -r --arg k "$KEY" '.[$k]' "$proj/project/configs/test-config.json")" = "tests/a.bats,tests/b.bats" ]

  # A value failing the pattern is exit 4 and leaves the file as it was.
  run env JENGA_PROJECT_ROOT="$proj" node "$REPO_ROOT/bin/jenga.js" config set "test-config.$KEY" "tests/a.bats, tests/b.bats"
  [ "$status" -eq 4 ]
  [ "$(jq -r --arg k "$KEY" '.[$k]' "$proj/project/configs/test-config.json")" = "tests/a.bats,tests/b.bats" ]

  # The repository's own config was never touched.
  [ "$(jq -r --arg k "$KEY" '.[$k]' "$LIVE_CONFIG")" != "tests/a.bats,tests/b.bats" ]
}

# =================================================================================================================
# The resolver: a configured value becomes a runnable selection
# =================================================================================================================

@test "a configured subset resolves to the mapped suite and only the named test files" {
  fixture_tests a.bats b.bats c.bats
  resolve --set "tests/a.bats"
  [ "$status" -eq 0 ]
  [ "$(jq -c '.mapped_suites' <<<"$output")" = '["bats:tests"]' ]
  [ "$(jq -c '.mapped_tests["bats:tests"]' <<<"$output")" = '["tests/a.bats"]' ]
  [ "$(jq -r '.default_set.files_selected' <<<"$output")" = "1" ]
  [ "$(jq -r '.default_set.files_available' <<<"$output")" = "3" ]
  [ "$(jq -r '.default_set.source' <<<"$output")" = "override" ]
}

@test "the output carries map-scope.sh's four keys in order, so E72_S08_T02 can feed it to narrow-suites.sh --mapped-tests unchanged" {
  fixture_tests a.bats b.bats
  resolve --set "tests/a.bats"
  [ "$status" -eq 0 ]
  [ "$(jq -c 'keys_unsorted' <<<"$output")" = '["mapped_suites","mapped_tests","unmapped_files","warnings","default_set"]' ]
}

@test "a glob, not only a literal path, resolves: tests/a*.bats selects both matching files and not the third" {
  fixture_tests a1.bats a2.bats b.bats
  resolve --set "tests/a*.bats"
  [ "$status" -eq 0 ]
  [ "$(jq -c '.mapped_tests["bats:tests"]' <<<"$output")" = '["tests/a1.bats","tests/a2.bats"]' ]
}

@test "the value is read from test-config.json when no --set is given, and source says config" {
  fixture_tests a.bats b.bats
  cfg "tests/b.bats"
  run --separate-stderr bash "$RESOLVE" --root "$ROOT" --suites "$(discovery)" \
    --config "$ROOT/project/configs/test-config.json"
  [ "$status" -eq 0 ]
  [ "$(jq -c '.mapped_tests["bats:tests"]' <<<"$output")" = '["tests/b.bats"]' ]
  [ "$(jq -r '.default_set.source' <<<"$output")" = "config" ]
}

@test "two runs over an unchanged tree are byte-identical" {
  fixture_tests a.bats b.bats
  local d first second
  d="$(discovery)"
  first="$(bash "$RESOLVE" --root "$ROOT" --suites "$d" --set "tests/a.bats" 2>/dev/null)"
  second="$(bash "$RESOLVE" --root "$ROOT" --suites "$d" --set "tests/a.bats" 2>/dev/null)"
  [ "$first" = "$second" ]
}

# =================================================================================================================
# The strict-subset guard
# =================================================================================================================

@test "a value resolving to the entire runnable catalog is refused with exit 6, names the offending value, and runs nothing" {
  fixture_tests a.bats b.bats c.bats
  resolve --set "tests/*.bats"
  [ "$status" -eq 6 ]
  assert_contains "$stderr" "ENTIRE runnable catalog"
  assert_contains "$stderr" "test_default_suite_set=\"tests/*.bats\""
  # No selection object is printed, so nothing downstream could be handed a run.
  assert_not_contains "$output" "mapped_suites"
}

@test "naming every file one by one is refused too: the guard compares the resolved FILES, not the configured syntax" {
  fixture_tests a.bats b.bats
  resolve --set "tests/a.bats,tests/b.bats"
  [ "$status" -eq 6 ]
  assert_contains "$stderr" "ENTIRE runnable catalog"
}

@test "the guard reports equals-catalog for a single-file catalog, and the resolver still refuses it" {
  fixture_tests only.bats
  resolve --set "tests/only.bats"
  [ "$status" -eq 6 ]
  # The DOCUMENTED decision: a floor equal to everything is a contradiction
  # whatever the catalog's size. The guard exposes available_count so
  # E72_S08_T03 can make the opposite call for the scoped invariant if it wants.
  printf 'tests/only.bats\n' > "$BATS_TEST_TMPDIR/sel.txt"
  guard "$BATS_TEST_TMPDIR/sel.txt" --json
  [ "$status" -eq 6 ]
  [ "$(jq -r '.verdict' <<<"$output")" = "equals-catalog" ]
  [ "$(jq -r '.available_count' <<<"$output")" = "1" ]
}

@test "the guard accepts a strict subset and reports the counts and the verdict" {
  fixture_tests a.bats b.bats c.bats
  printf 'tests/a.bats\ntests/b.bats\n' > "$BATS_TEST_TMPDIR/sel.txt"
  guard "$BATS_TEST_TMPDIR/sel.txt" --json
  [ "$status" -eq 0 ]
  [ "$(jq -r '.verdict' <<<"$output")" = "strict-subset" ]
  [ "$(jq -r '.selected_count' <<<"$output")" = "2" ]
  [ "$(jq -r '.available_count' <<<"$output")" = "3" ]
  [ "$(jq -c '.selected' <<<"$output")" = '["tests/a.bats","tests/b.bats"]' ]
}

@test "the guard quotes --label back in a refusal, so a caller can name the responsible setting or rule" {
  fixture_tests a.bats
  printf 'tests/a.bats\n' > "$BATS_TEST_TMPDIR/sel.txt"
  guard "$BATS_TEST_TMPDIR/sel.txt" --label 'rule 7: **/*.sh -> tests/**/*.bats'
  [ "$status" -eq 6 ]
  assert_contains "$output" "rule 7: **/*.sh -> tests/**/*.bats"
}

@test "the guard's human line agrees with the exit code for all three outcomes" {
  fixture_tests a.bats b.bats
  printf 'tests/a.bats\n' > "$BATS_TEST_TMPDIR/subset.txt"
  printf 'tests/a.bats\ntests/b.bats\n' > "$BATS_TEST_TMPDIR/all.txt"
  : > "$BATS_TEST_TMPDIR/none.txt"

  guard "$BATS_TEST_TMPDIR/subset.txt"
  [ "$status" -eq 0 ]
  assert_contains "$output" "a strict subset"

  guard "$BATS_TEST_TMPDIR/all.txt"
  [ "$status" -eq 6 ]
  assert_contains "$output" "NOT a strict subset"

  guard "$BATS_TEST_TMPDIR/none.txt"
  [ "$status" -eq 5 ]
  assert_contains "$output" "nothing to run"
  assert_contains "$output" "NOT a pass"
}

@test "a regression test for the invariant itself: it asserts the refusal, so removing the equality check turns it red" {
  fixture_tests a.bats b.bats c.bats
  printf 'tests/a.bats\ntests/b.bats\ntests/c.bats\n' > "$BATS_TEST_TMPDIR/sel.txt"
  guard "$BATS_TEST_TMPDIR/sel.txt"
  [ "$status" -eq 6 ]
}

# =================================================================================================================
# A runnable suite that declares no test-file paths (THE LIMIT OF A FILE-LEVEL UNIVERSE)
# =================================================================================================================
#
# discover-tests.sh gives `paths: []` to an npm suite and to shellcheck:all, so their files
# cannot be enumerated and are not in the universe the guard compares against. Whether
# shellcheck is on PATH is an environment fact, so these two cases use a HAND-WRITTEN
# discovery fixture rather than depending on it.

@test "a runnable suite with no paths is named in opaque_suites and in the equals-catalog message, not papered over" {
  fixture_tests a.bats b.bats
  jq -n '{suites: [
      {id: "bats:tests", name: "bats tests", type: "unit", ecosystem: "bats",
       command: "bats tests/*.bats", paths: ["tests/*.bats"]},
      {id: "npm:test", name: "npm test", type: "unit", ecosystem: "npm",
       command: "npm test", paths: []}
    ], warnings: []}' > "$BATS_TEST_TMPDIR/opaque.json"
  printf 'tests/a.bats\ntests/b.bats\n' > "$BATS_TEST_TMPDIR/sel.txt"

  run --separate-stderr bash "$GUARD" --root "$ROOT" --suites "$BATS_TEST_TMPDIR/opaque.json" \
    --files "$BATS_TEST_TMPDIR/sel.txt" --json
  [ "$status" -eq 6 ]
  [ "$(jq -c '.opaque_suites' <<<"$output")" = '["npm:test"]' ]
  [ "$(jq -r '.available_count' <<<"$output")" = "2" ]

  # The human line must not claim "the entire catalog" when a suite was never in the
  # comparison: it says ENUMERABLE and names the suite.
  run --separate-stderr bash "$GUARD" --root "$ROOT" --suites "$BATS_TEST_TMPDIR/opaque.json" \
    --files "$BATS_TEST_TMPDIR/sel.txt"
  [ "$status" -eq 6 ]
  assert_contains "$output" "ENUMERABLE"
  assert_contains "$output" "npm:test"
}

@test "a catalog whose only runnable suite declares no paths has an empty universe: exit 5 for any value, never a pass" {
  fixture_tests a.bats
  jq -n '{suites: [
      {id: "npm:test", name: "npm test", type: "unit", ecosystem: "npm",
       command: "npm test", paths: []}
    ], warnings: []}' > "$BATS_TEST_TMPDIR/only-opaque.json"

  run --separate-stderr bash "$RESOLVE" --root "$ROOT" --suites "$BATS_TEST_TMPDIR/only-opaque.json" \
    --set "tests/a.bats"
  [ "$status" -eq 5 ]
  assert_contains "$stderr" "NO runnable test file"
}

# =================================================================================================================
# The empty-set rule: zero runnable suites is a refusal, never a pass
# =================================================================================================================

@test "a value whose globs match no file in the working tree is exit 5, names the globs, and is not a pass" {
  fixture_tests a.bats
  resolve --set "tests/does-not-exist.bats"
  [ "$status" -eq 5 ]
  assert_contains "$stderr" "match no file in the working tree"
  assert_contains "$stderr" "tests/does-not-exist.bats"
  assert_contains "$stderr" "NO runnable test file"
}

@test "a value naming only files no runnable suite runs is exit 5, and the dropped paths are named" {
  fixture_tests a.bats
  printf '# notes\n' > "$ROOT/NOTES.md"
  resolve --set "NOTES.md"
  [ "$status" -eq 5 ]
  assert_contains "$stderr" "not run by any runnable suite"
  assert_contains "$stderr" "NOTES.md"
}

@test "a value mixing a covered file with an uncovered one keeps the covered file, reports the other in unmapped_files, and does not fail" {
  fixture_tests a.bats b.bats
  printf '# notes\n' > "$ROOT/NOTES.md"
  resolve --set "tests/a.bats,NOTES.md"
  [ "$status" -eq 0 ]
  [ "$(jq -c '.mapped_tests["bats:tests"]' <<<"$output")" = '["tests/a.bats"]' ]
  [ "$(jq -c '.unmapped_files' <<<"$output")" = '["NOTES.md"]' ]
  [ "$(jq -r '.warnings | length' <<<"$output")" != "0" ]
}

@test "a tree with no runnable test file at all is exit 5, not a pass" {
  rm -rf "$ROOT/tests"
  resolve --set "tests/a.bats"
  [ "$status" -eq 5 ]
}

# =================================================================================================================
# The absent-key default, and an invalid configured value
# =================================================================================================================

@test "an absent key is exit 4 and names the key and how to set it, never a pass and never the full catalog" {
  fixture_tests a.bats b.bats
  jq -n '{tools: []}' > "$ROOT/project/configs/test-config.json"
  run --separate-stderr bash "$RESOLVE" --root "$ROOT" --suites "$(discovery)" \
    --config "$ROOT/project/configs/test-config.json"
  [ "$status" -eq 4 ]
  assert_contains "$stderr" "is not configured"
  assert_contains "$stderr" "jenga config set test-config.$KEY"
  assert_not_contains "$output" "mapped_suites"
}

@test "an empty key is exit 4, the same documented not-configured outcome as an absent one" {
  fixture_tests a.bats b.bats
  cfg ""
  run --separate-stderr bash "$RESOLVE" --root "$ROOT" --suites "$(discovery)" \
    --config "$ROOT/project/configs/test-config.json"
  [ "$status" -eq 4 ]
  assert_contains "$stderr" "is not configured"
}

@test "a null key, a non-string key and a missing config file are all handled without claiming a run" {
  fixture_tests a.bats
  local d; d="$(discovery)"

  jq -n --arg k "$KEY" '{tools: [], ($k): null}' > "$ROOT/project/configs/test-config.json"
  run --separate-stderr bash "$RESOLVE" --root "$ROOT" --suites "$d" --config "$ROOT/project/configs/test-config.json"
  [ "$status" -eq 4 ]

  jq -n --arg k "$KEY" '{tools: [], ($k): ["tests/a.bats"]}' > "$ROOT/project/configs/test-config.json"
  run --separate-stderr bash "$RESOLVE" --root "$ROOT" --suites "$d" --config "$ROOT/project/configs/test-config.json"
  [ "$status" -eq 3 ]
  assert_contains "$stderr" "is not a string"

  run --separate-stderr bash "$RESOLVE" --root "$ROOT" --suites "$d" --config "$ROOT/project/configs/absent.json"
  [ "$status" -eq 4 ]
}

@test "a glob outside the shared dialect is exit 3 and names the key and the offending glob" {
  fixture_tests a.bats
  resolve --set "tests/[ab].bats"
  [ "$status" -eq 3 ]
  assert_contains "$stderr" "$KEY"
  assert_contains "$stderr" "tests/[ab].bats"
}

@test "a leading, trailing or doubled comma is exit 3 and says so" {
  fixture_tests a.bats b.bats
  resolve --set "tests/a.bats,"
  [ "$status" -eq 3 ]
  assert_contains "$stderr" "empty element"
  resolve --set ",tests/a.bats"
  [ "$status" -eq 3 ]
  resolve --set "tests/a.bats,,tests/b.bats"
  [ "$status" -eq 3 ]
}

@test "an absolute path and a .. segment are rejected rather than resolved" {
  fixture_tests a.bats
  resolve --set "/etc/passwd"
  [ "$status" -eq 3 ]
  resolve --set "tests/../tests/a.bats"
  [ "$status" -eq 3 ]
}

# =================================================================================================================
# Usage and shape
# =================================================================================================================

@test "both scripts print help on --help and exit 0, and reject an unknown option with exit 2" {
  run bash "$RESOLVE" --help
  [ "$status" -eq 0 ]
  assert_output_contains "bounded default suite set"
  run bash "$GUARD" --help
  [ "$status" -eq 0 ]
  assert_output_contains "STRICT subset"

  run bash "$RESOLVE" --root "$ROOT" --nope
  [ "$status" -eq 2 ]
  run bash "$GUARD" --root "$ROOT" --nope
  [ "$status" -eq 2 ]
}

@test "--config and --set cannot be combined, and the guard requires both of its inputs" {
  run bash "$RESOLVE" --root "$ROOT" --config "$LIVE_CONFIG" --set "tests/a.bats"
  [ "$status" -eq 2 ]
  assert_output_contains "cannot be combined"
  run bash "$GUARD" --root "$ROOT" --suites "$(discovery)"
  [ "$status" -eq 2 ]
  assert_output_contains "--files is required"
}

@test "both new scripts are tracked executable, so a consuming checkout can run them" {
  [ "$(git -C "$REPO_ROOT" ls-files -s -- skills/j-test/scripts/resolve-default-suites.sh | cut -c1-6)" = "100755" ]
  [ "$(git -C "$REPO_ROOT" ls-files -s -- skills/j-test/scripts/assert-bounded-subset.sh | cut -c1-6)" = "100755" ]
}

# =================================================================================================================
# Live, read-only cases against this repository
# =================================================================================================================

@test "live: this repository's configured set is a STRICT subset of its own runnable catalog" {
  run --separate-stderr bash "$RESOLVE" --root "$REPO_ROOT" --suites "$(live_discovery)"
  [ "$status" -eq 0 ]
  local selected available
  selected="$(jq -r '.default_set.files_selected' <<<"$output")"
  available="$(jq -r '.default_set.files_available' <<<"$output")"
  [ "$selected" -gt 0 ]
  [ "$available" -gt "$selected" ]
  # A floor is small by construction: well under a tenth of the catalog here.
  [ "$((selected * 10))" -lt "$available" ]
}

@test "live: none of the three barred mirror suites is in the configured set" {
  local v barred
  v="$(jq -r --arg k "$KEY" '.[$k]' "$LIVE_CONFIG")"
  for barred in tests/mirror-test-subject-invariant.bats \
                tests/mirror-permission-level-invariant.bats \
                tests/mirror-staging-branch-push.bats; do
    assert_not_contains "$v" "$barred"
  done
  # And resolving the set really does not select them: the configured value could
  # in principle name them through a glob rather than literally.
  run --separate-stderr bash "$RESOLVE" --root "$REPO_ROOT" --suites "$(live_discovery)"
  [ "$status" -eq 0 ]
  for barred in mirror-test-subject-invariant mirror-permission-level-invariant mirror-staging-branch-push; do
    assert_not_contains "$output" "$barred"
  done
}

@test "live: every file of the configured set exists, and none of them mutates a tracked artefact of its own tree" {
  run --separate-stderr bash "$RESOLVE" --root "$REPO_ROOT" --suites "$(live_discovery)"
  [ "$status" -eq 0 ]
  jq -r '.mapped_tests | to_entries[] | .value[]' <<<"$output" > "$BATS_TEST_TMPDIR/floor.txt"
  [ -s "$BATS_TEST_TMPDIR/floor.txt" ]
  local f
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    [ -f "$REPO_ROOT/$f" ] || { echo "configured set names a missing file: $f" >&2; return 1; }
    # The E72_S09 fold's rule: no suite in the floor may drive a real outward push
    # or rewrite a tracked file of the tree it runs in. These are the mechanisms
    # the three barred suites use.
    if grep -qE 'git push|MIRROR_PUBLIC_URL_OVERRIDE|MIRROR_WORKTREE_PATH_OVERRIDE' "$REPO_ROOT/$f"; then
      echo "a suite in the bounded default set drives a real push: $f" >&2
      return 1
    fi
    # A floor must also not carry the baseline-permissions marker: whether such a
    # file runs or skips depends on ambient session state, which would make the
    # floor's result flip for reasons unrelated to the change under test.
    if grep -q 'jenga:requires-baseline-permissions' "$REPO_ROOT/$f"; then
      echo "a suite in the bounded default set depends on ambient permission state: $f" >&2
      return 1
    fi
  done < "$BATS_TEST_TMPDIR/floor.txt"
}
