#!/usr/bin/env bats
#
# Coverage for what skills/j-test/scripts/map-scope.sh MAPS (E72_S03_T03).
#
# Contract under test: the script's header and E72_S03_T02's task text, not the implementation. Validation errors,
# edge cases, determinism and the real discovery walk are E72_S03_T04's, in tests/test-scope-map-errors.bats.
#
# How the cases are written
#   - Every repository is built by make_repo inside BATS_TEST_TMPDIR; nothing is written anywhere else and nothing
#     is committed under tests/fixtures/. Git is isolated from the host (no global/system config, local identity,
#     no signing).
#   - run_map is the only place the script is invoked. It always passes `--root <fixture> --suites <json>`, so the
#     real discover-tests.sh is never run, and it runs the script with `bash` so a missing exec bit cannot mask a
#     real result.
#   - Output is compared as canonical JSON (`jq -S -c`) against the expected object, plus targeted `jq -e` queries
#     where one property matters on its own. No raw substring matching of JSON.
#   - The shipped-template cases hand the repo's templates/test-scope-map.json to --map, so each of its six rules has
#     its own case; the selection cases cover which map file gets read at all.
#   - No line below begins with `[[`: tests/bats-assertion-convention.bats bans it.

bats_require_minimum_version 1.5.0

load helpers/assertions

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd -P)"
MAPPER="$REPO_ROOT/skills/j-test/scripts/map-scope.sh"
TEMPLATE="$REPO_ROOT/templates/test-scope-map.json"

# Suites a typical project would have discovered. npm has empty paths, so JS test files reach it by the ecosystem
# fallback; the others claim test files through their own paths.
STD_SUITES='{"suites":[
  {"id":"bats:tests","command":"bats tests/*.bats","paths":["tests/*.bats"]},
  {"id":"npm:test","command":"npm test","paths":[]},
  {"id":"pytest:tests","command":"pytest","paths":["tests/**/test_*.py"]},
  {"id":"go:test","command":"go test ./...","paths":["**/*_test.go"]},
  {"id":"cargo:integration:it","command":"cargo test --test it","paths":["tests/it.rs"]}]}'

setup() {
  export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null GIT_CONFIG_NOSYSTEM=1
  unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE
  SUITES_FILE="$BATS_TEST_TMPDIR/suites.json"
  printf '%s' "$STD_SUITES" > "$SUITES_FILE"
  REPO=""
}

# ---- fixture helpers ---------------------------------------------------------------------------------------------

# make_repo <name>: a fresh empty repository; sets REPO.
make_repo() {
  REPO="$BATS_TEST_TMPDIR/$1"
  mkdir -p "$REPO"
  git -C "$REPO" init -q
  git -C "$REPO" config user.name "Fixture"
  git -C "$REPO" config user.email "fixture@example.invalid"
  git -C "$REPO" config commit.gpgsign false
}

# put <relpath> [content]: write a file (creating directories) in REPO.
put() {
  mkdir -p "$(dirname "$REPO/$1")"
  printf '%s\n' "${2:-content of $1}" > "$REPO/$1"
}

# edit <relpath>: modify a tracked file.
edit() { printf 'changed\n' >> "$REPO/$1"; }

commit_all() {
  git -C "$REPO" add -A
  git -C "$REPO" commit -q -m "$1"
}

head_sha() { git -C "$REPO" rev-parse HEAD; }

# seed_repo <name>: a repository with one commit holding a source file and a test file for every rule of the shipped
# template, a README, and a bats file one directory below the one the bats suite's paths cover.
seed_repo() {
  local f
  make_repo "$1"
  for f in src/a.js lib/a.js test/a.test.js tests/b.test.js src/a.py tests/test_a.py pkg/a.go pkg/a_test.go \
           src/a.rs tests/it.rs scripts/a.sh tests/x.bats tests/sub/y.bats README.md; do
    put "$f"
  done
  commit_all "seed"
}

# use_suites <json>: replace the discovery JSON handed to --suites.
use_suites() { printf '%s' "$1" > "$SUITES_FILE"; }

# write_map <name> <json>: a scope map outside the repo (so it is not a change); sets MAP.
write_map() { MAP="$BATS_TEST_TMPDIR/$1"; printf '%s' "$2" > "$MAP"; }

# run_map [args...]: the only invocation of map-scope.sh. Sets status, output, stderr.
run_map() {
  run --separate-stderr bash "$MAPPER" --root "$REPO" --suites "$SUITES_FILE" "$@"
}

# ---- assertions --------------------------------------------------------------------------------------------------

# expect_json <json>: the output equals <json> as canonical JSON; exit 0 and nothing on stderr.
expect_json() {
  local want got
  [ "$status" -eq 0 ]
  [ -z "$stderr" ]
  want="$(printf '%s' "$1" | jq -S -c .)"
  got="$(printf '%s' "$output" | jq -S -c .)" || { printf 'output is not JSON:\n%s\n' "$output"; return 1; }
  if [ "$got" != "$want" ]; then
    printf 'expected: %s\nactual:   %s\n' "$want" "$got"
    return 1
  fi
}

# expect_jq <filter>: the jq filter is true over the output.
expect_jq() {
  if ! printf '%s' "$output" | jq -e "$1" > /dev/null; then
    printf 'jq -e %s was not true over:\n%s\n' "$1" "$output"
    return 1
  fi
}

# ---- shipped template, one case per rule -------------------------------------------------------------------------

@test "template rule 1: a changed src JS file maps to the npm suite and both JS test directories" {
  seed_repo r
  edit src/a.js
  run_map --map "$TEMPLATE"
  expect_json '{"mapped_suites":["npm:test"],"mapped_tests":{"npm:test":["test/a.test.js","tests/b.test.js"]},"unmapped_files":[],"warnings":[]}'
}

@test "template rule 2: a changed lib JS file maps only to test/, not tests/" {
  seed_repo r
  edit lib/a.js
  run_map --map "$TEMPLATE"
  expect_json '{"mapped_suites":["npm:test"],"mapped_tests":{"npm:test":["test/a.test.js"]},"unmapped_files":[],"warnings":[]}'
  expect_jq '.mapped_tests["npm:test"] | index("tests/b.test.js") == null'
}

@test "template rule 3: a changed src Python file maps to the pytest suite through its paths" {
  seed_repo r
  edit src/a.py
  run_map --map "$TEMPLATE"
  expect_json '{"mapped_suites":["pytest:tests"],"mapped_tests":{"pytest:tests":["tests/test_a.py"]},"unmapped_files":[],"warnings":[]}'
}

@test "template rule 4: a changed Go file maps to the go suite and its _test.go sibling" {
  seed_repo r
  edit pkg/a.go
  run_map --map "$TEMPLATE"
  expect_json '{"mapped_suites":["go:test"],"mapped_tests":{"go:test":["pkg/a_test.go"]},"unmapped_files":[],"warnings":[]}'
}

@test "template rule 5: a changed src Rust file maps to the cargo integration suite" {
  seed_repo r
  edit src/a.rs
  run_map --map "$TEMPLATE"
  expect_json '{"mapped_suites":["cargo:integration:it"],"mapped_tests":{"cargo:integration:it":["tests/it.rs"]},"unmapped_files":[],"warnings":[]}'
}

@test "template rule 6: a changed shell script maps to the bats suite, and only the bats files its paths cover" {
  seed_repo r
  edit scripts/a.sh
  run_map --map "$TEMPLATE"
  # tests/sub/y.bats matches the rule's tests glob but no suite's paths (`*` does not cross `/`): it is not reported.
  expect_json '{"mapped_suites":["bats:tests"],"mapped_tests":{"bats:tests":["tests/x.bats"]},"unmapped_files":[],"warnings":[]}'
}

@test "template: a README change matches no rule and is unmapped" {
  seed_repo r
  edit README.md
  run_map --map "$TEMPLATE"
  expect_json '{"mapped_suites":[],"mapped_tests":{},"unmapped_files":["README.md"],"warnings":["No tests found for the changed files"]}'
}

# ---- additive semantics ------------------------------------------------------------------------------------------

@test "additive: two rules matching one file yield the union of their tests" {
  seed_repo r
  write_map map.json '{"map_version":1,"rules":[
    {"source":"src/*.js","tests":["test/a.test.js"]},
    {"source":"src/a.js","tests":["tests/b.test.js"]}]}'
  edit src/a.js
  run_map --map "$MAP"
  expect_json '{"mapped_suites":["npm:test"],"mapped_tests":{"npm:test":["test/a.test.js","tests/b.test.js"]},"unmapped_files":[],"warnings":[]}'
}

@test "additive: an earlier matching rule that no suite can run does not shadow a later one" {
  seed_repo r
  use_suites '{"suites":[{"id":"npm:test","command":"npm test"}]}'
  write_map map.json '{"map_version":1,"rules":[
    {"source":"src/**/*.js","tests":["tests/sub/y.bats"]},
    {"source":"**/*.js","tests":["test/a.test.js"]}]}'
  edit src/a.js
  run_map --map "$MAP"
  expect_json '{"mapped_suites":["npm:test"],"mapped_tests":{"npm:test":["test/a.test.js"]},"unmapped_files":[],"warnings":["rule 1 (src/**/*.js): test files matched but no discovered suite runs them"]}'
}

# ---- a changed test file -----------------------------------------------------------------------------------------

@test "test file: a changed bats file maps to the bats suite with no rule involved" {
  seed_repo r
  edit tests/x.bats
  run_map --map "$TEMPLATE"
  expect_json '{"mapped_suites":["bats:tests"],"mapped_tests":{"bats:tests":["tests/x.bats"]},"unmapped_files":[],"warnings":[]}'
}

@test "test file: a changed JS test file no suite's paths claim falls back to the npm suite" {
  seed_repo r
  use_suites '{"suites":[
    {"id":"bats:tests","command":"bats tests/*.bats","paths":["tests/*.bats"]},
    {"id":"npm:test","command":"npm test","paths":[]}]}'
  edit test/a.test.js
  run_map --map "$TEMPLATE"
  expect_json '{"mapped_suites":["npm:test"],"mapped_tests":{"npm:test":["test/a.test.js"]},"unmapped_files":[],"warnings":[]}'
}

# ---- glob dialect, observed through the mapper -------------------------------------------------------------------

@test "glob: ** matches zero segments and many, and a file outside the glob stays unmapped" {
  seed_repo r
  put src/x/y/b.js
  put other.js
  commit_all more
  write_map map.json '{"map_version":1,"rules":[{"source":"src/**/*.js","tests":["test/a.test.js"]}]}'
  edit src/a.js
  edit src/x/y/b.js
  edit other.js
  run_map --map "$MAP"
  expect_json '{"mapped_suites":["npm:test"],"mapped_tests":{"npm:test":["test/a.test.js"]},"unmapped_files":["other.js"],"warnings":[]}'
}

@test "glob: * in a source glob does not cross a slash" {
  seed_repo r
  put src/deep/b.js
  commit_all more
  write_map map.json '{"map_version":1,"rules":[{"source":"src/*.js","tests":["test/a.test.js"]}]}'
  edit src/a.js
  edit src/deep/b.js
  run_map --map "$MAP"
  expect_json '{"mapped_suites":["npm:test"],"mapped_tests":{"npm:test":["test/a.test.js"]},"unmapped_files":["src/deep/b.js"],"warnings":[]}'
}

@test "glob: ? matches exactly one character" {
  seed_repo r
  put src/ab.js
  commit_all more
  write_map map.json '{"map_version":1,"rules":[{"source":"src/?.js","tests":["test/a.test.js"]}]}'
  edit src/a.js
  edit src/ab.js
  run_map --map "$MAP"
  expect_json '{"mapped_suites":["npm:test"],"mapped_tests":{"npm:test":["test/a.test.js"]},"unmapped_files":["src/ab.js"],"warnings":[]}'
}

@test "glob: a literal path rule matches that path only" {
  seed_repo r
  put scripts/b.sh
  commit_all more
  write_map map.json '{"map_version":1,"rules":[{"source":"scripts/a.sh","tests":["tests/x.bats"]}]}'
  edit scripts/a.sh
  edit scripts/b.sh
  run_map --map "$MAP"
  expect_json '{"mapped_suites":["bats:tests"],"mapped_tests":{"bats:tests":["tests/x.bats"]},"unmapped_files":["scripts/b.sh"],"warnings":[]}'
}

@test "glob: a tests glob with * does not reach into subdirectories" {
  seed_repo r
  put test/deep/c.test.js
  commit_all more
  write_map map.json '{"map_version":1,"rules":[{"source":"src/a.js","tests":["test/*.test.js"]}]}'
  edit src/a.js
  run_map --map "$MAP"
  expect_json '{"mapped_suites":["npm:test"],"mapped_tests":{"npm:test":["test/a.test.js"]},"unmapped_files":[],"warnings":[]}'
}

@test "glob: a tests glob with ** reaches every depth, zero segments included" {
  seed_repo r
  put test/deep/c.test.js
  commit_all more
  write_map map.json '{"map_version":1,"rules":[{"source":"lib/a.js","tests":["test/**/*.test.js"]}]}'
  edit lib/a.js
  run_map --map "$MAP"
  expect_json '{"mapped_suites":["npm:test"],"mapped_tests":{"npm:test":["test/a.test.js","test/deep/c.test.js"]},"unmapped_files":[],"warnings":[]}'
}

# ---- suite resolution --------------------------------------------------------------------------------------------

@test "suites: a test file covered by two suites' paths maps to both" {
  seed_repo r
  use_suites '{"suites":[
    {"id":"bats:tests","command":"bats tests/*.bats","paths":["tests/*.bats"]},
    {"id":"bats:fast","command":"bats --fast tests/*.bats","paths":["tests/x*.bats"]}]}'
  edit tests/x.bats
  run_map --map "$TEMPLATE"
  expect_json '{"mapped_suites":["bats:fast","bats:tests"],"mapped_tests":{"bats:fast":["tests/x.bats"],"bats:tests":["tests/x.bats"]},"unmapped_files":[],"warnings":[]}'
}

@test "suites: identical-command suites collapse to the lowest id, which takes the union of their tests" {
  seed_repo r
  put tests/integ/i.bats
  commit_all more
  # The higher id is listed first on purpose: the winner is the lowest id, not the first one seen.
  use_suites '{"suites":[
    {"id":"config:bats:integration","command":"bats tests/*.bats","paths":["tests/integ/*.bats"]},
    {"id":"bats:tests","command":"bats tests/*.bats","paths":["tests/*.bats"]}]}'
  edit tests/x.bats
  edit tests/integ/i.bats
  run_map --map "$TEMPLATE"
  expect_json '{"mapped_suites":["bats:tests"],"mapped_tests":{"bats:tests":["tests/integ/i.bats","tests/x.bats"]},"unmapped_files":[],"warnings":[]}'
  expect_jq '.mapped_suites | index("config:bats:integration") == null'
}

@test "suites: an empty-command suite is dropped with its warning, and mapping nothing else stays loud" {
  seed_repo r
  use_suites '{"suites":[{"id":"bats:tests","command":"","paths":["tests/*.bats"]}]}'
  edit tests/x.bats
  run_map --map "$TEMPLATE"
  [ "$status" -eq 0 ]
  expect_jq '.mapped_suites == [] and .mapped_tests == {}'
  expect_jq '.warnings == ["No tests found for the changed files","suite bats:tests has no runnable command; skipped"]'
}

@test "suites: dropping an empty-command suite leaves the runnable ones mapped" {
  seed_repo r
  use_suites '{"suites":[
    {"id":"bats:tests","command":"","paths":["tests/*.bats"]},
    {"id":"bats:other","command":"bats tests/x.bats","paths":["tests/x*.bats"]}]}'
  edit tests/x.bats
  run_map --map "$TEMPLATE"
  expect_json '{"mapped_suites":["bats:other"],"mapped_tests":{"bats:other":["tests/x.bats"]},"unmapped_files":[],"warnings":["suite bats:tests has no runnable command; skipped"]}'
}

# ---- change sources ----------------------------------------------------------------------------------------------

@test "source --rev: a normal commit is diffed against its parent" {
  seed_repo r
  edit src/a.js
  commit_all "touch src"
  run_map --map "$TEMPLATE" --rev HEAD
  expect_json '{"mapped_suites":["npm:test"],"mapped_tests":{"npm:test":["test/a.test.js","tests/b.test.js"]},"unmapped_files":[],"warnings":[]}'
}

@test "source --rev: a root commit lists every file it added" {
  make_repo root
  put src/a.js
  put test/a.test.js
  put README.md
  commit_all root
  run_map --map "$TEMPLATE" --rev HEAD
  expect_json '{"mapped_suites":["npm:test"],"mapped_tests":{"npm:test":["test/a.test.js"]},"unmapped_files":["README.md"],"warnings":[]}'
}

@test "source --rev: only the last of several commits counts" {
  seed_repo r
  edit src/a.js
  commit_all "touch src"
  edit README.md
  commit_all "touch readme"
  run_map --map "$TEMPLATE" --rev HEAD
  expect_json '{"mapped_suites":[],"mapped_tests":{},"unmapped_files":["README.md"],"warnings":["No tests found for the changed files"]}'
  run_map --map "$TEMPLATE" --rev HEAD~1
  expect_jq '.mapped_suites == ["npm:test"] and .unmapped_files == []'
}

@test "source --range: a..b covers the commits after a up to b and no others" {
  local first last
  seed_repo r
  first="$(head_sha)"
  edit src/a.js
  commit_all "touch src"
  edit scripts/a.sh
  commit_all "touch script"
  last="$(head_sha)"
  edit README.md
  commit_all "touch readme"
  run_map --map "$TEMPLATE" --range "$first..$last"
  expect_json '{"mapped_suites":["bats:tests","npm:test"],"mapped_tests":{"bats:tests":["tests/x.bats"],"npm:test":["test/a.test.js","tests/b.test.js"]},"unmapped_files":[],"warnings":[]}'
}

@test "source --staged: an unstaged edit is ignored" {
  seed_repo r
  edit src/a.js
  git -C "$REPO" add src/a.js
  edit scripts/a.sh
  run_map --map "$TEMPLATE" --staged
  expect_json '{"mapped_suites":["npm:test"],"mapped_tests":{"npm:test":["test/a.test.js","tests/b.test.js"]},"unmapped_files":[],"warnings":[]}'
  expect_jq '.mapped_suites | index("bats:tests") == null'
}

@test "source --working: staged, unstaged and untracked files count, an ignored file does not" {
  seed_repo r
  put .gitignore '*.log'
  commit_all "ignore logs"
  edit src/a.js
  git -C "$REPO" add src/a.js
  edit scripts/a.sh
  put src/new.py
  put docs/new.md
  put build.log
  run_map --map "$TEMPLATE" --working
  # npm from the staged edit, bats from the unstaged one, pytest from the untracked source file.
  expect_json '{"mapped_suites":["bats:tests","npm:test","pytest:tests"],"mapped_tests":{"bats:tests":["tests/x.bats"],"npm:test":["test/a.test.js","tests/b.test.js"],"pytest:tests":["tests/test_a.py"]},"unmapped_files":["docs/new.md"],"warnings":[]}'
  expect_jq '(.unmapped_files | index("build.log")) == null'
}

@test "source default: no flag behaves exactly as --working" {
  local explicit
  seed_repo r
  edit src/a.js
  edit scripts/a.sh
  put docs/new.md
  run_map --map "$TEMPLATE" --working
  explicit="$output"
  expect_jq '.mapped_suites == ["bats:tests","npm:test"] and .unmapped_files == ["docs/new.md"]'
  run_map --map "$TEMPLATE"
  [ "$status" -eq 0 ]
  [ "$output" = "$explicit" ]
}

@test "source: a rename reports both the old and the new name" {
  seed_repo r
  git -C "$REPO" mv README.md docs.md
  run_map --map "$TEMPLATE" --staged
  expect_json '{"mapped_suites":[],"mapped_tests":{},"unmapped_files":["README.md","docs.md"],"warnings":["No tests found for the changed files"]}'
  commit_all "rename"
  run_map --map "$TEMPLATE" --rev HEAD
  expect_jq '.unmapped_files == ["README.md","docs.md"]'
}

# ---- which mapping file is read ----------------------------------------------------------------------------------

@test "map file: --map selects the file whose rules apply" {
  seed_repo r
  put docs/g.md
  commit_all more
  write_map map.json '{"map_version":1,"rules":[{"source":"docs/*.md","tests":["test/a.test.js"]}]}'
  edit docs/g.md
  run_map --map "$MAP"
  expect_json '{"mapped_suites":["npm:test"],"mapped_tests":{"npm:test":["test/a.test.js"]},"unmapped_files":[],"warnings":[]}'
}

@test "map file: commit_scope_map_file in the fixture's test-config.json is read, relative to the root" {
  seed_repo r
  put docs/g.md
  put config/scope-map.json '{"map_version":1,"rules":[{"source":"docs/*.md","tests":["test/a.test.js"]}]}'
  put project/configs/test-config.json '{"commit_scope_map_file":"config/scope-map.json"}'
  commit_all more
  edit docs/g.md
  run_map
  expect_json '{"mapped_suites":["npm:test"],"mapped_tests":{"npm:test":["test/a.test.js"]},"unmapped_files":[],"warnings":[]}'
}

@test "map file: an absent commit_scope_map_file key reads the shipped template" {
  seed_repo r
  put project/configs/test-config.json '{}'
  commit_all more
  edit src/a.js
  run_map
  expect_json '{"mapped_suites":["npm:test"],"mapped_tests":{"npm:test":["test/a.test.js","tests/b.test.js"]},"unmapped_files":[],"warnings":[]}'
}

@test "map file: the root's own templates/test-scope-map.json is read before the shipped copy" {
  seed_repo r
  put templates/test-scope-map.json '{"map_version":1,"rules":[{"source":"docs/*.md","tests":["test/a.test.js"]}]}'
  put docs/g.md
  commit_all more
  edit docs/g.md
  edit src/a.js
  run_map
  # Only the root's own docs rule exists: src/a.js would map under the shipped template, and does not here.
  expect_json '{"mapped_suites":["npm:test"],"mapped_tests":{"npm:test":["test/a.test.js"]},"unmapped_files":["src/a.js"],"warnings":[]}'
}

@test "map file: --map beats commit_scope_map_file" {
  seed_repo r
  put docs/g.md
  put config/scope-map.json '{"map_version":1,"rules":[{"source":"docs/*.md","tests":["test/a.test.js"]}]}'
  put config/other.json '{"map_version":1,"rules":[{"source":"docs/*.md","tests":["tests/b.test.js"]}]}'
  put project/configs/test-config.json '{"commit_scope_map_file":"config/scope-map.json"}'
  commit_all more
  edit docs/g.md
  run_map --map "$REPO/config/other.json"
  expect_json '{"mapped_suites":["npm:test"],"mapped_tests":{"npm:test":["tests/b.test.js"]},"unmapped_files":[],"warnings":[]}'
}

# ---- zero mapped suites is never silent --------------------------------------------------------------------------

@test "zero mapped: a docs-only change prints exactly the specified single-line object" {
  seed_repo r
  edit README.md
  run_map --map "$TEMPLATE"
  [ "$status" -eq 0 ]
  [ "$output" = '{"mapped_suites":[],"mapped_tests":{},"unmapped_files":["README.md"],"warnings":["No tests found for the changed files"]}' ]
}

@test "zero mapped: an empty suites array additionally warns that no test suites were discovered" {
  seed_repo r
  use_suites '{"suites":[]}'
  edit README.md
  run_map --map "$TEMPLATE"
  expect_json '{"mapped_suites":[],"mapped_tests":{},"unmapped_files":["README.md"],"warnings":["No test suites discovered","No tests found for the changed files"]}'
}

# ---- per-rule warnings -------------------------------------------------------------------------------------------

@test "rule warning: a matching rule whose test globs match no file names its index, source and file count" {
  seed_repo r
  put src/z.js
  commit_all more
  write_map map.json '{"map_version":1,"rules":[
    {"source":"docs/**/*.md","tests":["nothing/*.test.js"]},
    {"source":"src/**/*.js","tests":["nothing/**/*.test.js"]}]}'
  edit src/a.js
  edit src/z.js
  run_map --map "$MAP"
  # Rule 1 never matched a changed file, so only rule 2 warns.
  expect_json '{"mapped_suites":[],"mapped_tests":{},"unmapped_files":["src/a.js","src/z.js"],"warnings":["No tests found for the changed files","rule 2 (src/**/*.js): 2 changed file(s) matched but no existing test file matched its tests globs"]}'
}

@test "rule warning: matched test files that no discovered suite runs are named" {
  seed_repo r
  use_suites '{"suites":[{"id":"npm:test","command":"npm test"}]}'
  write_map map.json '{"map_version":1,"rules":[{"source":"scripts/*.sh","tests":["tests/**/*.bats"]}]}'
  edit scripts/a.sh
  run_map --map "$MAP"
  expect_json '{"mapped_suites":[],"mapped_tests":{},"unmapped_files":["scripts/a.sh"],"warnings":["No tests found for the changed files","rule 1 (scripts/*.sh): test files matched but no discovered suite runs them"]}'
}

# ---- isolation ---------------------------------------------------------------------------------------------------

# tree_sum <dir>: a checksum over every file under <dir>, .git included.
tree_sum() { (cd "$1" && find . -type f | LC_ALL=C sort | xargs cksum | cksum); }

# real_state: the real repository's HEAD, git status and index listing.
real_state() {
  { git -C "$REPO_ROOT" rev-parse HEAD
    git -C "$REPO_ROOT" status --porcelain
    git -C "$REPO_ROOT" ls-files -s
  } | cksum
}

@test "isolation: runs in every change mode leave the real repository and the fixture untouched" {
  local real_before real_after fixture_before fixture_after
  seed_repo r
  edit src/a.js
  git -C "$REPO" add src/a.js
  put docs/new.md
  real_before="$(real_state)"
  fixture_before="$(tree_sum "$REPO")"
  # cwd is the real repository on purpose: --root, not the cwd, must decide where git looks.
  cd "$REPO_ROOT"
  run_map --map "$TEMPLATE"
  [ "$status" -eq 0 ]
  run_map --map "$TEMPLATE" --working
  [ "$status" -eq 0 ]
  run_map --map "$TEMPLATE" --staged
  [ "$status" -eq 0 ]
  run_map --map "$TEMPLATE" --rev HEAD
  [ "$status" -eq 0 ]
  real_after="$(real_state)"
  fixture_after="$(tree_sum "$REPO")"
  [ "$real_before" = "$real_after" ]
  [ "$fixture_before" = "$fixture_after" ]
}
