#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# scripts/remove-scratch-mcp.sh - delete the .mcp.json of a scratch project
#
# USAGE
#   remove-scratch-mcp.sh <project-dir>
#
# Removes <project-dir>/.mcp.json and nothing else. Idempotent: when the file is already gone it says so and
# exits 0, so a resumed workflow run does not fail on a step that had already done its work.
#
# Refuses (exit 2) when <project-dir> is missing, is not a directory, or is the repository this script belongs
# to: that repository's own .mcp.json is real configuration, not scratch.
#
# stdout: one line, "removed <path>" or "nothing to remove: <path> does not exist".
# EXIT CODES: 0 done or already absent, 2 usage error or refused target.
# ---------------------------------------------------------------------------
set -u

die() { printf 'remove-scratch-mcp.sh: %s\n' "$1" >&2; exit 2; }

[ "$#" -eq 1 ] && [ -n "$1" ] || die "usage: remove-scratch-mcp.sh <project-dir>"
[ -d "$1" ] || die "not a directory: $1"

SELF_DIR="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
repo_root="$(CDPATH='' cd -P -- "$SELF_DIR/.." && pwd)"
target_dir="$(CDPATH='' cd -P -- "$1" && pwd)"

[ "$target_dir" != "$repo_root" ] || die "refusing to touch this repository's own .mcp.json ($repo_root)"

file="$target_dir/.mcp.json"
if [ ! -e "$file" ] && [ ! -L "$file" ]; then
  echo "nothing to remove: $file does not exist"
  exit 0
fi
[ -f "$file" ] || [ -L "$file" ] || die "not a regular file: $file"

rm -- "$file" || die "could not remove $file"
echo "removed $file"
