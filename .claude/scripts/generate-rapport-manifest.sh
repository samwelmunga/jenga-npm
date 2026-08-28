#!/bin/bash
# scripts/generate-rapport-manifest.sh
#
# Regenerates the rapport manifest used by hooks/on_session_end.sh to detect
# *new* problem rapports (project/rapports/problems/*.md, excluding resolved
# *.IGNORE.md files). This script is the single source of truth for "what
# does the manifest look like right now" — it is used both to produce the
# committed seed manifest and, at runtime, by the hook itself whenever it
# rewrites the manifest after finding new rapports.
#
# Entries are stored as paths relative to the repo root (e.g.
# "project/rapports/problems/foo.md"), NOT absolute paths. The manifest is
# a committed artifact shared across every clone/worktree, each of which
# has a different absolute checkout location — absolute paths would make
# the seed match nobody's filesystem but the one it was generated on.
#
# Safe to re-run at any time: it is a pure snapshot of the current directory
# contents, never a diff, so running it twice in a row produces identical
# output.
#
# Usage: scripts/generate-rapport-manifest.sh [output_file]
#   output_file defaults to project/data/rapport_manifest.json

set -euo pipefail

# shellcheck source=lib/resolve-project-dir.sh
source "$(git rev-parse --show-toplevel)/lib/resolve-project-dir.sh"

PROJECT_DIR="$JENGA_PROJECT_DIR"
RAPPORT_DIR="$PROJECT_DIR/project/rapports/problems"
OUTPUT="${1:-$PROJECT_DIR/project/data/rapport_manifest.json}"

mkdir -p "$(dirname "$OUTPUT")"

if [ -d "$RAPPORT_DIR" ]; then
  find "$RAPPORT_DIR" -name "*.md" ! -name "*.IGNORE.md" 2>/dev/null \
    | sed "s|^$PROJECT_DIR/||" \
    | sort | jq -R . | jq -s . > "$OUTPUT"
else
  echo "[]" > "$OUTPUT"
fi

echo "Wrote $(jq 'length' "$OUTPUT") rapport filename(s) to $OUTPUT"
