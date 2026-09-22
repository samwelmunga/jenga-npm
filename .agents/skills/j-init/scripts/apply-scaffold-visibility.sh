#!/usr/bin/env bash
#
# apply-scaffold-visibility.sh — apply the `scaffold_visibility` mode to a project.
#
# This is a DISTINCT flag from `project_files_visibility` (see
# apply-project-visibility.sh). `project_files_visibility` covers the
# project/ working tree (scrum board, todo.md, queue/, rapports/, logs/) —
# E31_S05's own Background section scopes it to that tree only. This script
# instead covers the *distributed framework scaffold* — `.claude/` and
# `.agents/` — which is a different tree with a different lifecycle (it is
# overwritten wholesale by every `/distribute` run or npm upgrade; project/
# is not). Filed as new, adjacent scope under E31_S07 rather than folded
# silently into project_files_visibility's existing enum. See
# skills/j-distribute/CONFIG_SCHEMA.md's "Scaffold visibility" section for the
# full rationale.
#
# This file is the sole copy. It was added by E31_S07_T03 as skills/j-init/'s own
# hand-maintained duplicate of a then-existing skills/init/scripts/ copy, with an
# instruction to keep the two in lockstep. That instruction is void: E50_S15_T04
# deleted every bare-name skills/<name>/ directory on 2026-09-19, making
# skills/j-<name>/ the sole canonical form (see docs/skill-authoring.md's "The
# Canonical Naming Contract"), and scripts/generate-j-alias.sh — which had excluded
# this pair from generation as hand-maintained — was itself retired by E50_S14_T01.
# There is no second copy to mirror a change into, and none should be created.
#
# Usage:
#   apply-scaffold-visibility.sh <mode> [project_root]
#   apply-scaffold-visibility.sh --check-only <mode>
#
# Modes:
#   visible   Scaffold directories stay where they are. No-op on disk beyond
#             the config write. This is the default — matches the behavior
#             of every /init run before this flag existed.
#   ignored   .claude/ and .agents/ are added to the project's .gitignore —
#             present on disk (whenever npm postinstall or /distribute
#             places them, whether that happens before or after this runs),
#             never committed. Entries are written unconditionally, the same
#             way apply-project-visibility.sh gitignores project/ whether or
#             not it exists yet, so a scaffold created by a later
#             /distribute run is covered too, not just one already on disk.
#
# Exit codes:
#   0  Success
#   1  Bad usage or missing prerequisite
#   2  Invalid mode (outside the two-value enum)
#   3  Filesystem apply failure
#   4  jenga.config.json write failure

# Do NOT use set -e globally — each step handles its own errors.
set -uo pipefail

info() { echo "[scaffold-visibility] $*"; }
warn() { echo "[scaffold-visibility] WARNING: $*"; }
err()  { echo "[scaffold-visibility] ERROR: $*" >&2; }

usage() {
  echo "Usage: $(basename "$0") <visible|ignored> [project_root]" >&2
  echo "       $(basename "$0") --check-only <visible|ignored>" >&2
  exit 1
}

# The distributed framework scaffold — mirrored copies of skills/agents for
# Claude Code and Copilot/other agents. Distinct from JENGA_WORKING_PATHS in
# apply-project-visibility.sh, which covers project/ only.
JENGA_SCAFFOLD_PATHS=(".claude" ".agents")

VALID_MODES="visible ignored"

validate_mode() {
  local mode="$1"
  for valid in $VALID_MODES; do
    [ "$mode" = "$valid" ] && return 0
  done
  err "Invalid scaffold_visibility value: '${mode}'"
  err "Allowed values are: ${VALID_MODES// /, }"
  exit 2
}

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------

CHECK_ONLY=0
if [ "${1:-}" = "--check-only" ]; then
  CHECK_ONLY=1
  shift
fi

MODE="${1:-}"
[ -n "$MODE" ] || usage

validate_mode "$MODE"

if [ "$CHECK_ONLY" -eq 1 ]; then
  info "Mode '$MODE' is valid."
  exit 0
fi

PROJECT_ROOT="${2:-$PWD}"
if [ ! -d "$PROJECT_ROOT" ]; then
  err "Project root does not exist: $PROJECT_ROOT"
  exit 1
fi
cd "$PROJECT_ROOT" || { err "Cannot enter project root: $PROJECT_ROOT"; exit 1; }

if ! command -v jq >/dev/null 2>&1; then
  err "jq is required to write jenga.config.json but was not found on PATH."
  exit 1
fi

# ---------------------------------------------------------------------------
# ignored — append to .gitignore, without ever duplicating an entry
# ---------------------------------------------------------------------------

gitignore_append() {
  local entry="$1"
  local gitignore=".gitignore"

  if [ -f "$gitignore" ] && grep -qxF -- "$entry" "$gitignore"; then
    info "'$entry' already present in .gitignore — skipping."
    return 0
  fi

  # Don't glue our entry onto a final line that lacks a newline.
  if [ -s "$gitignore" ] && [ -n "$(tail -c 1 "$gitignore")" ]; then
    printf '\n' >> "$gitignore"
  fi

  if ! printf '%s\n' "$entry" >> "$gitignore"; then
    err "Failed to append '$entry' to .gitignore"
    exit 3
  fi
  info "Added '$entry' to .gitignore"
}

# ---------------------------------------------------------------------------
# jenga.config.json — merge the field in, written atomically (temp + mv)
# ---------------------------------------------------------------------------

write_scaffold_config() {
  local mode="$1"
  local config="jenga.config.json"
  local tmp="${config}.tmp"
  local existing='{}'

  # /init normally runs before any /distribute, so the file usually does not
  # exist yet. Merge rather than overwrite so other fields survive.
  if [ -f "$config" ]; then
    if ! jq empty "$config" 2>/dev/null; then
      err "$config exists but contains malformed JSON — refusing to overwrite it."
      exit 4
    fi
    existing="$(cat "$config")"
  fi

  local content
  content="$(jq --arg v "$mode" '.scaffold_visibility = $v' <<< "$existing")"
  if [ -z "$content" ]; then
    err "Failed to construct $config content."
    exit 4
  fi

  if ! printf '%s\n' "$content" > "$tmp"; then
    err "Failed to write temporary config file: $tmp"
    exit 4
  fi

  if ! mv "$tmp" "$config"; then
    err "Failed to atomically move $tmp to $config"
    rm -f "$tmp"
    exit 4
  fi

  info "Wrote scaffold_visibility = \"$mode\" to $config"
}

# ---------------------------------------------------------------------------
# Apply
# ---------------------------------------------------------------------------

case "$MODE" in
  visible)
    info "Mode 'visible' — scaffold directories stay in place; nothing to change on disk."
    ;;
  ignored)
    for path in "${JENGA_SCAFFOLD_PATHS[@]}"; do
      gitignore_append "${path}/"
    done
    ;;
esac

write_scaffold_config "$MODE"

info "Applied scaffold_visibility '$MODE' to $PROJECT_ROOT"
