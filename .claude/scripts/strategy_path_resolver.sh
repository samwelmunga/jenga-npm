#!/usr/bin/env bash
# Resolves where the project's strategy brief (STRATEGY.md) lives.
# Prints one path (relative to the working-file anchor, no trailing slash) to stdout.
#
# Single source for both /init (which scaffolds the file) and /strategy (which reads and
# writes it), so the two cannot drift (E34_S06_T03). The registry is located and read by the
# shared resolver, scripts/resolve-root.sh (E34_S01), so there is exactly one mechanism and this
# script works from any subdirectory of the project and from a relocated tree.
#
#   configured : paths.strategy in the registry (absent key or registry =>
#                project/documentation/STRATEGY.md, the default since E34_S07)
#   legacy     : docs/STRATEGY.md, the path every pre-E34_S07 consumer project already has
#
# Resolution order:
#   1. the configured path, when that file exists
#   2. the legacy path, when the configured path does not exist but the legacy file does
#      (so changing paths.strategy later updates the existing file in place instead of
#      silently creating a second copy)
#   3. the configured path (where a new file should be created)
#
# Uses the resolver's default (non-strict) mode: a project with no registry still gets
# project/documentation/STRATEGY.md. Existence checks run against the anchor, not the current directory.
#
# Exits non-zero and prints to stderr when the registry exists but is malformed (the resolver's
# exit 1), or when JENGA_PROJECT_ROOT names a root that has no registry (exit 3).

# Deliberate legacy fallback (E34_S07): the one intentional surviving "docs/STRATEGY.md" literal
# under scripts/. A consumer project whose file still sits there keeps resolving to it, so
# /strategy updates it in place. No script ever moves, copies or deletes a consumer's file;
# migrating is the consumer's own call (git mv docs/STRATEGY.md project/documentation/STRATEGY.md).
LEGACY="docs/STRATEGY.md"

_strategy_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=resolve-root.sh
. "$_strategy_dir/resolve-root.sh"

anchor=$(jenga_resolve_root) || exit $?
configured=$(jenga_resolve_path strategy --relative) || exit $?

# A registry value may be absolute; otherwise it is relative to the anchor.
case "$configured" in
  /*) configured_file="$configured" ;;
  *) configured_file="$anchor/$configured" ;;
esac

if [ ! -f "$configured_file" ] && [ -f "$anchor/$LEGACY" ]; then
  printf '%s\n' "$LEGACY"
else
  printf '%s\n' "$configured"
fi
exit 0
