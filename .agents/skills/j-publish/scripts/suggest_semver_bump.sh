#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/publish_common.sh"

usage() {
  cat <<'USAGE'
Usage: suggest_semver_bump.sh [--current-version <vX.Y.Z>] [--yes] [<publish_json_path>]
USAGE
}

CURRENT_VERSION=""
AUTO_ACCEPT=0
CONFIG_PATH=""
POSITIONAL_COUNT=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --current-version)
      [[ $# -ge 2 ]] || { usage >&2; exit 1; }
      CURRENT_VERSION="$2"
      shift 2
      ;;
    --yes)
      AUTO_ACCEPT=1
      shift
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    --*)
      usage >&2
      exit 1
      ;;
    *)
      POSITIONAL_COUNT=$((POSITIONAL_COUNT + 1))
      if (( POSITIONAL_COUNT > 1 )); then
        usage >&2
        exit 1
      fi
      CONFIG_PATH="$1"
      shift
      ;;
  esac
done

HISTORY_FILE="$(publish_resolve_history_file "$CONFIG_PATH")"
if [[ -z "$CURRENT_VERSION" ]]; then
  CURRENT_VERSION="$(publish_latest_ledger_version "$HISTORY_FILE" 2>/dev/null || true)"
fi
[[ -n "$CURRENT_VERSION" ]] || CURRENT_VERSION='v0.0.0'
CURRENT_VERSION="$(publish_normalize_version "$CURRENT_VERSION")" || {
  echo "Invalid current version: $CURRENT_VERSION" >&2
  exit 1
}

LAST_TAG="$(publish_resolve_last_publish_tag "$HISTORY_FILE" HEAD 2>/dev/null || true)"
if [[ -n "$LAST_TAG" ]]; then
  RANGE=("$LAST_TAG..HEAD")
else
  RANGE=(HEAD)
fi

LOG_CONTENT="$(git log "${RANGE[@]}" --format='%s%n%b<<__COMMIT_BOUNDARY__>>' 2>/dev/null || true)"
BUMP_LEVEL='patch'
if printf '%s\n' "$LOG_CONTENT" | grep -Eq 'BREAKING CHANGE|^[^[:space:]]+(\([^)]+\))?!:'; then
  BUMP_LEVEL='major'
elif printf '%s\n' "$LOG_CONTENT" | grep -Eq '^feat(\([^)]+\))?(!)?: '; then
  BUMP_LEVEL='minor'
fi

NEW_VERSION="$(publish_bump_version "$CURRENT_VERSION" "$BUMP_LEVEL")"
printf 'Suggested version bump: %s → %s\n' "$BUMP_LEVEL" "$NEW_VERSION"

SELECTED_VERSION="$NEW_VERSION"
if (( AUTO_ACCEPT )); then
  :
elif [[ -t 0 ]]; then
  read -r -p "Use this version? [Y/n]: " response
  response="${response:-Y}"
  case "$response" in
    Y|y|yes|YES)
      :
      ;;
    N|n|no|NO)
      read -r -p "Enter version (vX.Y.Z), or press Enter to abort: " manual_version
      [[ -n "$manual_version" ]] || exit 1
      SELECTED_VERSION="$(publish_normalize_version "$manual_version")" || {
        echo "Invalid version: $manual_version" >&2
        exit 1
      }
      ;;
    *)
      echo 'Unrecognized response.' >&2
      exit 1
      ;;
  esac
else
  echo 'Non-interactive use requires --yes.' >&2
  exit 1
fi

printf '%s\n' "$SELECTED_VERSION"
