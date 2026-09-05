#!/usr/bin/env bash
# compute-scope-divergence.sh — Compute scope_divergence_flag for a task
#
# Usage: compute-scope-divergence.sh <execution_scope> <actual_files_changed> <actual_lines_delta>
#
# Reads project/configs/scope-thresholds.json (resolved from git root) and compares
# the supplied diff stats against the thresholds that apply to <execution_scope>.
#
# Scope logic:
#   inline  — divergence if actual_files_changed > inline_max_files
#                       OR actual_lines_delta    > inline_max_lines
#   story   — divergence if actual_files_changed > story_max_files
#   task    — no automatic threshold: always false
#   epic    — no automatic threshold: always false
#   (any other value) — treated as task; always false
#
# Prints "true" or "false" on stdout and exits 0.
# If the config file is missing or cannot be parsed, prints "false" (non-blocking),
# emits a warning to stderr, and exits 0.
#
# Exit codes:
#   0 — success (including graceful degradation when config is absent/malformed)
#   1 — invalid argument count

set -euo pipefail

# ---------------------------------------------------------------------------
# Argument validation
# ---------------------------------------------------------------------------

if [[ $# -ne 3 ]]; then
  echo "Usage: $(basename "$0") <execution_scope> <actual_files_changed> <actual_lines_delta>" >&2
  echo "  Example: $(basename "$0") inline 2 35" >&2
  exit 1
fi

EXECUTION_SCOPE="${1}"
ACTUAL_FILES="${2}"
ACTUAL_LINES="${3}"

# ---------------------------------------------------------------------------
# Short-circuit: task and epic scopes never flag divergence
# ---------------------------------------------------------------------------

if [[ "$EXECUTION_SCOPE" == "task" || "$EXECUTION_SCOPE" == "epic" ]]; then
  echo "false"
  exit 0
fi

# ---------------------------------------------------------------------------
# Locate the config file (relative to git root)
# ---------------------------------------------------------------------------

GIT_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || true)

if [[ -z "$GIT_ROOT" ]]; then
  echo "WARNING: Not inside a git repository; cannot locate scope-thresholds.json. Skipping divergence flag." >&2
  echo "false"
  exit 0
fi

CONFIG_FILE="${GIT_ROOT}/project/configs/scope-thresholds.json"

if [[ ! -f "$CONFIG_FILE" ]]; then
  echo "WARNING: scope-thresholds.json not found at '${CONFIG_FILE}'. Skipping divergence flag." >&2
  echo "false"
  exit 0
fi

# ---------------------------------------------------------------------------
# Parse thresholds (jq preferred, plain shell fallback)
# ---------------------------------------------------------------------------

INLINE_MAX_FILES=""
INLINE_MAX_LINES=""
STORY_MAX_FILES=""

if command -v jq >/dev/null 2>&1; then
  INLINE_MAX_FILES=$(jq -r '.inline_max_files // empty' "$CONFIG_FILE" 2>/dev/null || true)
  INLINE_MAX_LINES=$(jq -r '.inline_max_lines // empty' "$CONFIG_FILE" 2>/dev/null || true)
  STORY_MAX_FILES=$(jq -r  '.story_max_files  // empty' "$CONFIG_FILE" 2>/dev/null || true)
else
  # Plain shell fallback: grep for the numeric value on the matching key line
  INLINE_MAX_FILES=$(grep '"inline_max_files"' "$CONFIG_FILE" | grep -o '[0-9][0-9]*' | head -1 || true)
  INLINE_MAX_LINES=$(grep '"inline_max_lines"' "$CONFIG_FILE" | grep -o '[0-9][0-9]*' | head -1 || true)
  STORY_MAX_FILES=$(grep  '"story_max_files"'  "$CONFIG_FILE" | grep -o '[0-9][0-9]*' | head -1 || true)
fi

# Validate that all required thresholds were parsed
if [[ -z "$INLINE_MAX_FILES" || -z "$INLINE_MAX_LINES" || -z "$STORY_MAX_FILES" ]]; then
  echo "WARNING: scope-thresholds.json is malformed or missing required keys (inline_max_files, inline_max_lines, story_max_files). Skipping divergence flag." >&2
  echo "false"
  exit 0
fi

# Ensure values are integers
if ! [[ "$INLINE_MAX_FILES" =~ ^[0-9]+$ && "$INLINE_MAX_LINES" =~ ^[0-9]+$ && "$STORY_MAX_FILES" =~ ^[0-9]+$ ]]; then
  echo "WARNING: Non-integer threshold value found in scope-thresholds.json. Skipping divergence flag." >&2
  echo "false"
  exit 0
fi

# ---------------------------------------------------------------------------
# Apply per-scope divergence logic
# ---------------------------------------------------------------------------

case "$EXECUTION_SCOPE" in
  inline)
    if [[ "$ACTUAL_FILES" -gt "$INLINE_MAX_FILES" ]] || [[ "$ACTUAL_LINES" -gt "$INLINE_MAX_LINES" ]]; then
      echo "true"
    else
      echo "false"
    fi
    ;;
  story)
    if [[ "$ACTUAL_FILES" -gt "$STORY_MAX_FILES" ]]; then
      echo "true"
    else
      echo "false"
    fi
    ;;
  *)
    # Unknown scope — treat conservatively as no divergence
    echo "false"
    ;;
esac

exit 0
