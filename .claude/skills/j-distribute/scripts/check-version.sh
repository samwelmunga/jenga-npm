#!/usr/bin/env bash
# check-version.sh <project_path>
#
# Compares the monorepo version (package.json) against the target project's
# jenga.config.json version field.
#
# Exit codes:
#   0 — target needs an update: jenga.config.json absent OR versions differ
#   1 — already up to date: versions match exactly
#   2 — invalid input: <project_path> missing or monorepo package.json missing

set -euo pipefail

# ---------------------------------------------------------------------------
# Resolve monorepo root from this script's own location (two levels up)
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MONOREPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

# ---------------------------------------------------------------------------
# Validate arguments
# ---------------------------------------------------------------------------
if [[ $# -ne 1 ]]; then
  echo "Usage: check-version.sh <project_path>" >&2
  exit 2
fi

PROJECT_PATH="$1"

# ---------------------------------------------------------------------------
# Validate paths
# ---------------------------------------------------------------------------
PACKAGE_JSON="${MONOREPO_ROOT}/package.json"

if [[ ! -d "$PROJECT_PATH" ]]; then
  echo "check-version: project path does not exist: ${PROJECT_PATH}" >&2
  exit 2
fi

if [[ ! -f "$PACKAGE_JSON" ]]; then
  echo "check-version: monorepo package.json not found at ${PACKAGE_JSON}" >&2
  exit 2
fi

# ---------------------------------------------------------------------------
# Read monorepo version
# ---------------------------------------------------------------------------
MONOREPO_VERSION="$(node -e "process.stdout.write(JSON.parse(require('fs').readFileSync('${PACKAGE_JSON}','utf8')).version || '')")"

if [[ -z "$MONOREPO_VERSION" ]]; then
  echo "check-version: could not read version from ${PACKAGE_JSON}" >&2
  exit 2
fi

# ---------------------------------------------------------------------------
# Read target version (absent jenga.config.json => needs update)
# ---------------------------------------------------------------------------
JENGA_CONFIG="${PROJECT_PATH}/jenga.config.json"

if [[ ! -f "$JENGA_CONFIG" ]]; then
  # No config file — target needs to be initialised
  exit 0
fi

TARGET_VERSION="$(node -e "process.stdout.write(JSON.parse(require('fs').readFileSync('${JENGA_CONFIG}','utf8')).version || '')")"

# ---------------------------------------------------------------------------
# Compare using exact string equality
# ---------------------------------------------------------------------------
if [[ "$MONOREPO_VERSION" == "$TARGET_VERSION" ]]; then
  exit 1  # Already up to date
else
  exit 0  # Needs update
fi
