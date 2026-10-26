#!/usr/bin/env bats
#
# E80_S01_T05: scripts/workflow/load-workflows.sh, the merged builtin + project workflow catalog.
# Covers: the script is present, executable and bash -n clean; a builtin and a project definition both load with the
# right `source`, a `file` field and id-sorted output; no project directory (silent, exit 0, empty stderr); an empty
# or missing builtin directory (`[]`, silent); an `id` collision (builtin wins, stderr names both files and the id);
# two project files with the same id (the lexicographically first wins); an invalid file (absent, stderr names it and
# the validator's reason, the rest still load, exit 0); a file that is not JSON; an invalid builtin file not shadowing
# a project definition; definitions carried through unchanged; and the real templates/workflows/ holding only .gitkeep plus the example-report definition and its template (E80_S06_T02).
#
# Every tree is synthetic, under $BATS_TEST_TMPDIR, selected with JENGA_WORKFLOWS_TEST_ROOT; the schema and type
# registry are copied in so the real validator runs against them. The repository's own templates/workflows/ is only
# listed, never written. Nothing reads this repository's board or any private path.

bats_require_minimum_version 1.5.0
load helpers/assertions

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
LOADER="$REPO_ROOT/scripts/workflow/load-workflows.sh"

setup() {
  unset JENGA_PROJECT_ROOT
  ROOT="$BATS_TEST_TMPDIR/box"
  mkdir -p "$ROOT/templates/workflows"
  cp "$REPO_ROOT/templates/workflow-schema.json" "$REPO_ROOT/templates/playbook-types.json" "$ROOT/templates/"
  export JENGA_WORKFLOWS_TEST_ROOT="$ROOT"
  BUILTIN="$ROOT/templates/workflows"
  PROJECT="$ROOT/project/.workflows"
}

# wf <id>: prints a minimal valid definition with that id.
wf() {
  jq -n --arg id "$1" '{id: $id, name: ("Flow " + $id), description: "Fixture.",
    steps: [ { id: "only", type: "skill", skill: "j.status" } ]}'
}

# put <dir> <file name> <id>: writes a valid definition into <dir>.
put() {
  mkdir -p "$1"
  wf "$3" > "$1/$2"
}

# ids: prints the comma-joined ids of the catalog held in $output.
ids() {
  printf '%s' "$output" | jq -r '[.[].id] | join(",")'
}

# run_loader: runs the loader keeping stdout and stderr apart ($output is stdout, $stderr is stderr).
run_loader() {
  run --separate-stderr bash "$LOADER"
}

@test "the loader exists, is executable and passes bash -n" {
  [ -f "$LOADER" ]
  [ -x "$LOADER" ]
  run bash -n "$LOADER"
  [ "$status" -eq 0 ]
}

@test "the header documents usage, the source and file fields, exit codes and the collision rule" {
  head -n 70 "$LOADER" > "$BATS_TEST_TMPDIR/header.txt"
  run cat "$BATS_TEST_TMPDIR/header.txt"
  assert_output_contains "USAGE"
  assert_output_contains '"source"'
  assert_output_contains '"file"'
  assert_output_contains "EXIT CODES"
  assert_output_contains "COLLISION RULE"
}

@test "-h prints usage and exits 0; an argument is a usage error" {
  run bash "$LOADER" -h
  [ "$status" -eq 0 ]
  assert_output_contains "Usage: load-workflows.sh"
  run bash "$LOADER" extra
  [ "$status" -eq 2 ]
}

@test "one builtin and one project definition load with the right source, sorted by id" {
  put "$BUILTIN" zeta.json zeta
  put "$PROJECT" alpha.json alpha
  run_loader
  [ "$status" -eq 0 ]
  [ -z "$stderr" ]
  [ "$(printf '%s' "$output" | jq 'length')" = "2" ]
  [ "$(ids)" = "alpha,zeta" ]
  [ "$(printf '%s' "$output" | jq -r '.[] | select(.id == "alpha") | .source')" = "project" ]
  [ "$(printf '%s' "$output" | jq -r '.[] | select(.id == "zeta") | .source')" = "builtin" ]
}

@test "each entry carries a file field naming the definition file" {
  put "$BUILTIN" zeta.json zeta
  put "$PROJECT" alpha.json alpha
  run_loader
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r '.[] | select(.id == "zeta") | .file')" = "$BUILTIN/zeta.json" ]
  [ "$(printf '%s' "$output" | jq -r '.[] | select(.id == "alpha") | .file')" = "$PROJECT/alpha.json" ]
}

@test "definitions are carried through unchanged apart from source and file" {
  put "$BUILTIN" zeta.json zeta
  run_loader
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -c '.[0] | del(.source, .file)')" = "$(wf zeta | jq -c .)" ]
}

@test "output is sorted by id across both sources and is deterministic" {
  put "$BUILTIN" a.json mmm
  put "$BUILTIN" b.json bbb
  put "$PROJECT" c.json zzz
  put "$PROJECT" d.json aaa
  run_loader
  [ "$status" -eq 0 ]
  [ "$(ids)" = "aaa,bbb,mmm,zzz" ]
  first="$output"
  run_loader
  [ "$output" = "$first" ]
}

@test "no project directory: exit 0, builtin entries printed, stderr empty" {
  put "$BUILTIN" zeta.json zeta
  [ ! -e "$PROJECT" ]
  run_loader
  [ "$status" -eq 0 ]
  [ -z "$stderr" ]
  [ "$(ids)" = "zeta" ]
}

@test "no project directory and an empty builtin directory: [] and empty stderr" {
  run_loader
  [ "$status" -eq 0 ]
  [ -z "$stderr" ]
  [ "$(printf '%s' "$output" | jq -c .)" = "[]" ]
}

@test "no builtin directory either: [] and empty stderr" {
  rm -rf "$BUILTIN"
  run_loader
  [ "$status" -eq 0 ]
  [ -z "$stderr" ]
  [ "$(printf '%s' "$output" | jq -c .)" = "[]" ]
}

@test "a .gitkeep and non-json files in a directory are ignored silently" {
  : > "$BUILTIN/.gitkeep"
  printf 'notes\n' > "$BUILTIN/README.md"
  put "$PROJECT" alpha.json alpha
  run_loader
  [ "$status" -eq 0 ]
  [ -z "$stderr" ]
  [ "$(ids)" = "alpha" ]
}

@test "an id collision: the builtin entry stays, the project entry is dropped, stderr names both files and the id" {
  put "$BUILTIN" shared.json shared
  put "$PROJECT" mine.json shared
  run_loader
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq 'length')" = "1" ]
  [ "$(printf '%s' "$output" | jq -r '.[0].source')" = "builtin" ]
  [ "$(printf '%s' "$output" | jq -r '.[0].file')" = "$BUILTIN/shared.json" ]
  assert_contains "$stderr" "$BUILTIN/shared.json"
  assert_contains "$stderr" "$PROJECT/mine.json"
  assert_contains "$stderr" "'shared'"
}

@test "a collision does not stop other project definitions from loading" {
  put "$BUILTIN" shared.json shared
  put "$PROJECT" mine.json shared
  put "$PROJECT" other.json other
  run_loader
  [ "$status" -eq 0 ]
  [ "$(ids)" = "other,shared" ]
}

@test "two project files with the same id: the lexicographically first wins and stderr names both" {
  put "$PROJECT" b-second.json dup
  put "$PROJECT" a-first.json dup
  run_loader
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq 'length')" = "1" ]
  [ "$(printf '%s' "$output" | jq -r '.[0].file')" = "$PROJECT/a-first.json" ]
  assert_contains "$stderr" "$PROJECT/a-first.json"
  assert_contains "$stderr" "$PROJECT/b-second.json"
  assert_contains "$stderr" "'dup'"
}

@test "an invalid file is absent, stderr names it with the validator's reason, the rest still load" {
  put "$BUILTIN" good.json good
  mkdir -p "$PROJECT"
  wf broken | jq 'del(.name)' > "$PROJECT/broken.json"
  put "$PROJECT" fine.json fine
  run_loader
  [ "$status" -eq 0 ]
  [ "$(ids)" = "fine,good" ]
  assert_contains "$stderr" "$PROJECT/broken.json"
  assert_contains "$stderr" "missing required"
  assert_contains "$stderr" "name"
}

@test "a semantic problem is reported as the validator's reason" {
  mkdir -p "$PROJECT"
  wf badref | jq '.steps[0].args = {a: "${inputs.nope}"}' > "$PROJECT/badref.json"
  put "$PROJECT" fine.json fine
  run_loader
  [ "$status" -eq 0 ]
  [ "$(ids)" = "fine" ]
  assert_contains "$stderr" "$PROJECT/badref.json"
  assert_contains "$stderr" "inputs.nope"
}

@test "a file that is not JSON is dropped with a warning and exit stays 0" {
  mkdir -p "$PROJECT"
  printf '{ not json\n' > "$PROJECT/garbage.json"
  put "$PROJECT" fine.json fine
  run_loader
  [ "$status" -eq 0 ]
  [ "$(ids)" = "fine" ]
  assert_contains "$stderr" "$PROJECT/garbage.json"
}

@test "an invalid builtin file does not shadow a project definition with the same id" {
  mkdir -p "$BUILTIN"
  wf shared | jq 'del(.steps)' > "$BUILTIN/shared.json"
  put "$PROJECT" mine.json shared
  run_loader
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r '.[0].source')" = "project" ]
  assert_contains "$stderr" "$BUILTIN/shared.json"
  assert_not_contains "$stderr" "already defined"
}

@test "the project directory follows the dot-prefixed working-file tree when that is the layout" {
  mkdir -p "$ROOT/.project/configs"
  cp "$REPO_ROOT/project/configs/workflow.json" "$ROOT/.project/configs/workflow.json"
  put "$ROOT/.project/.workflows" dot.json dot
  run_loader
  [ "$status" -eq 0 ]
  [ "$(ids)" = "dot" ]
}

@test "the loader resolves the validator relative to itself, not the working directory" {
  put "$PROJECT" alpha.json alpha
  cd "$BATS_TEST_TMPDIR"
  run_loader
  [ "$status" -eq 0 ]
  [ -z "$stderr" ]
  [ "$(ids)" = "alpha" ]
}

@test "an unusable schema is a loader failure (exit 2), not a silently dropped file" {
  put "$PROJECT" alpha.json alpha
  rm "$ROOT/templates/workflow-schema.json"
  run_loader
  [ "$status" -eq 2 ]
  assert_contains "$stderr" "validator could not run"
}

@test "the real templates/workflows/ holds .gitkeep and only the example-report definition and its template" {
  [ -f "$REPO_ROOT/templates/workflows/.gitkeep" ]
  run find "$REPO_ROOT/templates/workflows" -type f ! -name .gitkeep ! -name example-report.json ! -name example-report.md
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  # the only .json the loader scans is the one example-report definition
  run find "$REPO_ROOT/templates/workflows" -type f -name '*.json'
  [ "$output" = "$REPO_ROOT/templates/workflows/example-report.json" ]
}
