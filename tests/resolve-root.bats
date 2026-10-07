#!/usr/bin/env bats
#
# E34_S01_T04: scripts/resolve-root.sh is the shared working-file root and per-key path resolver.
# Every case builds its own throwaway trees under $BATS_TEST_TMPDIR (a conventional ./project/ tree
# and a relocated ./.project/ tree), so nothing here reads this repo's board or any private path.
#
# Mirror safety: this file ships to the public mirror and runs there in a mirror-shaped tree. It
# depends only on scripts/resolve-root.sh, templates/SCRUM_BOARD_SCHEMA.md, and fixtures it builds.
# It must not read any private skill or board path, or any other .publicignore'd path (see
# project/documentation/public-mirror-content-parity.md). The one read of the real
# project/configs/workflow.json is conditional and skips when that file is absent. The
# "project/..." strings below are registry VALUES written into scratch fixtures, never reads.

load helpers/assertions

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
RESOLVER="$REPO_ROOT/scripts/resolve-root.sh"
SCHEMA_DOC="$REPO_ROOT/templates/SCRUM_BOARD_SCHEMA.md"

# key|conventional default, in the order the contract documents them. The consistency-guard case
# below proves this table matches the script's built-in defaults and the schema doc's key table.
DEFAULTS="board|project/board
epics|project/board/epics
stories|project/board/stories
tasks|project/board/tasks
rapports_problems|project/rapports/problems
rapports_analysis|project/rapports/analysis
queue|project/queue
scrum_triggers|project/queue/scrum_triggers.jsonl
developer_triggers|project/queue/developer_triggers.jsonl
tester_triggers|project/queue/tester_triggers.jsonl
session_handoff|project/queue/handoffs
logs|project/logs
data|project/data
configs|project/configs
documentation|project/documentation
documentation_plans|project/documentation/plans
documentation_summaries|project/documentation/summaries
strategy|project/documentation/STRATEGY.md"

setup() {
  unset JENGA_PROJECT_ROOT JENGA_RESOLVE_STRICT
  CONV="$BATS_TEST_TMPDIR/conv"
  REL="$BATS_TEST_TMPDIR/rel"
  EMPTY="$BATS_TEST_TMPDIR/empty"
  mkdir -p "$CONV/sub/deep" "$REL/sub/deep" "$EMPTY"
}

# expected_rel <key> <tree>: the registry/default value for a key under tree "project" or ".project".
expected_rel() {
  local line k v
  while IFS='|' read -r k v; do
    if [ "$k" = "$1" ]; then
      case "$v" in project/*) v="$2/${v#project/}" ;; esac
      printf '%s' "$v"
      return 0
    fi
  done <<EOF
$DEFAULTS
EOF
  return 1
}

# registry_json <tree>: a full 18-key registry, session_handoff stored with a trailing slash as in
# the real registry, plus a same-named key outside `paths` that a naive grep fallback would pick up.
registry_json() {
  local k v body="" sep=""
  while IFS='|' read -r k v; do
    v=$(expected_rel "$k" "$1")
    if [ "$k" = "session_handoff" ]; then v="$v/"; fi
    body="$body$sep    \"$k\": \"$v\""
    sep=$',\n'
  done <<EOF
$DEFAULTS
EOF
  printf '{\n  "other": {"queue": "wrong", "data": "wrong"},\n  "paths": {\n%s\n  }\n}\n' "$body"
}

# make_tree <dir> <tree>: writes a full registry at <dir>/<tree>/configs/workflow.json.
make_tree() {
  mkdir -p "$1/$2/configs"
  registry_json "$2" > "$1/$2/configs/workflow.json"
}

# write_registry <dir> <tree> <json>
write_registry() {
  mkdir -p "$1/$2/configs"
  printf '%s\n' "$3" > "$1/$2/configs/workflow.json"
}

# resolve <dir> <args...>: run the resolver from <dir>.
resolve() {
  local dir="$1"
  shift
  cd "$dir" || return 1
  bash "$RESOLVER" "$@"
}

# nojq_path: a PATH holding only the tools the resolver's fallback needs, with jq absent.
nojq_path() {
  local bin="$BATS_TEST_TMPDIR/nojq" t
  mkdir -p "$bin"
  for t in sed grep tr head cat; do
    ln -sf "$(command -v "$t")" "$bin/$t"
  done
  printf '%s' "$bin"
}

resolve_nojq() {
  local dir="$1" bin
  shift
  bin=$(nojq_path)
  cd "$dir" || return 1
  PATH="$bin" "$BASH" "$RESOLVER" "$@"
}

anchor_of() {
  (cd "$1" && pwd)
}

# --- conventional tree ---------------------------------------------------------------------------

@test "conventional tree: root, source and tree from the anchor and from a nested subdirectory" {
  make_tree "$CONV" project
  local anchor
  anchor=$(anchor_of "$CONV")
  for d in "$CONV" "$CONV/sub/deep"; do
    run resolve "$d" root
    [ "$status" -eq 0 ]
    [ "$output" = "$anchor" ]
    run resolve "$d" source
    [ "$status" -eq 0 ]
    [ "$output" = "search" ]
    run resolve "$d" tree
    [ "$status" -eq 0 ]
    [ "$output" = "project" ]
  done
}

@test "conventional tree: get resolves all 18 keys to absolute paths, from the anchor and a nested subdirectory" {
  make_tree "$CONV" project
  local anchor k v
  anchor=$(anchor_of "$CONV")
  for d in "$CONV" "$CONV/sub/deep"; do
    while IFS='|' read -r k v; do
      run resolve "$d" get "$k"
      [ "$status" -eq 0 ]
      [ "$output" = "$anchor/$v" ]
    done <<EOF
$DEFAULTS
EOF
  done
}

@test "conventional tree: --relative returns the registry value with no trailing slash" {
  make_tree "$CONV" project
  local k v
  while IFS='|' read -r k v; do
    run resolve "$CONV/sub" get "$k" --relative
    [ "$status" -eq 0 ]
    [ "$output" = "$v" ]
  done <<EOF
$DEFAULTS
EOF
}

@test "conventional tree: list prints 18 key=path lines in the documented order" {
  make_tree "$CONV" project
  local anchor k v expected=""
  anchor=$(anchor_of "$CONV")
  while IFS='|' read -r k v; do
    expected="$expected$k=$anchor/$v"$'\n'
  done <<EOF
$DEFAULTS
EOF
  run resolve "$CONV/sub" list
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 18 ]
  [ "$output" = "${expected%$'\n'}" ]
}

# --- relocated tree ------------------------------------------------------------------------------

@test "relocated tree: root, source and tree are found with only .project/ present" {
  make_tree "$REL" .project
  local anchor
  anchor=$(anchor_of "$REL")
  for d in "$REL" "$REL/sub/deep"; do
    run resolve "$d" root
    [ "$status" -eq 0 ]
    [ "$output" = "$anchor" ]
    run resolve "$d" source
    [ "$status" -eq 0 ]
    [ "$output" = "search" ]
    run resolve "$d" tree
    [ "$status" -eq 0 ]
    [ "$output" = ".project" ]
  done
}

@test "relocated tree: all 18 keys resolve under .project/ and nothing touches ./project/" {
  make_tree "$REL" .project
  local anchor k v want
  anchor=$(anchor_of "$REL")
  for d in "$REL" "$REL/sub/deep"; do
    while IFS='|' read -r k v; do
      want=$(expected_rel "$k" .project)
      run resolve "$d" get "$k"
      [ "$status" -eq 0 ]
      [ "$output" = "$anchor/$want" ]
    done <<EOF
$DEFAULTS
EOF
  done
  run resolve "$REL" list
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 18 ]
  assert_output_contains "queue=$anchor/.project/queue"
  assert_output_not_contains "$anchor/project/"
  # Read-only: resolving must not have created the conventional tree beside the real one.
  [ ! -e "$REL/project" ]
}

@test "relocated tree: a partial registry's missing keys default under .project/, not ./project/" {
  write_registry "$REL" .project '{"paths": {"queue": ".project/custom-queue"}}'
  local anchor
  anchor=$(anchor_of "$REL")
  run resolve "$REL" get queue --relative
  [ "$output" = ".project/custom-queue" ]
  run resolve "$REL" get logs --relative
  [ "$status" -eq 0 ]
  [ "$output" = ".project/logs" ]
  run resolve "$REL" get strategy --relative
  [ "$output" = ".project/documentation/STRATEGY.md" ]
  [ ! -e "$REL/project" ]
}

# --- layer precedence ----------------------------------------------------------------------------

@test "JENGA_PROJECT_ROOT beats a closer registry found by the upward search" {
  make_tree "$CONV" project
  make_tree "$REL" .project
  export JENGA_PROJECT_ROOT="$REL"
  run resolve "$CONV/sub" root
  [ "$status" -eq 0 ]
  [ "$output" = "$(anchor_of "$REL")" ]
  run resolve "$CONV/sub" source
  [ "$output" = "env" ]
  run resolve "$CONV/sub" tree
  [ "$output" = ".project" ]
  run resolve "$CONV/sub" get board --relative
  [ "$output" = ".project/board" ]
}

@test "JENGA_PROJECT_ROOT with no registry exits 3 with an actionable message and does not fall through" {
  make_tree "$CONV" project
  export JENGA_PROJECT_ROOT="$EMPTY"
  run resolve "$CONV" root
  [ "$status" -eq 3 ]
  assert_output_contains "JENGA_PROJECT_ROOT"
  assert_output_contains "$EMPTY"
  run resolve "$CONV" get board
  [ "$status" -eq 3 ]
  run resolve "$CONV" list
  [ "$status" -eq 3 ]
}

@test "JENGA_PROJECT_ROOT naming a directory that does not exist exits 3" {
  export JENGA_PROJECT_ROOT="$BATS_TEST_TMPDIR/does-not-exist"
  run resolve "$EMPTY" root
  [ "$status" -eq 3 ]
  assert_output_contains "JENGA_PROJECT_ROOT"
}

@test "nearest ancestor registry wins over a farther one" {
  make_tree "$CONV" project
  mkdir -p "$CONV/inner/sub"
  make_tree "$CONV/inner" project
  run resolve "$CONV/inner/sub" root
  [ "$status" -eq 0 ]
  [ "$output" = "$(anchor_of "$CONV/inner")" ]
  run resolve "$CONV/sub" root
  [ "$output" = "$(anchor_of "$CONV")" ]
}

@test "project/ beats .project/ when both exist in one directory" {
  make_tree "$CONV" project
  make_tree "$CONV" .project
  run resolve "$CONV" tree
  [ "$status" -eq 0 ]
  [ "$output" = "project" ]
  run resolve "$CONV" get queue --relative
  [ "$output" = "project/queue" ]
}

@test "upward search reaches a registry 25 ancestors up and stops before 26" {
  make_tree "$CONV" project
  local near="$CONV" far="$CONV" i
  for i in $(seq 1 25); do near="$near/d$i"; done
  for i in $(seq 1 26); do far="$far/d$i"; done
  mkdir -p "$far"
  run resolve "$near" source
  [ "$status" -eq 0 ]
  [ "$output" = "search" ]
  # No registry exists above $BATS_TEST_TMPDIR in a test run, so the capped search falls to default.
  run resolve "$far" source
  [ "$status" -eq 0 ]
  [ "$output" = "default" ]
}

# --- default layer -------------------------------------------------------------------------------

@test "no registry anywhere: default layer returns PWD, conventional paths, and creates nothing" {
  local anchor
  anchor=$(anchor_of "$EMPTY")
  run resolve "$EMPTY" root
  [ "$status" -eq 0 ]
  [ "$output" = "$anchor" ]
  run resolve "$EMPTY" source
  [ "$output" = "default" ]
  run resolve "$EMPTY" tree
  [ "$output" = "project" ]
  run resolve "$EMPTY" get queue
  [ "$status" -eq 0 ]
  [ "$output" = "$anchor/project/queue" ]
  run resolve "$EMPTY" list
  [ "${#lines[@]}" -eq 18 ]
  [ -z "$(ls -A "$EMPTY")" ]
}

@test "--strict exits 3 when only the default layer is available, for root, get and list" {
  run resolve "$EMPTY" --strict root
  [ "$status" -eq 3 ]
  assert_output_contains "JENGA_PROJECT_ROOT"
  run resolve "$EMPTY" --strict get board
  [ "$status" -eq 3 ]
  run resolve "$EMPTY" get board --strict
  [ "$status" -eq 3 ]
  run resolve "$EMPTY" --strict list
  [ "$status" -eq 3 ]
}

@test "--strict still succeeds when a registry is found" {
  make_tree "$CONV" project
  run resolve "$CONV/sub" --strict root
  [ "$status" -eq 0 ]
  [ "$output" = "$(anchor_of "$CONV")" ]
  run resolve "$CONV/sub" --strict get queue --relative
  [ "$status" -eq 0 ]
  [ "$output" = "project/queue" ]
}

# --- per-key behaviour ---------------------------------------------------------------------------

@test "a partial registry falls back to defaults for absent keys and list still prints 18 lines" {
  write_registry "$CONV" project '{"paths": {"queue": "project/custom-queue"}}'
  run resolve "$CONV" get queue --relative
  [ "$output" = "project/custom-queue" ]
  run resolve "$CONV" get board --relative
  [ "$status" -eq 0 ]
  [ "$output" = "project/board" ]
  run resolve "$CONV" list
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 18 ]
}

@test "a registry with no paths object falls back to defaults" {
  write_registry "$CONV" project '{"version": 1}'
  run resolve "$CONV" get board --relative
  [ "$status" -eq 0 ]
  [ "$output" = "project/board" ]
}

@test "session_handoff has no trailing slash even though the registry stores one" {
  make_tree "$CONV" project
  grep -q 'handoffs/"' "$CONV/project/configs/workflow.json"
  run resolve "$CONV" get session_handoff --relative
  [ "$output" = "project/queue/handoffs" ]
  run resolve "$CONV" get session_handoff
  assert_output_not_contains "handoffs/"
  [ "${output%handoffs}" != "$output" ]
}

@test "unknown key exits 2 and lists the valid keys" {
  make_tree "$CONV" project
  run resolve "$CONV" get nonsense
  [ "$status" -eq 2 ]
  assert_output_contains "unknown key"
  assert_output_contains "session_handoff"
  assert_output_contains "strategy"
}

@test "missing key argument, unknown option and no subcommand exit 2" {
  make_tree "$CONV" project
  run resolve "$CONV" get
  [ "$status" -eq 2 ]
  run resolve "$CONV" --bogus root
  [ "$status" -eq 2 ]
  run resolve "$CONV"
  [ "$status" -eq 2 ]
  run resolve "$CONV" nonsense
  [ "$status" -eq 2 ]
}

# --- failure paths and no-jq ---------------------------------------------------------------------

@test "malformed JSON exits 1 with the contract message (jq path)" {
  mkdir -p "$CONV/project/configs"
  printf 'not json\n' > "$CONV/project/configs/workflow.json"
  run resolve "$CONV" get queue
  [ "$status" -eq 1 ]
  assert_output_contains "Error: project/configs/workflow.json contains malformed JSON"
  run resolve "$CONV" list
  [ "$status" -eq 1 ]
}

@test "malformed JSON exits 1 with jq removed from PATH" {
  mkdir -p "$CONV/project/configs"
  printf 'not json\n' > "$CONV/project/configs/workflow.json"
  run resolve_nojq "$CONV" get queue
  [ "$status" -eq 1 ]
  assert_output_contains "contains malformed JSON"
  run resolve_nojq "$CONV" list
  [ "$status" -eq 1 ]
}

@test "no-jq run: PATH really has no jq, and list matches the jq run for conventional and relocated trees" {
  make_tree "$CONV" project
  make_tree "$REL" .project
  local bin
  bin=$(nojq_path)
  run bash -c 'PATH="$1"; command -v jq' _ "$bin"
  [ "$status" -ne 0 ]
  local with_jq without_jq
  for d in "$CONV/sub" "$REL/sub"; do
    run resolve "$d" list
    [ "$status" -eq 0 ]
    with_jq="$output"
    run resolve_nojq "$d" list
    [ "$status" -eq 0 ]
    without_jq="$output"
    [ "$with_jq" = "$without_jq" ]
    [ "${#lines[@]}" -eq 18 ]
  done
}

@test "no-jq run ignores a same-named key outside the paths object" {
  # The fixture carries "other": {"queue": "wrong", "data": "wrong"} ahead of "paths".
  make_tree "$CONV" project
  run resolve_nojq "$CONV" get queue --relative
  [ "$status" -eq 0 ]
  [ "$output" = "project/queue" ]
  run resolve_nojq "$CONV" get data --relative
  [ "$output" = "project/data" ]
}

# --- consistency guard ---------------------------------------------------------------------------

# The key sets (and conventional values) in the script's defaults, the schema doc's "Working-File
# Path Resolution" key table, and this repo's workflow.json must be one and the same.
@test "script defaults, schema doc key table and workflow.json carry the same 18 keys" {
  local script_pairs doc_pairs
  script_pairs=$(cd "$EMPTY" && bash "$RESOLVER" list --relative)
  doc_pairs=$(awk '/^## Working-File Path Resolution/{f=1;next} /^## /{f=0} f' "$SCHEMA_DOC" \
    | grep -E '^\| `[a-z_]+` \| `' \
    | sed -E 's/^\| `([a-z_]+)` \| `([^`]*)` \|.*/\1=\2/')
  [ "$(printf '%s\n' "$script_pairs" | wc -l | tr -d ' ')" -eq 18 ]
  [ "$(printf '%s\n' "$doc_pairs" | wc -l | tr -d ' ')" -eq 18 ]
  [ "$script_pairs" = "$doc_pairs" ]
  # The test's own fixture table agrees too.
  local fixture_pairs
  fixture_pairs=$(printf '%s\n' "$DEFAULTS" | sed 's/|/=/')
  [ "$script_pairs" = "$fixture_pairs" ]
}

@test "workflow.json paths keys match the script's keys (skipped when the registry is absent)" {
  if [ ! -f "$REPO_ROOT/project/configs/workflow.json" ]; then
    skip "SKIPPED (no coverage): project/configs/workflow.json is absent from this tree"
  fi
  if ! command -v jq >/dev/null 2>&1; then
    skip "SKIPPED (no coverage): jq is not installed"
  fi
  local script_keys registry_keys
  script_keys=$(cd "$EMPTY" && bash "$RESOLVER" list --relative | sed 's/=.*//' | sort)
  registry_keys=$(jq -r '.paths | keys[]' "$REPO_ROOT/project/configs/workflow.json" | sort)
  [ "$script_keys" = "$registry_keys" ]
}

# --- sourced use ---------------------------------------------------------------------------------

@test "sourcing prints nothing, exits cleanly and creates nothing, under set -u" {
  cd "$EMPTY"
  run bash -uc '. "$1"' _ "$RESOLVER"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ -z "$(ls -A "$EMPTY")" ]
}

@test "sourced: jenga_resolve_path, jenga_resolve_root and jenga_resolve_list work" {
  make_tree "$CONV" project
  local anchor
  anchor=$(anchor_of "$CONV")
  cd "$CONV/sub"
  run bash -uc '. "$1"; jenga_resolve_path queue' _ "$RESOLVER"
  [ "$status" -eq 0 ]
  [ "$output" = "$anchor/project/queue" ]
  run bash -uc '. "$1"; jenga_resolve_path queue --relative' _ "$RESOLVER"
  [ "$output" = "project/queue" ]
  run bash -uc '. "$1"; jenga_resolve_root' _ "$RESOLVER"
  [ "$output" = "$anchor" ]
  run bash -uc '. "$1"; jenga_resolve_list' _ "$RESOLVER"
  [ "${#lines[@]}" -eq 18 ]
}

@test "sourced: an unresolvable call returns non-zero without killing the caller" {
  cd "$EMPTY"
  run bash -uc '. "$1"; jenga_resolve_root --strict; echo "caller alive rc=$?"' _ "$RESOLVER"
  [ "$status" -eq 0 ]
  assert_output_contains "caller alive rc=3"
}
