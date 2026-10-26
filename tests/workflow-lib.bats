#!/usr/bin/env bats
#
# E80_S01_T02: scripts/workflow/lib.sh is the shared location resolver for the workflow tools (package root,
# schema, types, built-in workflow directory, project-local workflow directory).
#
# Every case that needs a layout builds its own throwaway tree under $BATS_TEST_TMPDIR, so nothing here reads this
# repository's board or any private path. The one exception is the "unset inside this repository" case, which
# resolves against the checkout the test runs in and only reads the package root path, never a board file.
#
# Mirror safety: depends only on scripts/workflow/lib.sh, scripts/resolve-root.sh and fixtures it builds. The
# working-file tree names in the fixtures are registry-layout directory names, written into scratch trees only.

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
LIB="$REPO_ROOT/scripts/workflow/lib.sh"
RESOLVER="$REPO_ROOT/scripts/resolve-root.sh"

setup() {
  unset JENGA_WORKFLOWS_TEST_ROOT JENGA_PROJECT_ROOT
  TREE_A="project"
  TREE_B=".project"
}

# Builds a fixture working-file tree $1/$2 (registry present) so resolve-root.sh finds it.
make_tree() {
  mkdir -p "$1/$2/configs"
  printf '{"paths":{}}\n' > "$1/$2/configs/workflow.json"
}

# Builds a consumer layout under $1: the scripts copied in without any templates/ next to them.
make_consumer() {
  mkdir -p "$1/scripts/workflow"
  cp "$LIB" "$1/scripts/workflow/lib.sh"
  cp "$RESOLVER" "$1/scripts/resolve-root.sh"
}

# Runs function $2 from the lib at $1 in a fresh bash with set -u; cwd is $3 (default: current).
run_fn() {
  local lib="$1" fn="$2" cwd="${3:-$PWD}"
  run bash -c 'set -u; cd "$3" && . "$1" && "$2"' _ "$lib" "$fn" "$cwd"
}

# --- AC1: exists, syntax, silent, creates nothing, documented ------------------------------------

@test "lib.sh exists and passes bash -n" {
  [ -f "$LIB" ]
  run bash -n "$LIB"
  [ "$status" -eq 0 ]
}

@test "sourcing lib.sh prints nothing, exits nothing and creates nothing (set -u)" {
  local box="$BATS_TEST_TMPDIR/box"
  make_consumer "$box"
  make_tree "$box" project
  local before after
  before="$(cd "$box" && find . | LC_ALL=C sort)"
  run bash -c 'set -u; cd "$1" && . "$1/scripts/workflow/lib.sh"; echo still-here' _ "$box"
  [ "$status" -eq 0 ]
  [ "$output" = "still-here" ]
  after="$(cd "$box" && find . | LC_ALL=C sort)"
  [ "$before" = "$after" ]
}

@test "calling every function creates no file or directory" {
  local box="$BATS_TEST_TMPDIR/box"
  make_consumer "$box"
  make_tree "$box" project
  mkdir -p "$box/node_modules/@jenga-ai/agent/templates"
  local before after fn
  before="$(cd "$box" && find . | LC_ALL=C sort)"
  for fn in workflow_pkg_root workflow_schema_path workflow_types_path workflow_builtin_dir workflow_project_dir; do
    run_fn "$box/scripts/workflow/lib.sh" "$fn" "$box"
    [ "$status" -eq 0 ]
  done
  after="$(cd "$box" && find . | LC_ALL=C sort)"
  [ "$before" = "$after" ]
}

@test "header documents each function and the test-override variable" {
  local name
  for name in workflow_pkg_root workflow_schema_path workflow_types_path workflow_builtin_dir workflow_project_dir JENGA_WORKFLOWS_TEST_ROOT; do
    run grep -c "^#.*$name" "$LIB"
    [ "$status" -eq 0 ]
    [ "$output" -ge 1 ]
  done
}

# --- AC2: test override and in-repo default ------------------------------------------------------

@test "with JENGA_WORKFLOWS_TEST_ROOT set every resolved path is under that root" {
  local root="$BATS_TEST_TMPDIR/fixture"
  make_tree "$root" project
  export JENGA_WORKFLOWS_TEST_ROOT="$root"
  local fn
  for fn in workflow_pkg_root workflow_schema_path workflow_types_path workflow_builtin_dir workflow_project_dir; do
    run_fn "$LIB" "$fn" "$BATS_TEST_TMPDIR"
    [ "$status" -eq 0 ]
    case "$output" in "$root"/*|"$root") ;; *) echo "$fn escaped the root: $output"; false ;; esac
  done
  run_fn "$LIB" workflow_pkg_root "$BATS_TEST_TMPDIR"
  [ "$output" = "$root" ]
  run_fn "$LIB" workflow_schema_path "$BATS_TEST_TMPDIR"
  [ "$output" = "$root/templates/workflow-schema.json" ]
  run_fn "$LIB" workflow_types_path "$BATS_TEST_TMPDIR"
  [ "$output" = "$root/templates/playbook-types.json" ]
  run_fn "$LIB" workflow_builtin_dir "$BATS_TEST_TMPDIR"
  [ "$output" = "$root/templates/workflows" ]
  run_fn "$LIB" workflow_project_dir "$BATS_TEST_TMPDIR"
  [ "$output" = "$root/project/.workflows" ]
}

@test "the override wins even when the working directory is a different project" {
  local root="$BATS_TEST_TMPDIR/fixture" other="$BATS_TEST_TMPDIR/other"
  make_tree "$root" project
  make_tree "$other" project
  mkdir -p "$other/templates"
  export JENGA_WORKFLOWS_TEST_ROOT="$root"
  run_fn "$LIB" workflow_project_dir "$other"
  [ "$status" -eq 0 ]
  [ "$output" = "$root/project/.workflows" ]
}

@test "the override ignores JENGA_PROJECT_ROOT when reading the tree name" {
  local root="$BATS_TEST_TMPDIR/fixture" other="$BATS_TEST_TMPDIR/other"
  make_tree "$root" .project
  make_tree "$other" project
  export JENGA_WORKFLOWS_TEST_ROOT="$root" JENGA_PROJECT_ROOT="$other"
  run_fn "$LIB" workflow_project_dir "$BATS_TEST_TMPDIR"
  [ "$status" -eq 0 ]
  [ "$output" = "$root/.project/.workflows" ]
}

@test "unset inside this repository the package paths are under the repository's own templates" {
  run_fn "$LIB" workflow_pkg_root "$REPO_ROOT"
  [ "$status" -eq 0 ]
  [ "$output" = "$REPO_ROOT" ]
  run_fn "$LIB" workflow_schema_path "$REPO_ROOT"
  [ "$output" = "$REPO_ROOT/templates/workflow-schema.json" ]
  run_fn "$LIB" workflow_types_path "$REPO_ROOT"
  [ "$output" = "$REPO_ROOT/templates/playbook-types.json" ]
  run_fn "$LIB" workflow_builtin_dir "$REPO_ROOT"
  [ "$output" = "$REPO_ROOT/templates/workflows" ]
}

@test "a checkout with templates/ beside the scripts resolves to that checkout, not to node_modules" {
  local box="$BATS_TEST_TMPDIR/checkout"
  make_consumer "$box"
  mkdir -p "$box/templates" "$box/node_modules/@jenga-ai/agent/templates"
  run_fn "$box/scripts/workflow/lib.sh" workflow_pkg_root "$box"
  [ "$status" -eq 0 ]
  [ "$output" = "$(cd "$box" && pwd)" ]
}

# --- AC3: consumer install fallback ---------------------------------------------------------------

@test "consumer layout with no templates/ resolves the node_modules copy" {
  local box="$BATS_TEST_TMPDIR/consumer"
  make_consumer "$box"
  make_tree "$box" project
  mkdir -p "$box/node_modules/@jenga-ai/agent/templates"
  run_fn "$box/scripts/workflow/lib.sh" workflow_pkg_root "$box"
  [ "$status" -eq 0 ]
  [ "$output" = "$box/node_modules/@jenga-ai/agent" ]
  run_fn "$box/scripts/workflow/lib.sh" workflow_schema_path "$box"
  [ "$output" = "$box/node_modules/@jenga-ai/agent/templates/workflow-schema.json" ]
  run_fn "$box/scripts/workflow/lib.sh" workflow_builtin_dir "$box"
  [ "$output" = "$box/node_modules/@jenga-ai/agent/templates/workflows" ]
}

@test "the node_modules fallback is found from a subdirectory of the project" {
  local box="$BATS_TEST_TMPDIR/consumer"
  make_consumer "$box"
  make_tree "$box" project
  mkdir -p "$box/node_modules/@jenga-ai/agent/templates" "$box/deep/er"
  run_fn "$box/scripts/workflow/lib.sh" workflow_pkg_root "$box/deep/er"
  [ "$status" -eq 0 ]
  [ "$output" = "$box/node_modules/@jenga-ai/agent" ]
}

# --- AC4: nothing found -----------------------------------------------------------------------------

@test "with neither templates/ nor the node_modules copy, workflow_pkg_root fails naming what was searched" {
  local box="$BATS_TEST_TMPDIR/empty"
  make_consumer "$box"
  make_tree "$box" project
  run bash -c 'set -u; cd "$2" && . "$1" && workflow_pkg_root 2>"$3"; echo "rc=$?"' _ "$box/scripts/workflow/lib.sh" "$box" "$BATS_TEST_TMPDIR/err"
  [ "$status" -eq 0 ]
  [ "$output" = "rc=1" ]
  run cat "$BATS_TEST_TMPDIR/err"
  [[ "$output" == *"templates"* ]]
  [[ "$output" == *"$box/scripts/workflow/../../templates"* ]]
  [[ "$output" == *"$box/node_modules/@jenga-ai/agent/templates"* ]]
}

@test "the path functions propagate the package-root failure and print nothing on stdout" {
  local box="$BATS_TEST_TMPDIR/empty" fn
  make_consumer "$box"
  make_tree "$box" project
  for fn in workflow_schema_path workflow_types_path workflow_builtin_dir; do
    run bash -c 'set -u; cd "$2" && . "$1" && out=$("$3" 2>/dev/null); rc=$?; echo "rc=$rc out=[$out]"' _ "$box/scripts/workflow/lib.sh" "$box" "$fn"
    [ "$output" = "rc=1 out=[]" ]
  done
}

# --- AC5: project dir derives from resolve-root.sh -----------------------------------------------

@test "workflow_project_dir is .workflows under the conventional tree" {
  local box="$BATS_TEST_TMPDIR/proj"
  make_consumer "$box"
  make_tree "$box" project
  run_fn "$box/scripts/workflow/lib.sh" workflow_project_dir "$box"
  [ "$status" -eq 0 ]
  [ "$output" = "$box/project/.workflows" ]
}

@test "workflow_project_dir follows the dot-prefixed tree variant" {
  local box="$BATS_TEST_TMPDIR/proj"
  make_consumer "$box"
  make_tree "$box" .project
  run_fn "$box/scripts/workflow/lib.sh" workflow_project_dir "$box"
  [ "$status" -eq 0 ]
  [ "$output" = "$box/.project/.workflows" ]
}

@test "workflow_project_dir honours JENGA_PROJECT_ROOT through resolve-root.sh" {
  local box="$BATS_TEST_TMPDIR/proj" elsewhere="$BATS_TEST_TMPDIR/elsewhere"
  make_consumer "$box"
  make_tree "$box" .project
  mkdir -p "$elsewhere"
  export JENGA_PROJECT_ROOT="$box"
  run_fn "$box/scripts/workflow/lib.sh" workflow_project_dir "$elsewhere"
  [ "$status" -eq 0 ]
  [ "$output" = "$box/.project/.workflows" ]
}

@test "workflow_project_dir surfaces resolve-root.sh's failure when the anchor cannot be resolved" {
  local box="$BATS_TEST_TMPDIR/proj"
  make_consumer "$box"
  make_tree "$box" project
  export JENGA_PROJECT_ROOT="$BATS_TEST_TMPDIR/does-not-exist"
  run bash -c 'set -u; cd "$2" && . "$1" && workflow_project_dir 2>"$3"; echo "rc=$?"' _ "$box/scripts/workflow/lib.sh" "$box" "$BATS_TEST_TMPDIR/err"
  [ "$output" = "rc=3" ]
  run cat "$BATS_TEST_TMPDIR/err"
  [[ "$output" == *"JENGA_PROJECT_ROOT"* ]]
}

@test "lib.sh delegates to resolve-root.sh and contains no working-file tree literal" {
  run grep -n 'resolve-root.sh' "$LIB"
  [ "$status" -eq 0 ]
  run grep -n 'project/' "$LIB"
  [ "$status" -eq 1 ]
  [ -z "$output" ]
}
