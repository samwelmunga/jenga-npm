#!/usr/bin/env bash
# smoke-harness.sh — Per-repository smoke test harness for inline-scoped task execution
#
# Usage:
#   bash scripts/smoke-harness.sh [changed_file ...]
#
# If changed files are supplied as positional arguments, those are used directly.
# If no arguments are given, the harness infers changed files from:
#   git diff --name-only HEAD
#
# Discovery algorithm (in priority order):
#   1. scripts/smoke.sh   — if present, delegate and return its exit code
#   2. npm test           — if package.json has a .scripts.test entry and jq is available
#   3. pytest             — if pytest is in PATH and setup.py/pyproject.toml exists
#   4. go test ./...      — if go.mod exists
#   5. No runner found    — pass if all changed files are config/docs; fail otherwise
#
# Exit codes:
#   0 — smoke test passed (or structural-only change with no runner available)
#   1 — smoke test failed (or logic files changed with no runner available)

set -uo pipefail

# ---------------------------------------------------------------------------
# Resolve repo root
# ---------------------------------------------------------------------------
REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"

# ---------------------------------------------------------------------------
# Collect changed files
# ---------------------------------------------------------------------------
# Accept changed files as positional arguments; if none given, infer from git.
# Uses a portable loop rather than mapfile/readarray (bash 3.x safe for macOS).
if [[ $# -gt 0 ]]; then
  CHANGED_FILES=("$@")
else
  CHANGED_FILES=()
  while IFS= read -r line; do
    [[ -n "$line" ]] && CHANGED_FILES+=("$line")
  done < <(git diff --name-only HEAD 2>/dev/null || true)
fi

# ---------------------------------------------------------------------------
# Step 1: Delegate to scripts/smoke.sh if it exists
# ---------------------------------------------------------------------------
if [[ -f "$REPO_ROOT/scripts/smoke.sh" ]]; then
  echo "INFO: Found scripts/smoke.sh — delegating to project smoke test."
  bash "$REPO_ROOT/scripts/smoke.sh"
  exit $?
fi

# ---------------------------------------------------------------------------
# Step 2: Infer npm test
# Requires: package.json with a non-null .scripts.test field, and jq in PATH.
# ---------------------------------------------------------------------------
if [[ -f "$REPO_ROOT/package.json" ]]; then
  if command -v jq > /dev/null 2>&1; then
    if jq -e '.scripts.test // empty' "$REPO_ROOT/package.json" > /dev/null 2>&1; then
      echo "INFO: Detected npm project with test script — running npm test."
      cd "$REPO_ROOT" && npm test
      exit $?
    else
      echo "INFO: package.json found but no .scripts.test entry — skipping npm test inference."
    fi
  else
    echo "INFO: package.json found but jq is not available — skipping npm test inference."
  fi
fi

# ---------------------------------------------------------------------------
# Step 3: Infer pytest
# Requires: pytest in PATH, and setup.py or pyproject.toml at repo root.
# ---------------------------------------------------------------------------
if command -v pytest > /dev/null 2>&1; then
  if [[ -f "$REPO_ROOT/setup.py" || -f "$REPO_ROOT/pyproject.toml" ]]; then
    echo "INFO: Detected Python project — running pytest."
    cd "$REPO_ROOT" && pytest
    exit $?
  fi
fi

# ---------------------------------------------------------------------------
# Step 4: Infer go test
# Requires: go.mod at repo root.
# ---------------------------------------------------------------------------
if [[ -f "$REPO_ROOT/go.mod" ]]; then
  echo "INFO: Detected Go project — running go test ./..."
  cd "$REPO_ROOT" && go test ./...
  exit $?
fi

# ---------------------------------------------------------------------------
# Step 5: No test runner found — classify changed files
#
# Files are considered config/documentation if they match one of:
#   - Extension: .json .yaml .yml .md .txt .toml .ini .cfg
#   - Path prefix: docs/ project/ templates/
#   - Shell scripts in scripts/: scripts/*.sh (structural scaffolding, not logic)
# All other files are treated as logic/source files requiring a real test.
# ---------------------------------------------------------------------------
CONFIG_DOC_PATTERN='\.(json|yaml|yml|md|txt|toml|ini|cfg)$'
STRUCTURAL_SCRIPT_PATTERN='^scripts/[^/]+\.sh$'
STRUCTURAL_PATH_PATTERN='^(docs|project|templates)/'

NON_CONFIG_FILES=()
for f in "${CHANGED_FILES[@]}"; do
  is_config=false

  # Check extension pattern
  if echo "$f" | grep -qE "$CONFIG_DOC_PATTERN"; then
    is_config=true
  fi

  # Check structural script pattern (scripts/*.sh)
  if echo "$f" | grep -qE "$STRUCTURAL_SCRIPT_PATTERN"; then
    is_config=true
  fi

  # Check structural path prefix
  if echo "$f" | grep -qE "$STRUCTURAL_PATH_PATTERN"; then
    is_config=true
  fi

  if [[ "$is_config" == "false" ]]; then
    NON_CONFIG_FILES+=("$f")
  fi
done

if [[ ${#NON_CONFIG_FILES[@]} -gt 0 ]]; then
  echo "ERROR: No smoke test runner found and the task touches logic/source files:" >&2
  for f in "${NON_CONFIG_FILES[@]}"; do
    echo "  - $f" >&2
  done
  echo "Add a test runner (scripts/smoke.sh, npm test, pytest, or go test) before marking this task complete." >&2
  exit 1
fi

echo "INFO: No test runner discoverable; all changed files are config/docs/structural. Smoke test passes."
exit 0
