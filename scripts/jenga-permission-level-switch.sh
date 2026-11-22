#!/usr/bin/env bash
# scripts/jenga-permission-level-switch.sh — switch the current session's
# 5-tier permission level by merging the matching template's level-policy keys
# into .claude/settings.json and .agents/settings.json, and recording the level
# in .jenga-permission-level.json at the repo root.
#
# Usage: bash scripts/jenga-permission-level-switch.sh <n>
#        bash scripts/jenga-permission-level-switch.sh --help
#   <n> must be an integer 1-5.
#
# Owned keys (the level policy; the only keys this script writes):
#   defaultMode, permissions.deny, permissions.ask, autoMode
#   (E100_S01: project/documentation/client-settings-requirements.md; the
#   list lives in OWNED_KEYS below.)
#
# Behavior:
#   - Templates live at templates/permission-levels/level-<n>-<name>.json.
#     This is a KEY-LEVEL MERGE, not a copy of the whole template: for each owned key
#     the destination takes the template's value, or loses the key when the
#     template does not set it (the new level's policy replaces the old one).
#     Every other key (hooks, permissions.allow, env, statusLine, ...) is left
#     exactly as it was, in its original order. Key order of the destination is
#     preserved; an owned key the destination lacked is appended.
#   - A destination that does not exist is created holding only the owned keys.
#     A destination that is not a valid JSON object fails loud, names the
#     file, and is left unchanged.
#   - Both destination writes use a temp-file-then-atomic-rename pattern.
#   - .jenga-permission-level.json is only written after BOTH settings.json
#     merges succeed. If the .claude/ merge succeeds but the .agents/ merge
#     fails, the script fails loud (no rollback of the .claude/ merge, no
#     write to .jenga-permission-level.json) and instructs the user to
#     re-run; re-running with the same <n> is idempotent and self-heals.
#   - After success, a destination with no PreToolUse entry that runs
#     hooks/on_preflight_check.sh gets one stderr line saying the pre-flight
#     backstop is not registered and that `npx jenga sync` registers it.
#   - Invalid input (missing/extra args, non-integer, out of range 1-5)
#     exits non-zero and makes zero file changes. --help exits 0, no changes.
#
# Exit codes:
#   0  Success (also --help).
#   1  Invalid usage/argument — no files changed.
#   2  Mapped template file missing — no files changed.
#   3  .claude/settings.json is not valid JSON or could not be written — unchanged.
#   4  .agents/settings.json is not valid JSON or could not be written —
#      .claude/settings.json WAS updated (inconsistent state); re-run to repair.
#   5  Failed to write .jenga-permission-level.json — both settings.json
#      files WERE updated (inconsistent state); re-run the script to repair.

set -euo pipefail

# The level-policy key paths this script owns. Nothing else is ever written.
OWNED_KEYS='[["defaultMode"],["permissions","deny"],["permissions","ask"],["autoMode"]]'

usage() {
  echo "Usage: $(basename "$0") <n>   (n must be an integer 1-5)" >&2
}

if [[ $# -eq 1 && ( "$1" == "--help" || "$1" == "-h" ) ]]; then
  usage
  echo "Merges the level policy (defaultMode, permissions.deny, permissions.ask, autoMode) of level <n> into" >&2
  echo ".claude/settings.json and .agents/settings.json; every other key is left as it was." >&2
  exit 0
fi

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

# PACKAGE_ROOT locates package-shipped assets (templates/). This script always
# lives at scripts/, one level below the package root, in both layouts:
#   - this monorepo checkout
#   - a consumer install, inside node_modules/@jenga-ai/agent/
# BASH_SOURCE-derived resolution is exact in both cases — no probing needed.
PACKAGE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEMPLATE="$PACKAGE_ROOT/templates/permission-levels/level-${LEVEL}-${NAME}.json"

# REPO_ROOT locates the consumer's own repo — always the destination for
# .claude/settings.json, .agents/settings.json, and .jenga-permission-level.json,
# never node_modules/. Guarded against a non-git directory (set -euo pipefail
# would otherwise abort on git's raw stderr) following the existing pattern in
# scripts/check-public-playbook-steps.sh.
REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
if [[ ! -d "$REPO_ROOT" ]]; then
  echo "Error: could not resolve a repository root (not a git repository and pwd is unusable): $REPO_ROOT" >&2
  exit 2
fi
CLAUDE_SETTINGS="$REPO_ROOT/.claude/settings.json"
AGENTS_SETTINGS="$REPO_ROOT/.agents/settings.json"
LEVEL_FILE="$REPO_ROOT/.jenga-permission-level.json"

if [[ ! -f "$TEMPLATE" ]]; then
  echo "Error: template file not found for level $LEVEL. Searched: $TEMPLATE (resolved from PACKAGE_ROOT: $PACKAGE_ROOT)" >&2
  exit 2
fi

# Key-level merge of the owned keys into dest via temp-file + atomic rename.
merge_template() {
  local dest="$1"
  local tmp="${dest}.tmp"
  local base='{}'
  if [[ -e "$dest" ]]; then
    base="$(cat "$dest")" || return 1
    if ! printf '%s' "$base" | jq -e 'type == "object"' >/dev/null 2>&1; then
      echo "Error: $dest is not a valid JSON object; leaving it unchanged." >&2
      return 1
    fi
  fi
  mkdir -p "$(dirname "$dest")"
  printf '%s' "$base" | jq --slurpfile tpl "$TEMPLATE" --argjson owned "$OWNED_KEYS" '
    . as $dest | $tpl[0] as $t
    | reduce $owned[] as $p ($dest;
        if ($t | try getpath($p) catch null) != null
        then setpath($p; $t | getpath($p))
        else delpaths([$p]) end)' > "$tmp" && mv "$tmp" "$dest"
}

# True when dest registers a PreToolUse hook that runs on_preflight_check.sh.
has_preflight_hook() {
  jq -e '[.hooks.PreToolUse[]?.hooks[]?.command? | strings | contains("hooks/on_preflight_check.sh")] | any' "$1" >/dev/null 2>&1
}

if ! merge_template "$CLAUDE_SETTINGS"; then
  echo "Error: failed to merge the level policy into $CLAUDE_SETTINGS. No files changed." >&2
  rm -f "${CLAUDE_SETTINGS}.tmp"
  exit 3
fi

if ! merge_template "$AGENTS_SETTINGS"; then
  echo "Error: failed to merge the level policy into $AGENTS_SETTINGS." >&2
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
for f in "$CLAUDE_SETTINGS" "$AGENTS_SETTINGS"; do
  if ! has_preflight_hook "$f"; then
    echo "Note: $f has no PreToolUse entry for hooks/on_preflight_check.sh, so the pre-flight backstop is not registered; run 'npx jenga sync' to register it." >&2
  fi
done
exit 0
