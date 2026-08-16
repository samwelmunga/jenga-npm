#!/usr/bin/env bash
# commit-version-bump.sh — Commit the package.json version bump as a standalone git commit.
#
# Called by the /distribute skill after a successful non-amend distribution run.
# No arguments. Reads the new version from package.json at the monorepo root.
#
# Behaviour:
#   1. Resolve monorepo root from this script's own location (two levels up from scripts/).
#   2. Read the version field from <monorepo_root>/package.json.
#   3. Stage only package.json: git add package.json.
#   4. If nothing changed, exit 0 with an informational message.
#   5. Create commit: "chore: bump version to <version>".
#   6. Exit 0 on success, non-zero with a descriptive message on failure.
#
# Exit codes:
#   0  success (commit created, or nothing to commit)
#   1  fatal error (package.json missing, version unreadable, git commit failed)

set -uo pipefail

# ---------------------------------------------------------------------------
# Path resolution
# ---------------------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# scripts/ -> distribute/ -> skills/ -> <monorepo_root>
MONOREPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
PACKAGE_JSON="$MONOREPO_ROOT/package.json"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

log_info() {
  printf '→ %s\n' "$1"
}

fail() {
  printf 'commit-version-bump: error: %s\n' "$1" >&2
  exit 1
}

# ---------------------------------------------------------------------------
# Validate prerequisites
# ---------------------------------------------------------------------------

if [[ ! -f "$PACKAGE_JSON" ]]; then
  fail "package.json not found at $PACKAGE_JSON"
fi

if ! command -v node >/dev/null 2>&1; then
  fail "node is required to read package.json but was not found in PATH"
fi

# ---------------------------------------------------------------------------
# Read version from package.json
# ---------------------------------------------------------------------------

VERSION="$(node -p "require('$PACKAGE_JSON').version" 2>/dev/null)" || \
  fail "Failed to read version from $PACKAGE_JSON"

if [[ -z "$VERSION" ]]; then
  fail "version field is empty or missing in $PACKAGE_JSON"
fi

log_info "Version read from package.json: $VERSION"

# ---------------------------------------------------------------------------
# Stage package.json
# ---------------------------------------------------------------------------

git -C "$MONOREPO_ROOT" add "$PACKAGE_JSON" || fail "git add failed for $PACKAGE_JSON"

# ---------------------------------------------------------------------------
# Check whether there is anything to commit
# ---------------------------------------------------------------------------

if git -C "$MONOREPO_ROOT" diff --cached --quiet; then
  log_info "Nothing to commit — package.json is already clean"
  exit 0
fi

# ---------------------------------------------------------------------------
# Verify only package.json is staged (safety check)
# ---------------------------------------------------------------------------

STAGED_FILES="$(git -C "$MONOREPO_ROOT" diff --cached --name-only)"
STAGED_COUNT="$(printf '%s\n' "$STAGED_FILES" | grep -c .)"

if [[ "$STAGED_COUNT" -gt 1 ]]; then
  fail "Unexpected staged files detected. Only package.json should be staged. Found:
$STAGED_FILES"
fi

# ---------------------------------------------------------------------------
# Commit
# ---------------------------------------------------------------------------

COMMIT_MSG="chore: bump version to $VERSION"

log_info "Creating commit: $COMMIT_MSG"

if ! git -C "$MONOREPO_ROOT" commit -m "$COMMIT_MSG"; then
  fail "git commit failed for version bump to $VERSION"
fi

log_info "Committed successfully: $COMMIT_MSG"
exit 0
