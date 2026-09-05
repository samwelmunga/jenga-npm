#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/publish_common.sh"

usage() {
  cat <<'USAGE'
Usage: finalize_changelog.sh <version> [<changelog_path>]

Stamps the standing CHANGELOG.md's `## [Unreleased]` heading into a dated,
versioned heading (`## [<version>] — <date>`) and inserts a fresh, empty
`## [Unreleased]` section directly above it, matching
templates/CHANGELOG_TEMPLATE.md's subsection structure
(### Features / ### Bug Fixes / ### Other).

<changelog_path> defaults to <repo-root>/CHANGELOG.md.

This is a one-shot finalize step, meant to run once per confirmed deploy,
after the semver bump is confirmed and before the release is recorded to
the publish ledger. It does not merge or classify entries — that is
generate_release_notes.sh's job, run earlier in the deploy pipeline.
USAGE
}

[[ $# -ge 1 ]] || { usage >&2; exit 1; }
VERSION_RAW="$1"
CHANGELOG_PATH="${2:-$PUBLISH_REPO_ROOT/CHANGELOG.md}"

VERSION="$(publish_normalize_version "$VERSION_RAW")" || {
  echo "finalize_changelog.sh: invalid version '$VERSION_RAW'." >&2
  exit 1
}

[[ -f "$CHANGELOG_PATH" ]] || {
  echo "finalize_changelog.sh: changelog not found at '$CHANGELOG_PATH'." >&2
  exit 1
}

TODAY="$(date -u +"%Y-%m-%d")"

# ---------------------------------------------------------------------------
# Plain indexed-array line editing, matching generate_release_notes.sh's
# bash 3.2 convention (no mapfile/declare -A/local -n; the stock macOS
# default shell lacks all three). Zero-element array expansions are guarded
# with explicit count checks before use under `set -u`, same as that file.
# ---------------------------------------------------------------------------

CL_LINES=()

_cl_load() {
  CL_LINES=()
  local line
  while IFS= read -r line || [[ -n "$line" ]]; do
    CL_LINES+=("$line")
  done < "$1"
}

_cl_save() {
  if (( ${#CL_LINES[@]} > 0 )); then
    printf '%s\n' "${CL_LINES[@]}" > "$1"
  else
    : > "$1"
  fi
}

_cl_load "$CHANGELOG_PATH"

UNRELEASED_INDEX=-1
CL_LINE_COUNT=${#CL_LINES[@]}
i=0
while (( i < CL_LINE_COUNT )); do
  if [[ "${CL_LINES[$i]}" == "## [Unreleased]" ]]; then
    UNRELEASED_INDEX=$i
    break
  fi
  i=$((i + 1))
done

if (( UNRELEASED_INDEX < 0 )); then
  echo "finalize_changelog.sh: '## [Unreleased]' section not found in $CHANGELOG_PATH — nothing to finalize." >&2
  exit 1
fi

# Stamp the located heading in place.
CL_LINES[UNRELEASED_INDEX]="## [$VERSION] — $TODAY"

BEFORE=()
AFTER=()
if (( UNRELEASED_INDEX > 0 )); then
  BEFORE=("${CL_LINES[@]:0:UNRELEASED_INDEX}")
fi
AFTER=("${CL_LINES[@]:UNRELEASED_INDEX}")

FRESH_UNRELEASED=(
  "## [Unreleased]"
  ""
  "### Features"
  ""
  "### Bug Fixes"
  ""
  "### Other"
  ""
)

CL_LINES=()
if (( ${#BEFORE[@]} > 0 )); then
  CL_LINES+=("${BEFORE[@]}")
fi
CL_LINES+=("${FRESH_UNRELEASED[@]}")
CL_LINES+=("${AFTER[@]}")

_cl_save "$CHANGELOG_PATH"

printf '🏷️  CHANGELOG.md finalized: [Unreleased] stamped as [%s] — %s\n' "$VERSION" "$TODAY"
