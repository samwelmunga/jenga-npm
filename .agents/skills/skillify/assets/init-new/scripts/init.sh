#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ASSETS_DIR="$SCRIPT_DIR/../assets"

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

# ─── 9. Initial commit ───────────────────────────────────────────────────────
echo "→ Staging and committing scaffolded files..."
git add -A
git commit -m "init: scaffold project structure and workflow config"

echo ""
echo "✓ Project scaffold complete."