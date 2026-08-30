#!/usr/bin/env bash
#
# apply-project-visibility.sh — apply the `project_files_visibility` mode to a project.
#
# Usage:
#   apply-project-visibility.sh <mode> [project_root]
#   apply-project-visibility.sh --check-only <mode>
#
# Modes:
#   visible   Working files stay where they are. No-op on disk beyond the config write.
#   ignored   Working files are added to the project's .gitignore — present on disk,
#             never committed.
#
# NOTE: A third mode, `hidden` (dot-prefixing project/ -> .project/), was
# implemented and then withdrawn before release. Testing found it functionally
# broken: scripts/board_resolver.sh hardcodes project/configs/workflow.json
# and never locates the rewritten path, and hooks/on_session_end.sh
# unconditionally recreates a shadow project/ tree on every session end,
# splitting runtime state across two trees. See
# project/rapports/problems/E31_S05_T01-hidden-mode-path-resolution-gaps.md
# for the full findings. Re-introducing `hidden` requires fixing both of
# those hardcoded paths first — tracked as a follow-up /todo item.
#
# Exit codes:
#   0  Success
#   1  Bad usage or missing prerequisite
#   2  Invalid mode (outside the two-value enum)
#   3  Filesystem apply failure
#   4  jenga.config.json write failure

# Do NOT use set -e globally — each step handles its own errors.
set -uo pipefail

info() { echo "[visibility] $*"; }
warn() { echo "[visibility] WARNING: $*"; }
err()  { echo "[visibility] ERROR: $*" >&2; }

usage() {
  echo "Usage: $(basename "$0") <visible|ignored> [project_root]" >&2
  echo "       $(basename "$0") --check-only <visible|ignored>" >&2
  exit 1
}

# Every Jenga AI working file named in E31_S05 — the scrum board, todo.md,
# queue/, rapports/ and logs/ — nests under this single root, so one entry
# covers them all. `ignored` consumes this list.
JENGA_WORKING_PATHS=("project")

VALID_MODES="visible ignored"

validate_mode() {
  local mode="$1"
  for valid in $VALID_MODES; do
    [ "$mode" = "$valid" ] && return 0
  done
  err "Invalid project_files_visibility value: '${mode}'"
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

write_visibility_config() {
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
  content="$(jq --arg v "$mode" '.project_files_visibility = $v' <<< "$existing")"
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

  info "Wrote project_files_visibility = \"$mode\" to $config"
}

# ---------------------------------------------------------------------------
# Apply
# ---------------------------------------------------------------------------

case "$MODE" in
  visible)
    info "Mode 'visible' — working files stay in place; nothing to change on disk."
    ;;
  ignored)
    for path in "${JENGA_WORKING_PATHS[@]}"; do
      gitignore_append "${path}/"
    done
    ;;
esac

write_visibility_config "$MODE"

info "Applied project_files_visibility '$MODE' to $PROJECT_ROOT"
