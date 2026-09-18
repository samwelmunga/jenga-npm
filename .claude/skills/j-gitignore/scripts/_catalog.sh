#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# skills/j-gitignore/scripts/_catalog.sh
#
# Shared helpers for the j-gitignore scripts. Sourced, never run directly:
#
#   source "$(dirname "${BASH_SOURCE[0]}")/_catalog.sh"
#
# Provides:
#   CATALOG_FILE            absolute path to assets/jenga-paths.txt
#   MANAGED_BEGIN/_END      the managed-block markers
#   load_catalog <tiers>    populates CATALOG_PATHS/_TIERS/_DESCS arrays
#   validate_tiers <csv>    rejects an unknown tier name
#   resolve_root <dir>      cd's to a project root, verifying it is a git repo
#
# The leading underscore marks this as internal to the skill — it is not an
# entry point and takes no arguments of its own.
# -----------------------------------------------------------------------------

# Deliberately no `set -e` — callers handle their own errors, matching the
# convention in skills/j-init/scripts/apply-scaffold-visibility.sh.
set -uo pipefail

_CATALOG_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CATALOG_FILE="${_CATALOG_LIB_DIR}/../assets/jenga-paths.txt"

MANAGED_BEGIN="# >>> jenga:gitignore >>>"
MANAGED_END="# <<< jenga:gitignore <<<"

VALID_TIERS="scaffold hybrid board optional"

# Populated by load_catalog.
CATALOG_PATHS=()
CATALOG_TIERS=()
CATALOG_DESCS=()

validate_tiers() {
  local csv="$1" tier valid found
  [ -n "$csv" ] || { echo "ERROR: --tiers was given an empty value." >&2; return 2; }
  # Split on commas into an array FIRST, then restore IFS. Setting IFS=',' for
  # the duration of both loops would stop the space-separated $VALID_TIERS from
  # splitting, making every tier look invalid.
  local -a requested=()
  local old_ifs="$IFS"
  IFS=','; read -r -a requested <<< "$csv"; IFS="$old_ifs"
  for tier in "${requested[@]}"; do
    found=0
    for valid in $VALID_TIERS; do
      [ "$tier" = "$valid" ] && found=1 && break
    done
    if [ "$found" -eq 0 ]; then
      echo "ERROR: Unknown tier '${tier}'. Valid tiers: ${VALID_TIERS// /, }" >&2
      return 2
    fi
  done
  return 0
}

# load_catalog <comma-separated-tiers>
# Reads CATALOG_FILE, keeping only rows whose tier is in the requested set.
load_catalog() {
  local want="$1"
  CATALOG_PATHS=(); CATALOG_TIERS=(); CATALOG_DESCS=()

  if [ ! -f "$CATALOG_FILE" ]; then
    echo "ERROR: Path catalog not found: $CATALOG_FILE" >&2
    return 1
  fi

  local tier path desc
  while IFS=$'\t' read -r tier path desc || [ -n "${tier:-}" ]; do
    [ -z "${tier// /}" ] && continue
    case "$tier" in \#*) continue ;; esac
    [ -n "${path:-}" ] || continue
    case ",${want}," in
      *",${tier},"*)
        CATALOG_PATHS+=("$path")
        CATALOG_TIERS+=("$tier")
        CATALOG_DESCS+=("${desc:-}")
        ;;
    esac
  done < "$CATALOG_FILE"

  if [ "${#CATALOG_PATHS[@]}" -eq 0 ]; then
    echo "ERROR: No catalog entries matched tiers '${want}'." >&2
    return 1
  fi
  return 0
}

# resolve_root <dir> — cd into it and confirm it is the root of a git work tree.
resolve_root() {
  local root="$1"
  if [ ! -d "$root" ]; then
    echo "ERROR: Project root does not exist: $root" >&2
    return 1
  fi
  cd "$root" || { echo "ERROR: Cannot enter project root: $root" >&2; return 1; }
  if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    echo "ERROR: Not a git repository: $root" >&2
    echo "       This skill repairs a project's tracked/ignored state, so it needs git." >&2
    return 1
  fi
  return 0
}
