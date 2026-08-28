#!/usr/bin/env bash
# scripts/jenga-permission-level-switch.sh — switch the current session's
# 5-tier permission level by copying the matching template into
# .claude/settings.json and .agents/settings.json, and recording the level
# in .jenga-permission-level.json at the repo root.
#
# Usage: bash scripts/jenga-permission-level-switch.sh <n>
#   <n> must be an integer 1-5.
#
# Behavior:
#   - Templates live at templates/permission-levels/level-<n>-<name>.json
#     and are COMPLETE settings.json documents (defaultMode, env,
#     permissions, hooks). The copy is a whole-file overwrite of the
#     destination, not a merge — this intentionally drops any extra
#     top-level blocks (e.g. autoMode) present in the destination but
#     absent from the template. autoMode is never used at any permission
#     level (see PROJECT_SUMMARY.md, epic E33).
#   - Both destination writes use a temp-file-then-atomic-rename pattern.
#   - .jenga-permission-level.json is only written after BOTH settings.json
#     copies succeed. If the .claude/ copy succeeds but the .agents/ copy
#     fails, the script fails loud (no rollback of the .claude/ copy, no
#     write to .jenga-permission-level.json) and instructs the user to
#     re-run — re-running with the same <n> is idempotent and self-heals
#     the inconsistency, since every copy is an unconditional overwrite.
#   - Invalid input (missing/extra args, non-integer, out of range 1-5)
#     exits non-zero and makes zero file changes.
#
# Exit codes:
#   0  Success — all three files updated consistently.
#   1  Invalid usage/argument — no files changed.
#   2  Mapped template file missing — no files changed.
#   3  Failed to copy template to .claude/settings.json — no files changed.
#   4  Failed to copy template to .agents/settings.json — .claude/settings.json
#      WAS updated (inconsistent state); re-run the script to repair.
#   5  Failed to write .jenga-permission-level.json — both settings.json
#      files WERE updated (inconsistent state); re-run the script to repair.

set -euo pipefail

usage() {
  echo "Usage: $(basename "$0") <n>   (n must be an integer 1-5)" >&2
}

if [[ $# -ne 1 ]]; then
  echo "Error: expected exactly one argument, got $#." >&2
  usage
  exit 1
fi

LEVEL="$1"

if ! [[ "$LEVEL" =~ ^[1-5]$ ]]; then
  echo "Error: permission level must be an integer between 1 and 5, got '$LEVEL'." >&2
  usage
  exit 1
fi

case "$LEVEL" in
  1) NAME="locked" ;;
  2) NAME="guarded" ;;
  3) NAME="standard" ;;
  4) NAME="elevated" ;;
  5) NAME="unrestricted" ;;
esac

REPO_ROOT="$(git rev-parse --show-toplevel)"
TEMPLATE="$REPO_ROOT/templates/permission-levels/level-${LEVEL}-${NAME}.json"
CLAUDE_SETTINGS="$REPO_ROOT/.claude/settings.json"
AGENTS_SETTINGS="$REPO_ROOT/.agents/settings.json"
LEVEL_FILE="$REPO_ROOT/.jenga-permission-level.json"

if [[ ! -f "$TEMPLATE" ]]; then
  echo "Error: template file not found for level $LEVEL: $TEMPLATE" >&2
  exit 2
fi

# Whole-file overwrite of destination via temp-file + atomic rename.
copy_template() {
  local dest="$1"
  local tmp="${dest}.tmp"
  mkdir -p "$(dirname "$dest")"
  cp "$TEMPLATE" "$tmp" && mv "$tmp" "$dest"
}

if ! copy_template "$CLAUDE_SETTINGS"; then
  echo "Error: failed to copy template to $CLAUDE_SETTINGS. No files changed." >&2
  rm -f "${CLAUDE_SETTINGS}.tmp"
  exit 3
fi

if ! copy_template "$AGENTS_SETTINGS"; then
  echo "Error: failed to copy template to $AGENTS_SETTINGS." >&2
  echo "State is now INCONSISTENT: $CLAUDE_SETTINGS was updated to level $LEVEL but $AGENTS_SETTINGS was not." >&2
  echo ".jenga-permission-level.json was NOT updated. Re-run this script to repair (it is idempotent)." >&2
  rm -f "${AGENTS_SETTINGS}.tmp"
  exit 4
fi

# Only write the metadata file after both settings.json copies succeeded.
LEVEL_TMP="${LEVEL_FILE}.tmp"
if ! jq -n --argjson n "$LEVEL" '{"session_level": $n}' > "$LEVEL_TMP" || ! mv "$LEVEL_TMP" "$LEVEL_FILE"; then
  echo "Error: failed to write $LEVEL_FILE." >&2
  echo "State is now INCONSISTENT: both settings.json files were updated to level $LEVEL but .jenga-permission-level.json was not. Re-run this script to repair (it is idempotent)." >&2
  rm -f "$LEVEL_TMP"
  exit 5
fi

echo "Switched to level $LEVEL ($NAME)."
exit 0
