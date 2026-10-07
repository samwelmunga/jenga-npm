#!/usr/bin/env bats
#
# Coverage for skills/j-conventions/scripts/detect-conventions.sh (E69_S02_T04).
#
# Contract under test: the script's own header comment (output contract, thresholds, guarantees) and
# templates/conventions-schema.json (the category list). Human write-up: project/documentation/project-conventions.md,
# section "Detection output".
#
# Every fixture is a scratch project built at test time under $BATS_TEST_TMPDIR (which bats removes after each test):
# its own project/configs/workflow.json, its own `git init` with a LOCAL identity, scripted commits. JENGA_PROJECT_ROOT
# aims the script at it. Nothing here runs inside this repository's working tree, reads or writes this repository's own
# git history, or touches its project/configs/ (the teardown proves the last one).
#
# Streams: the script writes one JSON document to stdout and nothing to stderr on a normal run, so most tests use
# plain `run` and read $output with jq.

bats_require_minimum_version 1.5.0
load helpers/assertions

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
DETECT="$REPO_ROOT/skills/j-conventions/scripts/detect-conventions.sh"
VALIDATE="$REPO_ROOT/scripts/validate-conventions.sh"
SCHEMA="$REPO_ROOT/templates/conventions-schema.json"
REAL_CONFIGS="$REPO_ROOT/project/configs"

setup() {
  REAL_SUM="$(find "$REAL_CONFIGS" -type f -exec cksum {} + | sort | cksum)"
  unset JENGA_CONVENTIONS_SCHEMA JENGA_CONVENTIONS_PRESETS
}

teardown() {
  [ "$(find "$REAL_CONFIGS" -type f -exec cksum {} + | sort | cksum)" = "$REAL_SUM" ]
}

# --- fixture builders ----------------------------------------------------------------------------------------

# mkproj <name> [<workflow.json body>]: scratch project with a registry; prints nothing, sets PROJ.
mkproj() {
  PROJ="$BATS_TEST_TMPDIR/$1"
  mkdir -p "$PROJ/project/configs"
  printf '%s\n' "${2:-{\}}" > "$PROJ/project/configs/workflow.json"
}

# mkrepo <name> [<workflow.json body>]: mkproj plus a git repository with a local identity.
mkrepo() {
  mkproj "$@"
  git -C "$PROJ" init -q -b main
  git -C "$PROJ" config user.name "Fixture"
  git -C "$PROJ" config user.email "fixture@example.invalid"
  git -C "$PROJ" config commit.gpgsign false
}

# commits <message prefix> <count>: empty commits "<prefix> 1" .. "<prefix> <count>" in $PROJ.
commits() {
  local i=1
  while [ "$i" -le "$2" ]; do
    git -C "$PROJ" commit -q --allow-empty -m "$1 $i"
    i=$((i + 1))
  done
}

# commit_all <message>: stage everything in $PROJ and commit it.
commit_all() {
  git -C "$PROJ" add -A
  git -C "$PROJ" commit -q -m "$1"
}

# detect: run the detector against $PROJ.
detect() {
  JENGA_PROJECT_ROOT="$PROJ" run bash "$DETECT"
}

# jv <jq filter>: evaluate a filter over the detector's stdout ($output) as raw text.
jv() {
  printf '%s' "$output" | jq -r "$1"
}

# cat_field <category> <field>: raw value of one category field.
cat_field() {
  jv ".categories[\"$1\"].$2"
}

# Assert every category carries the "nothing found" shape.
assert_all_null() {
  [ "$(jv '[.categories[] | select(.detected != null or .confidence != "none")] | length')" = "0" ]
}

# --- arguments and environment -------------------------------------------------------------------------------

@test "--help prints the contract header and exits 0" {
  run bash "$DETECT" --help
  [ "$status" -eq 0 ]
  assert_output_contains "Output contract"
  assert_output_contains "preset_only"
}

@test "an unknown argument exits 2" {
  run --separate-stderr bash "$DETECT" --bogus
  [ "$status" -eq 2 ]
  assert_contains "$stderr" "unknown argument"
}

@test "jq missing from PATH exits 3 with a clear message and no crash" {
  mkproj nojq
  mkdir "$BATS_TEST_TMPDIR/bin"
  ln -s "$(command -v dirname)" "$BATS_TEST_TMPDIR/bin/dirname"
  run --separate-stderr env PATH="$BATS_TEST_TMPDIR/bin" JENGA_PROJECT_ROOT="$PROJ" /bin/bash "$DETECT"
  [ "$status" -eq 3 ]
  assert_contains "$stderr" "jq is required"
}

# --- no-signal projects ----------------------------------------------------------------------------------------

@test "an empty directory with a registry exits 0 with all 9 categories null" {
  mkproj empty
  detect
  [ "$status" -eq 0 ]
  printf '%s' "$output" | jq -e . >/dev/null
  [ "$(jv '.detect_version')" = "1" ]
  [ "$(jv '.categories | length')" = "9" ]
  assert_all_null
  [ "$(jv '.warnings | length')" = "0" ]
}

@test "a repository with no commits and no config exits 0 with all categories null" {
  mkrepo nocommits
  detect
  [ "$status" -eq 0 ]
  assert_all_null
  [ "$(jv '[.categories[] | select(.evidence != "")] | length')" = "0" ]
}

@test "a directory with no registry is inspected anyway and one warning says so" {
  PROJ="$BATS_TEST_TMPDIR/noregistry"
  mkdir -p "$PROJ"
  detect
  [ "$status" -eq 0 ]
  assert_all_null
  [ "$(jv '.warnings | length')" = "1" ]
  assert_contains "$(jv '.warnings[0]')" "no workflow.json registry found"
}

# --- contract ----------------------------------------------------------------------------------------------------

@test "category ids come from the schema in schema order" {
  mkproj ids
  detect
  [ "$status" -eq 0 ]
  [ "$(jv '.categories | keys_unsorted | join(",")')" = "$(jq -r '.categories | keys_unsorted | join(",")' "$SCHEMA")" ]
}

@test "the category list is read from the schema, not duplicated: an extra schema category appears" {
  mkproj extra
  jq '.categories["zz-extra"] = {"label":"Extra","values":{"x":{"type":"string","required":true}}}' "$SCHEMA" > "$BATS_TEST_TMPDIR/schema.json"
  JENGA_CONVENTIONS_SCHEMA="$BATS_TEST_TMPDIR/schema.json" JENGA_PROJECT_ROOT="$PROJ" run bash "$DETECT"
  [ "$status" -eq 0 ]
  [ "$(jv '.categories | length')" = "10" ]
  [ "$(cat_field zz-extra confidence)" = "none" ]
  [ "$(cat_field zz-extra preset_only)" = "false" ]
}

@test "every category has the five contract fields and code-comments alone is preset_only" {
  mkproj shape
  detect
  [ "$status" -eq 0 ]
  [ "$(jv '[.categories[] | keys | join(",")] | unique | join("|")')" = "confidence,detected,evidence,preset_match,preset_only" ]
  [ "$(cat_field code-comments preset_only)" = "true" ]
  [ "$(cat_field code-comments detected)" = "null" ]
  [ "$(jv '[.categories | to_entries[] | select(.value.preset_only == true) | .key] | join(",")')" = "code-comments" ]
}

@test "code-comments stays null and preset_only in a fully populated project" {
  mkrepo populated
  mkdir -p "$PROJ/src" "$PROJ/tests"
  printf '// why this exists\nfunction doThing() {}\n' > "$PROJ/src/thing-one.ts"
  printf '{"scripts":{"lint":"eslint ."}}\n' > "$PROJ/package.json"
  commit_all "feat: seed"
  detect
  [ "$status" -eq 0 ]
  [ "$(cat_field code-comments detected)" = "null" ]
  [ "$(cat_field code-comments preset_only)" = "true" ]
  [ "$(cat_field code-comments confidence)" = "none" ]
}

# --- commit-format -----------------------------------------------------------------------------------------------

@test "Conventional Commits repo: exact match count, EST subjects excluded, preset matched" {
  mkrepo cc
  commits "Update thing" 9
  # 41 conventional subjects, oldest to newest
  i=1
  while [ "$i" -le 41 ]; do
    git -C "$PROJ" commit -q --allow-empty -m "feat(api): change $i"
    i=$((i + 1))
  done
  # three board subjects, newest of all: they must not count and must not push anything out of the sample
  git -C "$PROJ" commit -q --allow-empty -m "task(E01_S01_T01): board work"
  git -C "$PROJ" commit -q --allow-empty -m "story(E01_S01): board work"
  git -C "$PROJ" commit -q --allow-empty -m "epic(E01): board work"
  detect
  [ "$status" -eq 0 ]
  assert_contains "$(cat_field commit-format evidence)" "41 of the last 50 commit subjects match type(scope): msg"
  assert_contains "$(cat_field commit-format evidence)" "3 EST board subjects excluded"
  [ "$(cat_field commit-format confidence)" = "high" ]
  [ "$(cat_field commit-format preset_match)" = "conventional-commits" ]
  [ "$(cat_field commit-format detected.style)" = "conventional-commits" ]
  [ "$(jv '.categories["commit-format"].detected.message_regex | length > 0')" = "true" ]
}

@test "no EST subjects excluded means the evidence does not mention exclusions" {
  mkrepo ccplain
  commits "fix(core): repair" 5
  detect
  [ "$status" -eq 0 ]
  assert_contains "$(cat_field commit-format evidence)" "5 of the last 5 commit subjects match"
  assert_not_contains "$(cat_field commit-format evidence)" "EST"
}

@test "commit-format confidence follows the 80 / 50 / 20 percent thresholds" {
  mkrepo medium
  commits "Plain" 20
  commits "feat: x" 30
  detect
  [ "$(cat_field commit-format confidence)" = "medium" ]
  assert_contains "$(cat_field commit-format evidence)" "30 of the last 50"

  mkrepo low
  commits "Plain" 38
  commits "feat: x" 12
  detect
  [ "$(cat_field commit-format confidence)" = "low" ]

  mkrepo below
  commits "Plain" 45
  commits "feat: x" 5
  detect
  [ "$(cat_field commit-format detected)" = "null" ]
  [ "$(cat_field commit-format confidence)" = "none" ]
  assert_contains "$(cat_field commit-format evidence)" "5 of the last 50"
  assert_contains "$(cat_field commit-format evidence)" "below the 20% detection floor"
}

@test "a commitlint config extending a conventional preset sets high confidence" {
  mkrepo commitlint
  commits "Plain" 4
  printf "module.exports = { extends: ['@commitlint/config-conventional'] };\n" > "$PROJ/commitlint.config.js"
  detect
  [ "$status" -eq 0 ]
  [ "$(cat_field commit-format confidence)" = "high" ]
  [ "$(cat_field commit-format preset_match)" = "conventional-commits" ]
  assert_contains "$(cat_field commit-format evidence)" "commitlint.config.js"
}

@test "a package.json commitlint key counts as a commitlint config" {
  mkrepo commitlintpkg
  printf '{"commitlint":{"extends":["@commitlint/config-conventional"]}}\n' > "$PROJ/package.json"
  detect
  [ "$status" -eq 0 ]
  [ "$(cat_field commit-format confidence)" = "high" ]
  assert_contains "$(cat_field commit-format evidence)" "package.json (commitlint key)"
}

# --- branching ---------------------------------------------------------------------------------------------------

@test "branching: feature/ branches are github-flow, a develop plus release/ is git-flow" {
  mkrepo ghflow
  commits "Plain" 1
  git -C "$PROJ" branch feature/a
  git -C "$PROJ" branch feature/b
  git -C "$PROJ" branch feature/c
  detect
  [ "$(cat_field branching detected.model)" = "github-flow" ]
  [ "$(cat_field branching preset_match)" = "github-flow" ]
  [ "$(cat_field branching confidence)" = "high" ]
  [ "$(cat_field branching detected.default_branch)" = "main" ]
  assert_contains "$(cat_field branching evidence)" "3 feature/"

  mkrepo gitflow
  commits "Plain" 1
  git -C "$PROJ" branch develop
  git -C "$PROJ" branch release/1.0
  git -C "$PROJ" branch feature/x
  detect
  [ "$(cat_field branching detected.model)" = "git-flow" ]
  [ "$(cat_field branching preset_match)" = "git-flow" ]
}

@test "branching: a lone main branch is low-confidence trunk-based and unrecognised names are not detected" {
  mkrepo trunk
  commits "Plain" 1
  detect
  [ "$(cat_field branching detected.model)" = "trunk-based" ]
  [ "$(cat_field branching confidence)" = "low" ]

  mkrepo odd
  commits "Plain" 1
  git -C "$PROJ" branch bundle-one
  git -C "$PROJ" branch task-two
  detect
  [ "$(cat_field branching detected)" = "null" ]
  assert_contains "$(cat_field branching evidence)" "no recognised branching pattern"
}

# --- formatting-linting and language-tooling ---------------------------------------------------------------------

# lint_fixture: prettier + eslint + lint script (which would write a marker if it were ever run) + lockfile + tsconfig.
lint_fixture() {
  mkrepo lint
  MARKER="$BATS_TEST_TMPDIR/lint-marker"
  printf '{"scripts":{"lint":"touch %s && eslint .","format":"prettier --write ."},"engines":{"node":">=18"},"devDependencies":{"typescript":"5"}}\n' "$MARKER" > "$PROJ/package.json"
  printf '{}\n' > "$PROJ/.prettierrc"
  printf 'export default [];\n' > "$PROJ/eslint.config.js"
  printf '{"compilerOptions":{"target":"ES2022"}}\n' > "$PROJ/tsconfig.json"
  printf '{}\n' > "$PROJ/package-lock.json"
  printf '20.11.0\n' > "$PROJ/.nvmrc"
  commit_all "chore: add tooling"
}

@test "lint configs: tools, commands and files are reported with high confidence, nothing is executed" {
  lint_fixture
  detect
  [ "$status" -eq 0 ]
  [ "$(cat_field formatting-linting confidence)" = "high" ]
  [ "$(cat_field formatting-linting detected.approach)" = "formatter-and-linter" ]
  [ "$(cat_field formatting-linting preset_match)" = "formatter-and-linter" ]
  [ "$(cat_field formatting-linting detected.lint_command)" = "npm run lint" ]
  [ "$(cat_field formatting-linting detected.format_command)" = "npm run format" ]
  assert_contains "$(cat_field formatting-linting evidence)" ".prettierrc"
  assert_contains "$(cat_field formatting-linting evidence)" "eslint.config.js"
  assert_contains "$(cat_field formatting-linting evidence)" "package.json scripts"
  [ ! -e "$MARKER" ]
}

@test "language tooling: package manager from the lockfile, pinned runtime, lockfile tracked" {
  lint_fixture
  detect
  [ "$(cat_field language-tooling detected.package_manager)" = "npm" ]
  [ "$(cat_field language-tooling detected.runtime)" = "node 20.11.0" ]
  [ "$(cat_field language-tooling detected.lockfile_committed)" = "true" ]
  [ "$(cat_field language-tooling detected.version_policy)" = "pinned-runtime-and-lockfile" ]
  [ "$(cat_field language-tooling preset_match)" = "pinned-runtime-with-lockfile" ]
  [ "$(cat_field language-tooling confidence)" = "high" ]
  assert_contains "$(cat_field language-tooling evidence)" "JavaScript/TypeScript"
  assert_contains "$(cat_field language-tooling evidence)" "package-lock.json"
  assert_contains "$(cat_field language-tooling evidence)" ".nvmrc"
  assert_contains "$(cat_field language-tooling evidence)" "tsconfig.json compilerOptions.target"
}

@test "language tooling: an untracked lockfile is not committed and the policy drops its preset" {
  mkrepo untracked
  printf '{"name":"x"}\n' > "$PROJ/package.json"
  commits "Plain" 1
  printf '{}\n' > "$PROJ/yarn.lock"
  detect
  [ "$(cat_field language-tooling detected.package_manager)" = "yarn" ]
  [ "$(cat_field language-tooling detected.lockfile_committed)" = "false" ]
  [ "$(cat_field language-tooling preset_match)" = "latest-stable" ]
  assert_contains "$(cat_field language-tooling evidence)" "not tracked by git"
}

@test "an .editorconfig alone is low-confidence editorconfig-only" {
  mkproj ec
  printf 'root = true\n' > "$PROJ/.editorconfig"
  detect
  [ "$status" -eq 0 ]
  [ "$(cat_field formatting-linting confidence)" = "low" ]
  [ "$(cat_field formatting-linting detected.approach)" = "editorconfig-only" ]
  [ "$(cat_field formatting-linting preset_match)" = "editorconfig-only" ]
  assert_contains "$(cat_field formatting-linting evidence)" ".editorconfig"
}

@test "a tool config without a script is medium confidence" {
  mkproj mediumcfg
  printf '[tool.ruff]\nline-length = 100\n' > "$PROJ/pyproject.toml"
  detect
  [ "$(cat_field formatting-linting confidence)" = "medium" ]
  assert_contains "$(cat_field formatting-linting evidence)" "ruff"
}

# --- malformed sources ----------------------------------------------------------------------------------------------

@test "malformed package.json, tsconfig and commitlint config are skipped with warnings naming each file" {
  mkrepo malformed
  printf '{ broken\n' > "$PROJ/package.json"
  printf '{ broken\n' > "$PROJ/tsconfig.json"
  printf '{ broken\n' > "$PROJ/.commitlintrc.json"
  commits "Plain" 2
  detect
  [ "$status" -eq 0 ]
  printf '%s' "$output" | jq -e . >/dev/null
  assert_contains "$(jv '.warnings | join("\n")')" "package.json is not valid JSON"
  assert_contains "$(jv '.warnings | join("\n")')" "tsconfig.json is not valid JSON"
  assert_contains "$(jv '.warnings | join("\n")')" ".commitlintrc.json is not valid JSON"
  [ "$(cat_field formatting-linting detected)" = "null" ]
  [ "$(cat_field language-tooling detected)" = "null" ]
  [ "$(cat_field commit-format detected)" = "null" ]
}

@test "a malformed test-config.json is skipped with a warning and testing falls back to other signals" {
  mkproj badtc
  printf '{ broken\n' > "$PROJ/project/configs/test-config.json"
  mkdir "$PROJ/tests"
  detect
  [ "$status" -eq 0 ]
  assert_contains "$(jv '.warnings | join("\n")')" "project/configs/test-config.json is not valid JSON"
  [ "$(cat_field testing detected.test_dir)" = "tests" ]
  [ "$(cat_field testing confidence)" = "medium" ]
}

# --- testing, file-layout, documentation-placement, naming ------------------------------------------------------

@test "testing: directory, test-config tools and test script give high confidence with evidence" {
  mkrepo testing
  mkdir "$PROJ/tests"
  printf 'x\n' > "$PROJ/tests/a.test.js"
  printf '{"scripts":{"test":"jest"}}\n' > "$PROJ/package.json"
  printf '{"tools":[{"tool_name":"jest","type":"unit"},{"tool_name":"-","type":"e2e"}]}\n' > "$PROJ/project/configs/test-config.json"
  detect
  [ "$(cat_field testing confidence)" = "high" ]
  [ "$(cat_field testing detected.test_dir)" = "tests" ]
  [ "$(cat_field testing detected.test_command)" = "npm run test" ]
  assert_contains "$(cat_field testing evidence)" "tests/"
  assert_contains "$(cat_field testing evidence)" "unit: jest"
  assert_not_contains "$(cat_field testing evidence)" "e2e"
}

@test "testing: the npm init placeholder test script is not a signal" {
  mkproj placeholder
  printf '{"scripts":{"test":"echo \\"Error: no test specified\\" && exit 1"}}\n' > "$PROJ/package.json"
  detect
  [ "$(cat_field testing detected)" = "null" ]
}

@test "file-layout: src plus tests is detected, no signal is null" {
  mkrepo layout
  mkdir "$PROJ/src" "$PROJ/tests" "$PROJ/node_modules"
  detect
  [ "$(cat_field file-layout detected.layout)" = "src-and-tests" ]
  [ "$(cat_field file-layout preset_match)" = "src-and-tests" ]
  [ "$(cat_field file-layout confidence)" = "high" ]
  assert_contains "$(cat_field file-layout evidence)" "top-level directories (2): src/, tests/"
  assert_not_contains "$(cat_field file-layout evidence)" "node_modules"

  mkproj nolayout
  detect
  [ "$(cat_field file-layout detected)" = "null" ]
  [ "$(cat_field file-layout confidence)" = "none" ]
}

@test "file-layout: packages/ is a monorepo and Jenga's own project/ tree is ignored" {
  mkproj mono
  mkdir -p "$PROJ/packages/a" "$PROJ/packages/b"
  detect
  [ "$(cat_field file-layout detected.layout)" = "monorepo-packages" ]
  assert_not_contains "$(cat_field file-layout evidence)" "project/"
}

@test "documentation-placement: docs/ plus an internal directory, counted by files" {
  mkproj docs
  mkdir -p "$PROJ/docs" "$PROJ/project/documentation"
  printf 'x\n' > "$PROJ/docs/a.md"
  printf 'x\n' > "$PROJ/docs/b.md"
  printf 'x\n' > "$PROJ/project/documentation/n.md"
  detect
  [ "$(cat_field documentation-placement preset_match)" = "published-docs-in-docs" ]
  [ "$(cat_field documentation-placement confidence)" = "high" ]
  [ "$(cat_field documentation-placement detected.internal_docs_dir)" = "project/documentation" ]
  assert_contains "$(cat_field documentation-placement evidence)" "docs/ holds 2 files"
  assert_contains "$(cat_field documentation-placement evidence)" "project/documentation/ holds 1 files"
}

@test "documentation-placement: the internal directory is resolved from workflow.json, not a literal" {
  mkproj relocated '{"paths":{"documentation":"notes/internal"}}'
  mkdir -p "$PROJ/docs" "$PROJ/notes/internal" "$PROJ/project/documentation"
  printf 'x\n' > "$PROJ/docs/a.md"
  printf 'x\n' > "$PROJ/notes/internal/n.md"
  printf 'x\n' > "$PROJ/project/documentation/decoy.md"
  detect
  [ "$(cat_field documentation-placement detected.internal_docs_dir)" = "notes/internal" ]
  assert_contains "$(cat_field documentation-placement evidence)" "notes/internal/ holds 1 files"
}

@test "documentation-placement: docs/ alone, README alone and nothing" {
  mkproj docsonly
  mkdir "$PROJ/docs"
  printf 'x\n' > "$PROJ/docs/a.md"
  detect
  [ "$(cat_field documentation-placement preset_match)" = "everything-in-docs" ]

  mkproj readme
  printf '# readme\n' > "$PROJ/README.md"
  detect
  [ "$(cat_field documentation-placement preset_match)" = "readme-only" ]
  [ "$(cat_field documentation-placement confidence)" = "low" ]

  mkproj nothing
  detect
  [ "$(cat_field documentation-placement detected)" = "null" ]
}

@test "naming: kebab-case files with camelCase identifiers match the preset, with a casing tally" {
  mkrepo naming
  mkdir "$PROJ/src"
  for n in user-model order-service cart-view price-rule stock-level audit-log tax-table pay-gate ship-plan sale-event; do
    printf 'export function doThing() {}\nconst fooBar = 1;\nconst bazQux = 2;\nclass Thing {}\n' > "$PROJ/src/$n.ts"
  done
  commit_all "feat: add modules"
  detect
  [ "$(cat_field naming detected.file_case)" = "kebab-case" ]
  [ "$(cat_field naming detected.identifier_case)" = "camelCase" ]
  [ "$(cat_field naming preset_match)" = "kebab-files-camel-identifiers" ]
  [ "$(cat_field naming confidence)" = "medium" ]
  assert_contains "$(cat_field naming evidence)" "10 kebab-case, 0 snake_case, 0 camelCase, 0 PascalCase"
}

@test "naming: the sample is capped at 200 files" {
  mkrepo cap
  mkdir "$PROJ/src"
  i=1
  while [ "$i" -le 230 ]; do
    : > "$PROJ/src/mod-file-$i.js"
    i=$((i + 1))
  done
  commit_all "feat: many files"
  detect
  [ "$status" -eq 0 ]
  assert_contains "$(cat_field naming evidence)" "200 source files sampled"
}

@test "naming: no repository or no majority is null" {
  mkproj nogit
  mkdir "$PROJ/src"
  printf 'x\n' > "$PROJ/src/some-file.ts"
  detect
  [ "$(cat_field naming detected)" = "null" ]

  mkrepo mixed
  mkdir "$PROJ/src"
  printf 'x\n' > "$PROJ/src/kebab-one.ts"
  printf 'x\n' > "$PROJ/src/snake_one.ts"
  printf 'x\n' > "$PROJ/src/camelOne.ts"
  printf 'x\n' > "$PROJ/src/PascalOne.ts"
  commit_all "feat: mixed"
  detect
  [ "$(cat_field naming detected)" = "null" ]
  assert_contains "$(cat_field naming evidence)" "no majority"
}

# --- read-only guarantee and downstream compatibility ------------------------------------------------------------

# snapshot <file>: every file (outside .git) with its checksum, plus the porcelain status.
snapshot() {
  (
    cd "$PROJ"
    find . -path ./.git -prune -o -type f -print | sort | xargs cksum
    git status --porcelain
  ) > "$1"
}

@test "the script is read-only: file listing, checksums and git status are identical before and after" {
  lint_fixture
  mkdir -p "$PROJ/src" "$PROJ/tests" "$PROJ/docs"
  printf 'x\n' > "$PROJ/docs/a.md"
  printf 'untracked\n' > "$PROJ/untracked.txt"
  git -C "$PROJ" branch feature/a
  snapshot "$BATS_TEST_TMPDIR/before"
  detect
  [ "$status" -eq 0 ]
  snapshot "$BATS_TEST_TMPDIR/after"
  run diff "$BATS_TEST_TMPDIR/before" "$BATS_TEST_TMPDIR/after"
  [ "$status" -eq 0 ]
  [ ! -e "$MARKER" ]
}

@test "detected values map onto the schema: a conventions.json built from them validates" {
  lint_fixture
  mkdir -p "$PROJ/src" "$PROJ/tests" "$PROJ/docs"
  printf 'x\n' > "$PROJ/docs/a.md"
  git -C "$PROJ" branch feature/a
  detect
  [ "$status" -eq 0 ]
  printf '%s' "$output" | jq '{conventions_version: 1, categories: (.categories | to_entries | map(select(.value.detected != null)) | map({key: .key, value: ({source: "detected", summary: "detected", values: .value.detected} + (if .value.preset_match then {preset: .value.preset_match} else {} end))}) | from_entries)}' > "$BATS_TEST_TMPDIR/derived.json"
  [ "$(jq '.categories | length' "$BATS_TEST_TMPDIR/derived.json")" -ge 4 ]
  run --separate-stderr bash "$VALIDATE" "$BATS_TEST_TMPDIR/derived.json"
  [ "$status" -eq 0 ]
}

@test "evidence strings never contain a newline and the output is a single JSON document" {
  lint_fixture
  detect
  [ "$status" -eq 0 ]
  [ "$(jv '[.categories[].evidence | select(test("\n"))] | length')" = "0" ]
  [ "$(printf '%s' "$output" | jq -s 'length')" = "1" ]
}
