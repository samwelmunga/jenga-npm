#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# skills/jenga/scripts/load-nl-catalog.sh
#
# Thin bash entry point for `load-nl-catalog.js` — the SINGLE REQUIRED SOURCE of skill-catalog
# data for `/jenga`'s natural-language branch (E53_S01_T03). `skills/jenga/SKILL.md` must never
# re-implement its own skill directory scan or hand-maintain a skill list; it only ever invokes
# this script and reads its stdout.
#
# This script's only job is root resolution: it locates JENGA_PROJECT_DIR (the consuming
# project's root) and PKG_ROOT (the jenga-agent PACKAGE root — where the canonical skills/ tree
# and lib/generate-skill-allow-list.js actually live, which may differ from the project root for
# an npm-installed consumer) and hands both to the Node helper, which does the actual reading and
# JSON assembly (see load-nl-catalog.js's own header for the full contract).
#
# ---------------------------------------------------------------------------
# USAGE
# ---------------------------------------------------------------------------
#   skills/jenga/scripts/load-nl-catalog.sh
#
# No arguments. Emits the full JSON catalog array to stdout — see load-nl-catalog.js's header for
# the exact per-entry shape (name/description/keywords/examples/prefered_agent).
#
# ---------------------------------------------------------------------------
# EXIT CODES
# ---------------------------------------------------------------------------
#   0   catalog written to stdout
#   2   setup failure: package root could not be located, node is missing, or the Node helper
#       itself failed (see its own stderr message for the reason)
#
# ---------------------------------------------------------------------------

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Resolve JENGA_PROJECT_DIR the same way every other script in skills/jenga/scripts/ does.
if [ -f "$SCRIPT_DIR/../../../lib/resolve-project-dir.sh" ]; then
  # shellcheck source=/dev/null
  source "$SCRIPT_DIR/../../../lib/resolve-project-dir.sh"
elif [ -n "${CLAUDE_PROJECT_DIR:-}" ]; then
  JENGA_PROJECT_DIR="$CLAUDE_PROJECT_DIR"
else
  JENGA_PROJECT_DIR="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel 2>/dev/null || pwd)"
fi

# Resolve the jenga-agent PACKAGE root (where lib/generate-skill-allow-list.js and the canonical
# skills/ tree actually live) — same monorepo-checkout vs. installed-npm-package detection used
# by skills/init/scripts/init.sh's PKG_ROOT resolution.
if [ -d "$SCRIPT_DIR/../../../templates" ]; then
  PKG_ROOT="$SCRIPT_DIR/../../.."
elif [ -d "$JENGA_PROJECT_DIR/node_modules/@jenga-ai/agent/templates" ]; then
  PKG_ROOT="$JENGA_PROJECT_DIR/node_modules/@jenga-ai/agent"
else
  echo "Error: could not locate the jenga-agent package root (templates/ not found via monorepo checkout or node_modules/@jenga-ai/agent)." >&2
  exit 2
fi

if ! command -v node >/dev/null 2>&1; then
  echo "Error: node is required by load-nl-catalog.sh" >&2
  exit 2
fi

node "$SCRIPT_DIR/load-nl-catalog.js" "$JENGA_PROJECT_DIR" "$PKG_ROOT"
exit $?
