#!/usr/bin/env bats
#
# Coverage for the /uncharted investigative-engine scripts under skills/j-uncharted/scripts/ (E43_S01_T02):
#
#   enumerate-target.sh   detect-dependencies.sh   detect-tests.sh   run-engine.sh   import-source.sh   inspect-provenance.sh
#
# Their secret-file skipping already has its own suites (uncharted-enumerate-secret-skip, uncharted-detectors-secret-skip,
# uncharted-import-secret-skip, uncharted-secret-files); this suite does not repeat that and covers the rest: the documented
# exit codes of each script, the three coverage states of detect-tests.sh, run-engine.sh's Board linkage row (linked, unlinked,
# not_checked), and the stdin / pipeline forms (a snippet piped into import-source.sh).
#
# Fixtures: tests/fixtures/uncharted-detectors/<case>/tree with expected.json beside it, plus the onboard fixture
# tests/fixtures/uncharted-subsystems/app/tree (src/api has a test file, src/web does not). Every script runs from the sandbox
# repo built by tests/helpers/uncharted.bash, so a defaulted output directory (run-engine.sh writes
# <repo>/project/rapports/analysis by default) lands in the sandbox, never in the live project.
#
# Rule 2 (project/documentation/bats-fixture-convention.md): a mode flag (--no-gitignore, --mode import, --origin, --max-depth) is
# named in the @test that uses it; a @test without one measures the defaults.

bats_require_minimum_version 1.5.0

load helpers/assertions
load helpers/uncharted

DETECTOR_FIXTURES="$UNCHARTED_FIXTURES/uncharted-detectors"

setup() {
  uncharted_sandbox
  ENUM="$SCRIPTS/enumerate-target.sh"
  DEPS="$SCRIPTS/detect-dependencies.sh"
  TESTS="$SCRIPTS/detect-tests.sh"
  ENGINE="$SCRIPTS/run-engine.sh"
  IMPORT="$SCRIPTS/import-source.sh"
  PROVENANCE="$SCRIPTS/inspect-provenance.sh"
  OUT="$BATS_TEST_TMPDIR/engine-out"
}

# detector_projection <tree>: the three detectors' stable fields, in the shape of expected.json.
detector_projection() {
  local tree="$1" deps tests enum
  deps="$(bash "$DEPS" "$tree" </dev/null 2>/dev/null)"
  tests="$(bash "$TESTS" "$tree" </dev/null 2>/dev/null)"
  enum="$(bash "$ENUM" "$tree" </dev/null 2>/dev/null)"
  jq -n -S --argjson d "$deps" --argjson t "$tests" --argjson e "$enum" '{
    dependencies: {
      unrecognised: $d.unrecognised,
      counts: $d.counts,
      languages: $d.languages,
      external: ([$d.external[] | {name, kind}] | sort_by(.name)),
      manifests: [$d.manifests[] | {name, declared_dependencies}]
    },
    tests: {coverage_status: $t.coverage_status, repo_has_tests: $t.repo_has_tests},
    enumeration: {total_files: $e.total_files, total_lines: $e.total_lines, extensions: $e.extensions}
  }'
}

@test "every case directory under tests/fixtures/uncharted-detectors has an expected.json and a tree" {
  local dir
  for dir in "$DETECTOR_FIXTURES"/*/; do
    [ -f "$dir/expected.json" ] || { echo "missing expected.json in $dir"; return 1; }
    [ -d "$dir/tree" ] || { echo "missing tree in $dir"; return 1; }
  done
}

@test "deps-mixed: dependencies, tests and enumeration match expected.json" {
  uncharted_tree "$DETECTOR_FIXTURES/deps-mixed/tree" deps git
  assert_json_equals "$(detector_projection "$TREE")" "$DETECTOR_FIXTURES/deps-mixed/expected.json"
}

@test "no-source: an unrecognised-language tree is a normal empty result, matching expected.json" {
  uncharted_tree "$DETECTOR_FIXTURES/no-source/tree" nosrc git
  assert_json_equals "$(detector_projection "$TREE")" "$DETECTOR_FIXTURES/no-source/expected.json"
}

# ---------------------------------------------------------------------------------------------------------------------
# enumerate-target.sh
# ---------------------------------------------------------------------------------------------------------------------

@test "enumerate-target.sh counts a git-tracked tree and respects .gitignore on the default path" {
  uncharted_tree "$UNCHARTED_FIXTURES/uncharted-subsystems/app/tree" app git
  mkdir -p "$TREE/ignored_dir"
  printf 'junk\n' >"$TREE/ignored_dir/junk.js"
  run --separate-stderr bash "$ENUM" "$TREE" </dev/null
  [ "$status" -eq 0 ]
  run jq -e '.gitignore_respected == true and .listing_source == "git-ls-files" and .total_files == 27' <<<"$output"
  [ "$status" -eq 0 ]
}

@test "enumerate-target.sh under --no-gitignore enumerates .gitignore'd content too, and says it did not respect .gitignore" {
  uncharted_tree "$UNCHARTED_FIXTURES/uncharted-subsystems/app/tree" app git
  mkdir -p "$TREE/ignored_dir"
  printf 'junk\n' >"$TREE/ignored_dir/junk.js"
  run --separate-stderr bash "$ENUM" "$TREE" </dev/null
  local default_total
  default_total="$(jq '.total_files' <<<"$output")"
  run --separate-stderr bash "$ENUM" --no-gitignore "$TREE" </dev/null
  [ "$status" -eq 0 ]
  run jq -e --argjson d "$default_total" '.gitignore_respected == false and .listing_source == "find" and .total_files > $d' <<<"$output"
  [ "$status" -eq 0 ]
}

@test "enumerate-target.sh on a single file reports target_type=file, listing_source=explicit and one file" {
  uncharted_tree "$UNCHARTED_FIXTURES/uncharted-detectors/deps-mixed/tree" deps git
  run --separate-stderr bash "$ENUM" "$TREE/main.py" </dev/null
  [ "$status" -eq 0 ]
  run jq -e '.target_type == "file" and .listing_source == "explicit" and .total_files == 1' <<<"$output"
  [ "$status" -eq 0 ]
}

@test "enumerate-target.sh under --max-depth 1 bounds the tree but never the counts (invariant: totals equal the unbounded run)" {
  uncharted_tree "$UNCHARTED_FIXTURES/uncharted-subsystems/app/tree" app git
  run --separate-stderr bash "$ENUM" --max-depth 0 "$TREE" </dev/null
  local unbounded
  unbounded="$(jq -c '{total_files, total_lines, total_bytes}' <<<"$output")"
  run --separate-stderr bash "$ENUM" --max-depth 1 "$TREE" </dev/null
  [ "$status" -eq 0 ]
  [ "$(jq -c '{total_files, total_lines, total_bytes}' <<<"$output")" = "$unbounded" ]
  run jq -e '.tree_truncated == true and ([.tree[].depth] | max) <= 1' <<<"$output"
  [ "$status" -eq 0 ]
}

@test "enumerate-target.sh exit codes: 0 --help, 1 usage (no target, unknown flag, bad number), 2 missing target" {
  run --separate-stderr bash "$ENUM" --help </dev/null
  [ "$status" -eq 0 ]
  run --separate-stderr bash "$ENUM" </dev/null
  [ "$status" -eq 1 ]
  run --separate-stderr bash "$ENUM" --no-such-flag "$BATS_TEST_TMPDIR" </dev/null
  [ "$status" -eq 1 ]
  run --separate-stderr bash "$ENUM" --max-depth abc "$BATS_TEST_TMPDIR" </dev/null
  [ "$status" -eq 1 ]
  run --separate-stderr bash "$ENUM" "$BATS_TEST_TMPDIR/no-such-target" </dev/null
  [ "$status" -eq 2 ]
}

# ---------------------------------------------------------------------------------------------------------------------
# detect-dependencies.sh
# ---------------------------------------------------------------------------------------------------------------------

@test "detect-dependencies.sh on a single source file scans exactly that file" {
  uncharted_tree "$DETECTOR_FIXTURES/deps-mixed/tree" deps git
  run --separate-stderr bash "$DEPS" "$TREE/main.py" </dev/null
  [ "$status" -eq 0 ]
  run jq -e '.target_type == "file" and .files_scanned == 1 and ([.external[].name] | sort) == ["os", "requests"]' <<<"$output"
  [ "$status" -eq 0 ]
}

@test "detect-dependencies.sh exit codes: 0 --help, 1 usage, 2 missing target" {
  run --separate-stderr bash "$DEPS" --help </dev/null
  [ "$status" -eq 0 ]
  run --separate-stderr bash "$DEPS" </dev/null
  [ "$status" -eq 1 ]
  run --separate-stderr bash "$DEPS" "$BATS_TEST_TMPDIR" "$BATS_TEST_TMPDIR" </dev/null
  [ "$status" -eq 1 ]
  run --separate-stderr bash "$DEPS" "$BATS_TEST_TMPDIR/no-such-target" </dev/null
  [ "$status" -eq 2 ]
}

@test "detect-dependencies.sh exit 3 (fails closed) when the shared secret-file list is missing" {
  uncharted_tree "$DETECTOR_FIXTURES/deps-mixed/tree" deps git
  rm "$SCRIPTS/secret-files.sh"
  run --separate-stderr bash "$DEPS" "$TREE" </dev/null
  [ "$status" -eq 3 ]
}

# ---------------------------------------------------------------------------------------------------------------------
# detect-tests.sh
# ---------------------------------------------------------------------------------------------------------------------

@test "detect-tests.sh reports three distinct coverage states: covered, repo_tests_only, no_tests_in_repo" {
  uncharted_tree "$UNCHARTED_FIXTURES/uncharted-subsystems/app/tree" app git
  run --separate-stderr bash "$TESTS" "$TREE/src/api" </dev/null
  [ "$status" -eq 0 ]
  run jq -e '.coverage_status == "covered" and .repo_has_tests == true and .target_test_files == ["src/api/handler.test.js"]' <<<"$output"
  [ "$status" -eq 0 ]
  run --separate-stderr bash "$TESTS" "$TREE/src/web" </dev/null
  [ "$status" -eq 0 ]
  run jq -e '.coverage_status == "repo_tests_only" and .repo_has_tests == true and .target_test_files == []' <<<"$output"
  [ "$status" -eq 0 ]
  uncharted_tree "$DETECTOR_FIXTURES/no-source/tree" nosrc git
  run --separate-stderr bash "$TESTS" "$TREE" </dev/null
  [ "$status" -eq 0 ]
  run jq -e '.coverage_status == "no_tests_in_repo" and .repo_has_tests == false' <<<"$output"
  [ "$status" -eq 0 ]
}

@test "detect-tests.sh invariant: covered implies a test file inside the target; no_tests_in_repo implies repo_has_tests=false" {
  uncharted_tree "$UNCHARTED_FIXTURES/uncharted-subsystems/app/tree" app git
  local target
  for target in src/api src/web docs-site services/billing; do
    run --separate-stderr bash "$TESTS" "$TREE/$target" </dev/null
    [ "$status" -eq 0 ]
    run jq -e '((.coverage_status == "covered") == ((.target_test_files | length > 0) or (.referencing_test_files | length > 0)))
               and ((.coverage_status == "no_tests_in_repo") == (.repo_has_tests == false))' <<<"$output"
    [ "$status" -eq 0 ] || { echo "invariant broken for $target"; return 1; }
  done
}

@test "detect-tests.sh exit codes: 0 --help, 1 usage, 2 missing target, 3 secret-file list missing" {
  run --separate-stderr bash "$TESTS" --help </dev/null
  [ "$status" -eq 0 ]
  run --separate-stderr bash "$TESTS" </dev/null
  [ "$status" -eq 1 ]
  run --separate-stderr bash "$TESTS" "$BATS_TEST_TMPDIR/no-such-target" </dev/null
  [ "$status" -eq 2 ]
  uncharted_tree "$DETECTOR_FIXTURES/deps-mixed/tree" deps git
  rm "$SCRIPTS/secret-files.sh"
  run --separate-stderr bash "$TESTS" "$TREE" </dev/null
  [ "$status" -eq 3 ]
}

# ---------------------------------------------------------------------------------------------------------------------
# run-engine.sh
# ---------------------------------------------------------------------------------------------------------------------

@test "run-engine.sh prints exactly the written document's path on stdout, and writes exactly one file to --out-dir" {
  uncharted_tree "$DETECTOR_FIXTURES/deps-mixed/tree" deps git
  run --separate-stderr bash "$ENGINE" --out-dir "$OUT" "$TREE" </dev/null
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 1 ]
  [ -f "$output" ]
  [ "$(find "$OUT" -type f | wc -l | tr -d ' ')" -eq 1 ]
  assert_contains "$output" "uncharted-segment-"
}

@test "run-engine.sh under --mode import --origin writes an import-named document that carries the origin row" {
  uncharted_tree "$DETECTOR_FIXTURES/deps-mixed/tree" deps git
  run --separate-stderr bash "$ENGINE" --mode import --origin "imported from fixture" --out-dir "$OUT" "$TREE" </dev/null
  [ "$status" -eq 0 ]
  assert_contains "$output" "uncharted-import-"
  assert_contains "$(cat "$output")" "imported from fixture"
}

@test "run-engine.sh under --json-out also writes the merged detector JSON" {
  uncharted_tree "$DETECTOR_FIXTURES/deps-mixed/tree" deps git
  run --separate-stderr bash "$ENGINE" --out-dir "$OUT" --json-out "$BATS_TEST_TMPDIR/merged.json" "$TREE" </dev/null
  [ "$status" -eq 0 ]
  jq -e . "$BATS_TEST_TMPDIR/merged.json" >/dev/null
}

@test "run-engine.sh Board linkage row distinguishes linked, unlinked and not_checked" {
  mkdir -p "$SB/src/linked" "$SB/src/unlinked"
  printf 'export const a = 1;\n' >"$SB/src/linked/a.js"
  printf 'export const b = 1;\n' >"$SB/src/unlinked/b.js"
  printf -- '---\nid: E01_S01_T01\ntitle: demo\ndocs: ["src/linked"]\n---\nTouches src/linked/a.js\n' >"$SB/project/board/tasks/E01_S01_T01_demo.md"
  ( cd "$SB" && git add -A && git commit -q -m fixture ) >/dev/null
  run --separate-stderr bash "$ENGINE" --out-dir "$OUT/linked" "$SB/src/linked" </dev/null
  [ "$status" -eq 0 ]
  local linked_row
  linked_row="$(grep -F '| Board linkage |' "$output")"
  assert_contains "$linked_row" "linked to \`E01_S01_T01\`"
  run --separate-stderr bash "$ENGINE" --out-dir "$OUT/unlinked" "$SB/src/unlinked" </dev/null
  [ "$status" -eq 0 ]
  local unlinked_row
  unlinked_row="$(grep -F '| Board linkage |' "$output")"
  assert_starts_with "${unlinked_row#| Board linkage | }" "unlinked"
  # A target outside the repository was never checked: it must not be reported as unlinked.
  uncharted_tree "$DETECTOR_FIXTURES/deps-mixed/tree" deps git
  run --separate-stderr bash "$ENGINE" --out-dir "$OUT/outside" "$TREE/lib" </dev/null
  [ "$status" -eq 0 ]
  local outside_row
  outside_row="$(grep -F '| Board linkage |' "$output")"
  assert_starts_with "${outside_row#| Board linkage | }" "not_checked"
  # A target that is a repository root has no meaningful linkage either: not "unlinked".
  run --separate-stderr bash "$ENGINE" --out-dir "$OUT/root" "$TREE" </dev/null
  [ "$status" -eq 0 ]
  local root_row
  root_row="$(grep -F '| Board linkage |' "$output")"
  assert_starts_with "${root_row#| Board linkage | }" "n/a"
}

@test "run-engine.sh exit codes: 0 --help, 1 usage (no target, bad --mode, unknown flag), 2 missing target" {
  run --separate-stderr bash "$ENGINE" --help </dev/null
  [ "$status" -eq 0 ]
  run --separate-stderr bash "$ENGINE" --out-dir "$OUT" </dev/null
  [ "$status" -eq 1 ]
  run --separate-stderr bash "$ENGINE" --mode bogus --out-dir "$OUT" "$BATS_TEST_TMPDIR" </dev/null
  [ "$status" -eq 1 ]
  run --separate-stderr bash "$ENGINE" --no-such-flag "$BATS_TEST_TMPDIR" </dev/null
  [ "$status" -eq 1 ]
  run --separate-stderr bash "$ENGINE" --out-dir "$OUT" "$BATS_TEST_TMPDIR/no-such-target" </dev/null
  [ "$status" -eq 2 ]
}

@test "run-engine.sh exit 3 when a detector script is missing, and nothing is written" {
  uncharted_tree "$DETECTOR_FIXTURES/deps-mixed/tree" deps git
  rm "$SCRIPTS/detect-tests.sh"
  run --separate-stderr bash "$ENGINE" --out-dir "$OUT" "$TREE" </dev/null
  [ "$status" -eq 3 ]
  [ -z "$(find "$OUT" -type f 2>/dev/null)" ]
}

@test "run-engine.sh exit 4 when --out-dir is a file, when --json-out's directory is missing, and when the template is missing" {
  uncharted_tree "$DETECTOR_FIXTURES/deps-mixed/tree" deps git
  : >"$BATS_TEST_TMPDIR/a-file"
  run --separate-stderr bash "$ENGINE" --out-dir "$BATS_TEST_TMPDIR/a-file" "$TREE" </dev/null
  [ "$status" -eq 4 ]
  run --separate-stderr bash "$ENGINE" --out-dir "$OUT" --json-out "$BATS_TEST_TMPDIR/no-such-dir/x.json" "$TREE" </dev/null
  [ "$status" -eq 4 ]
  run --separate-stderr bash "$ENGINE" --out-dir "$OUT" --template "$BATS_TEST_TMPDIR/no-such-template.md" "$TREE" </dev/null
  [ "$status" -eq 4 ]
  # the failures left no document behind
  [ -z "$(find "$OUT" -type f 2>/dev/null)" ]
}

# ---------------------------------------------------------------------------------------------------------------------
# import-source.sh
# ---------------------------------------------------------------------------------------------------------------------

@test "import-source.sh stages a local directory (type path) and its file_count equals the files in the source" {
  uncharted_tree "$DETECTOR_FIXTURES/deps-mixed/tree" src
  run --separate-stderr bash "$IMPORT" --json-only --staging-dir "$BATS_TEST_TMPDIR/stage" "$TREE" </dev/null
  [ "$status" -eq 0 ]
  local source_files staged_files
  source_files="$(find "$TREE" -type f | wc -l | tr -d ' ')"
  run jq -e --argjson n "$source_files" '.source_type == "path" and .file_count == $n and .git_ref == null' <<<"$output"
  [ "$status" -eq 0 ]
  staged_files="$(find "$BATS_TEST_TMPDIR/stage/source" -type f | wc -l | tr -d ' ')"
  [ "$staged_files" -eq "$source_files" ]
}

@test "import-source.sh under --type snippet reads the snippet from stdin (the documented cat file | import-source.sh - form)" {
  run --separate-stderr bash -c \
    'printf "line one\nline two\n" | bash "$1" --json-only --type snippet --name notes.txt --staging-dir "$2" -' _ "$IMPORT" "$BATS_TEST_TMPDIR/snip"
  [ "$status" -eq 0 ]
  run jq -e '.source_type == "snippet" and .file_count == 1' <<<"$output"
  [ "$status" -eq 0 ]
  [ "$(cat "$BATS_TEST_TMPDIR/snip/source/notes.txt")" = "$(printf 'line one\nline two')" ]
}

@test "import-source.sh under --type git clones a local repository and records its HEAD short sha as git_ref" {
  local origin="$BATS_TEST_TMPDIR/origin"
  mkdir -p "$origin"
  ( cd "$origin" && git init -q . && git config user.email a@example.invalid && git config user.name n \
    && printf 'hi\n' >f.txt && git add -A && git commit -q -m c ) >/dev/null
  run --separate-stderr bash "$IMPORT" --json-only --type git --staging-dir "$BATS_TEST_TMPDIR/cloned" "$origin" </dev/null
  [ "$status" -eq 0 ]
  local head
  head="$(git -C "$origin" rev-parse --short HEAD)"
  run jq -e --arg h "$head" '.source_type == "git" and .git_ref == $h' <<<"$output"
  [ "$status" -eq 0 ]
}

@test "import-source.sh exit 1 for a usage error: no source, bad --type, a --name with a directory separator" {
  run --separate-stderr bash "$IMPORT" </dev/null
  [ "$status" -eq 1 ]
  run --separate-stderr bash "$IMPORT" --type bogus x </dev/null
  [ "$status" -eq 1 ]
  run --separate-stderr bash -c 'printf "x" | bash "$1" --type snippet --name a/b.txt --staging-dir "$2" -' _ "$IMPORT" "$BATS_TEST_TMPDIR/s1"
  [ "$status" -eq 1 ]
}

@test "import-source.sh exit 3 when the git clone fails" {
  run --separate-stderr bash "$IMPORT" --type git --staging-dir "$BATS_TEST_TMPDIR/s2" "file://$BATS_TEST_TMPDIR/no-such-repo.git" </dev/null
  [ "$status" -eq 3 ]
}

@test "import-source.sh exit 4 for a missing source, an empty directory, and a path inside the repository" {
  run --separate-stderr bash "$IMPORT" --staging-dir "$BATS_TEST_TMPDIR/s3" "$BATS_TEST_TMPDIR/no-such-source" </dev/null
  [ "$status" -eq 4 ]
  mkdir -p "$BATS_TEST_TMPDIR/empty-source"
  run --separate-stderr bash "$IMPORT" --staging-dir "$BATS_TEST_TMPDIR/s4" "$BATS_TEST_TMPDIR/empty-source" </dev/null
  [ "$status" -eq 4 ]
  run --separate-stderr bash "$IMPORT" --staging-dir "$BATS_TEST_TMPDIR/s5" "$SB/skills" </dev/null
  [ "$status" -eq 4 ]
}

@test "import-source.sh exit 5 for an empty snippet on stdin" {
  run --separate-stderr bash "$IMPORT" --type snippet --staging-dir "$BATS_TEST_TMPDIR/s6" - </dev/null
  [ "$status" -eq 5 ]
}

@test "import-source.sh exit 6 when the staging directory is non-empty or inside the repository" {
  uncharted_tree "$DETECTOR_FIXTURES/deps-mixed/tree" src
  mkdir -p "$BATS_TEST_TMPDIR/occupied"
  : >"$BATS_TEST_TMPDIR/occupied/already-here"
  run --separate-stderr bash "$IMPORT" --staging-dir "$BATS_TEST_TMPDIR/occupied" "$TREE" </dev/null
  [ "$status" -eq 6 ]
  run --separate-stderr bash "$IMPORT" --staging-dir "$SB/staging-inside-repo" "$TREE" </dev/null
  [ "$status" -eq 6 ]
}

# ---------------------------------------------------------------------------------------------------------------------
# inspect-provenance.sh
# ---------------------------------------------------------------------------------------------------------------------

@test "inspect-provenance.sh on the licensed fixture matches expected.json" {
  uncharted_tree "$DETECTOR_FIXTURES/licensed/tree" licensed
  run --separate-stderr bash "$PROVENANCE" "$TREE" </dev/null
  [ "$status" -eq 0 ]
  local projected
  projected="$(jq -S '{license: {found: .license.found, files: .license.files}, spdx: [.spdx_identifiers.identifiers[] | {id, sources}],
                       copyright_found: .copyright.found, any_signal_found: .overall.any_signal_found}' <<<"$output")"
  assert_json_equals "$projected" "$DETECTOR_FIXTURES/licensed/expected.json"
}

@test "inspect-provenance.sh on a tree with no provenance signal exits 0 and says so (nothing found is a result, not a failure)" {
  uncharted_tree "$DETECTOR_FIXTURES/no-source/tree" nosrc
  run --separate-stderr bash "$PROVENANCE" "$TREE" </dev/null
  [ "$status" -eq 0 ]
  run jq -e '.overall.any_signal_found == false and .license.found == false and .spdx_identifiers.found == false and .copyright.found == false' <<<"$output"
  [ "$status" -eq 0 ]
}

@test "inspect-provenance.sh under --origin-source/--origin-type/--origin-ref carries the origin through verbatim" {
  uncharted_tree "$DETECTOR_FIXTURES/licensed/tree" licensed
  run --separate-stderr bash "$PROVENANCE" --origin-source "https://example.invalid/r.git" --origin-type git --origin-ref abc1234 "$TREE" </dev/null
  [ "$status" -eq 0 ]
  run jq -e '.git_origin.applicable == true and .git_origin.origin.source == "https://example.invalid/r.git"
             and .git_origin.origin.source_type == "git" and .git_origin.origin.head_sha == "abc1234"' <<<"$output"
  [ "$status" -eq 0 ]
}

@test "inspect-provenance.sh exit codes: 1 usage, 2 missing target, 4 --json-out cannot be written" {
  uncharted_tree "$DETECTOR_FIXTURES/licensed/tree" licensed
  run --separate-stderr bash "$PROVENANCE" </dev/null
  [ "$status" -eq 1 ]
  run --separate-stderr bash "$PROVENANCE" --no-such-flag "$TREE" </dev/null
  [ "$status" -eq 1 ]
  run --separate-stderr bash "$PROVENANCE" "$BATS_TEST_TMPDIR/no-such-target" </dev/null
  [ "$status" -eq 2 ]
  mkdir -p "$BATS_TEST_TMPDIR/a-directory"
  run --separate-stderr bash "$PROVENANCE" --json-out "$BATS_TEST_TMPDIR/a-directory" "$TREE" </dev/null
  [ "$status" -eq 4 ]
}

# The header documents exit 5 for "the shared secret-file list could not be loaded (fails closed)". It is reached when the list loads
# as a library but its `patterns` command fails. (A secret-files.sh that is absent altogether aborts at the `.` line with exit 1,
# not the documented 5; that gap is recorded in the E43_S01_T02 execution summary and deliberately not pinned here.)
@test "inspect-provenance.sh exit 5 (fails closed) when the secret-file list's patterns command fails" {
  uncharted_tree "$DETECTOR_FIXTURES/licensed/tree" licensed
  printf '#!/usr/bin/env bash\nif [ "${BASH_SOURCE[0]}" = "$0" ]; then exit 9; fi\n' >"$SCRIPTS/secret-files.sh"
  run --separate-stderr bash "$PROVENANCE" "$TREE" </dev/null
  [ "$status" -eq 5 ]
}
