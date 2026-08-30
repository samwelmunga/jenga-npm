#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ASSETS_DIR="$SCRIPT_DIR/../assets"
VISIBILITY_SCRIPT="$SCRIPT_DIR/apply-project-visibility.sh"

# ─── Resolve the package root that owns templates/ and lib/ ──────────────────
# postinstall.js mirrors only skills/ and agents/ into .claude/ and .agents/ —
# templates/ and lib/ are never copied there, so a script running from a
# mirrored copy (.claude/skills/init/scripts/ or .agents/skills/init/scripts/)
# cannot reach its siblings via a fixed ../../../ climb the way it can in this
# monorepo checkout, where init.sh actually lives at skills/init/scripts/ with
# templates/ and lib/ three levels up. Consumers instead have them inside the
# installed npm package.
if [[ -d "$SCRIPT_DIR/../../../templates" ]]; then
  PKG_ROOT="$SCRIPT_DIR/../../.."
elif [[ -d "$PWD/node_modules/@jenga-ai/agent/templates" ]]; then
  PKG_ROOT="$PWD/node_modules/@jenga-ai/agent"
else
  echo "Error: could not locate the jenga-agent package root (templates/ not found via monorepo checkout or node_modules/@jenga-ai/agent)." >&2
  exit 1
fi

# ─── 0. Resolve project_files_visibility ─────────────────────────────────────
# Defaults to `visible` — the only value that touches nothing on disk — so an
# unattended run can never silently relocate directories or edit .gitignore.
VISIBILITY="${JENGA_PROJECT_FILES_VISIBILITY:-visible}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --visibility)   VISIBILITY="${2:-}"; shift 2 ;;
    --visibility=*) VISIBILITY="${1#*=}"; shift ;;
    *) echo "Unknown argument: $1" >&2
       echo "Usage: $(basename "$0") [--visibility <visible|ignored>]" >&2
       exit 1 ;;
  esac
done

# Validate before scaffolding so a typo cannot leave a half-initialised project.
bash "$VISIBILITY_SCRIPT" --check-only "$VISIBILITY"

# ─── 1. Initialize git repository ────────────────────────────────────────────
echo "→ Initializing git repository..."
git init

# ─── 2. Create .gitignore ─────────────────────────────────────────────────────
echo "→ Copying .gitignore from template..."
cp "$ASSETS_DIR/.gitignore_template" .gitignore

# ─── 3. Scaffold directory structure ──────────────────────────────────────────
echo "→ Scaffolding directory structure..."
while IFS= read -r dir || [[ -n "$dir" ]]; do
  [[ -z "$dir" || "$dir" == \#* ]] && continue
  mkdir -p "$dir"
done < "$ASSETS_DIR/directory_structure.txt"

# ─── 4. Create project/PROJECT_SUMMARY.md ────────────────────────────────────
echo "→ Copying PROJECT_SUMMARY.md from template..."
cp "$ASSETS_DIR/PROJECT_SUMMARY_template.md" project/PROJECT_SUMMARY.md

# ─── 5. Create project/configs/workflow.json ─────────────────────────────────
echo "→ Copying workflow.json from template..."
cp "$ASSETS_DIR/workflow_template.json" project/configs/workflow.json

# ─── 6. Create project/configs/test-config.json stub ─────────────────────────
echo "→ Copying test-config.json from template..."
cp "$ASSETS_DIR/test-config_template.json" project/configs/test-config.json

# ─── 7. Create project/data/baselines.json ───────────────────────────────────
echo "→ Creating baselines.json..."
echo '{}' > project/data/baselines.json

# ─── 8. Create project/logs/events.json ──────────────────────────────────────
echo "→ Creating events.json..."
echo '[]' > project/logs/events.json

# ─── 9. Create docs/STRATEGY.md ──────────────────────────────────────────────
echo "→ Creating docs/STRATEGY.md (strategic brief for investors, partners, and the product team)..."
mkdir -p docs
cp "$ASSETS_DIR/strategy_stub_template.md" docs/STRATEGY.md

# ─── 10. Create CHANGELOG.md ──────────────────────────────────────────────────
echo "→ Creating CHANGELOG.md from template..."
cp "$PKG_ROOT/templates/CHANGELOG_TEMPLATE.md" CHANGELOG.md

# ─── 11. Apply project_files_visibility ──────────────────────────────────────
# Runs before the commit so the .gitignore entry (ignored) is captured in the
# initial commit.
echo "→ Applying project files visibility ($VISIBILITY)..."
bash "$VISIBILITY_SCRIPT" "$VISIBILITY" "$PWD"

# ─── 12. Generate CLAUDE.md / AGENTS.md ──────────────────────────────────────
# Unconditional — never gated on agentTarget (E41_S04). Applies the J-
# collision rule and idempotent managed-block updates; see
# lib/generate-agent-context.js (shared with the published `jenga init` CLI).
echo "→ Generating CLAUDE.md / AGENTS.md..."
if command -v node >/dev/null 2>&1; then
  node "$PKG_ROOT/lib/generate-agent-context.js" "$PWD"
else
  echo "  Warning: node not found — skipped CLAUDE.md/AGENTS.md generation." >&2
fi

# ─── 13. Initial commit ──────────────────────────────────────────────────────
echo "→ Staging and committing scaffolded files..."
git add -A
git commit -m "init: scaffold project structure and workflow config"

echo ""
echo "✓ Project scaffold complete."