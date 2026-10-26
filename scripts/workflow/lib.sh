#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# scripts/workflow/lib.sh - shared location resolution for the workflow tools (epic E80, task E80_S01_T02)
#
# One place that answers "where does the workflow schema live, where are the built-in workflows, where do a
# project's own workflows go". validate-workflow.sh and load-workflows.sh source this file instead of
# resolving locations themselves, so no workflow script hardcodes a working-file tree name.
#
# Sourcing this file prints nothing, exits nothing and creates nothing. It only defines functions (and two
# variables prefixed _WORKFLOW_). Compatible with macOS bash 3.2 and safe under `set -u`. No function here
# creates a file or directory. Every function prints one absolute path on stdout and nothing else; on failure
# it prints nothing on stdout, a message on stderr, and returns non-zero.
#
# ---------------------------------------------------------------------------
# FUNCTIONS
# ---------------------------------------------------------------------------
#   workflow_pkg_root
#       The package root, the directory that holds templates/. Order, first match wins:
#         1. JENGA_WORKFLOWS_TEST_ROOT, when set and non-empty (test override, see below). Taken as given;
#            the directory is not required to hold templates/.
#         2. The checkout this file lives in: <this file's directory>/../.. when it holds templates/. This is
#            the monorepo checkout and also a package installed whole.
#         3. Consumer install (E46 fallback): <project anchor>/node_modules/@jenga-ai/agent when that holds
#            templates/. The project anchor comes from scripts/resolve-root.sh.
#         4. None found: nothing on stdout, a message naming every location searched on stderr, returns 1.
#       A failure to resolve the project anchor in step 3 returns resolve-root.sh's own status (3).
#
#   workflow_schema_path     <package root>/templates/workflow-schema.json
#   workflow_types_path      <package root>/templates/playbook-types.json
#   workflow_builtin_dir     <package root>/templates/workflows
#       Each returns workflow_pkg_root's status when the package root cannot be resolved. None of them checks
#       that the resulting file or directory exists; the caller decides what a missing one means.
#
#   workflow_consumer_pkg_dir <anchor>
#       The consumer-install package directory under project anchor <anchor>, whether or not it exists. Pure
#       string building (no filesystem access, no resolve-root.sh call). It is the single place other workflow
#       scripts take that location from, so none of them names it; returns 2 with a message on stderr when
#       <anchor> is missing or empty.
#
#   workflow_project_dir
#       The project-local workflow directory: ".workflows" inside the working-file tree. The anchor and the
#       tree name (the conventional tree or the dot-prefixed variant) are both read from scripts/resolve-root.sh
#       (its `root` and `tree` subcommands); nothing here names the conventional tree. Returns the path whether
#       or not it exists. Returns resolve-root.sh's status (3) with its message on stderr when the anchor
#       cannot be resolved.
#         Under JENGA_WORKFLOWS_TEST_ROOT the anchor is that directory and the tree name is read by running
#         resolve-root.sh from there with JENGA_PROJECT_ROOT cleared, so the answer is
#         $JENGA_WORKFLOWS_TEST_ROOT/<tree>/.workflows and depends on nothing outside the fixture.
#
# ---------------------------------------------------------------------------
# TEST OVERRIDE
# ---------------------------------------------------------------------------
#   JENGA_WORKFLOWS_TEST_ROOT   When set and non-empty, every path above resolves under that directory, so a
#                               test can point the workflow tools at a synthetic tree under $BATS_TEST_TMPDIR
#                               instead of this repository. It mirrors JENGA_PLAYBOOKS_TEST_ROOT in
#                               skills/jenga/scripts/load-playbooks.sh. Never set it in a real invocation.
# ---------------------------------------------------------------------------

_WORKFLOW_LIB_DIR="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
_WORKFLOW_RESOLVE_ROOT="$_WORKFLOW_LIB_DIR/../resolve-root.sh"

_workflow_err() {
  printf '%s\n' "$*" >&2
}

# Prints $1 without trailing slashes (a lone "/" is kept).
_workflow_trim() {
  local v="$1"
  while [ "$v" != "/" ] && [ "${v%/}" != "$v" ]; do
    v="${v%/}"
  done
  printf '%s' "$v"
}

# Runs resolve-root.sh with subcommand $1 (root|tree) in the caller's environment; prints its stdout.
_workflow_resolve() {
  if [ ! -f "$_WORKFLOW_RESOLVE_ROOT" ]; then
    _workflow_err "Error: cannot resolve the working-file location; $_WORKFLOW_RESOLVE_ROOT is missing"
    return 3
  fi
  bash "$_WORKFLOW_RESOLVE_ROOT" "$1"
}

workflow_pkg_root() {
  local anchor candidate

  if [ -n "${JENGA_WORKFLOWS_TEST_ROOT:-}" ]; then
    _workflow_trim "$JENGA_WORKFLOWS_TEST_ROOT"
    printf '\n'
    return 0
  fi

  candidate="$_WORKFLOW_LIB_DIR/../.."
  if [ -d "$candidate/templates" ]; then
    candidate="$(CDPATH='' cd -- "$candidate" >/dev/null 2>&1 && pwd)"
    printf '%s\n' "$candidate"
    return 0
  fi

  anchor="$(_workflow_resolve root)" || return $?
  anchor="$(_workflow_trim "$anchor")"
  if [ -d "$anchor/node_modules/@jenga-ai/agent/templates" ]; then
    printf '%s\n' "$anchor/node_modules/@jenga-ai/agent"
    return 0
  fi

  _workflow_err "Error: could not locate the jenga-agent package root (templates/ not found). Searched: $_WORKFLOW_LIB_DIR/../../templates and $anchor/node_modules/@jenga-ai/agent/templates"
  return 1
}

workflow_consumer_pkg_dir() {
  if [ -z "${1:-}" ]; then
    _workflow_err "Error: workflow_consumer_pkg_dir needs the project anchor as its argument"
    return 2
  fi
  printf '%s\n' "$(_workflow_trim "$1")/node_modules/@jenga-ai/agent"
}

workflow_schema_path() {
  local root
  root="$(workflow_pkg_root)" || return $?
  printf '%s\n' "$root/templates/workflow-schema.json"
}

workflow_types_path() {
  local root
  root="$(workflow_pkg_root)" || return $?
  printf '%s\n' "$root/templates/playbook-types.json"
}

workflow_builtin_dir() {
  local root
  root="$(workflow_pkg_root)" || return $?
  printf '%s\n' "$root/templates/workflows"
}

workflow_project_dir() {
  local anchor tree

  if [ -n "${JENGA_WORKFLOWS_TEST_ROOT:-}" ]; then
    anchor="$(_workflow_trim "$JENGA_WORKFLOWS_TEST_ROOT")"
    tree="$(cd "$anchor" 2>/dev/null && env -u JENGA_PROJECT_ROOT bash "$_WORKFLOW_RESOLVE_ROOT" tree)" || {
      _workflow_err "Error: cannot resolve the working-file tree under JENGA_WORKFLOWS_TEST_ROOT=$anchor"
      return 3
    }
  else
    anchor="$(_workflow_resolve root)" || return $?
    anchor="$(_workflow_trim "$anchor")"
    tree="$(_workflow_resolve tree)" || return $?
  fi
  printf '%s\n' "$anchor/$tree/.workflows"
}
