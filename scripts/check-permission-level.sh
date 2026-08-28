#!/usr/bin/env bash
#
# check-permission-level.sh — read-only gate for a skill's declared minimum
# permission level (the `minimum_permission_level` SKILL.md frontmatter field,
# see docs/skill-authoring.md).
#
# ============================================================================
# CHECK vs ENFORCE — READ THIS BEFORE WIRING THIS SCRIPT INTO A SKILL
# ============================================================================
# This script is READ-ONLY. It CHECKS the current session's permission level
# against a required minimum and SIGNALS the result. It does NOT:
#   - prompt the user for confirmation
#   - elevate the session level
#   - write to .jenga-permission-level.json, .claude/settings.json, or
#     .agents/settings.json under any code path
#
# The CALLING SKILL's own instructions are responsible for:
#   1. Detecting the `NEEDS_CONFIRMATION` signal (non-zero exit) below.
#   2. Explicitly asking the user to confirm elevation (no silent
#      auto-elevation, ever).
#   3. On confirmation, invoking `jenga-permission-level-switch.sh <minimum-level>`
#      (a sibling script, scripts/jenga-permission-level-switch.sh — task E33_S02_T02) to
#      actually perform the elevation.
#   4. Immediately after the skill's own work completes, resetting the
#      session back to Guarded (2) — typically via `jenga-permission-level-switch.sh 2` as
#      the skill's last step. This reset is NOT automatic and is NOT this
#      script's job.
#
# Usage:
#   scripts/check-permission-level.sh <minimum-level>
#
#   <minimum-level>  Integer 1-5 — the value a calling skill read from its
#                     own `minimum_permission_level` frontmatter field.
#
# Exit codes:
#   0  Current session level already meets <minimum-level>. No output.
#   1  Current session level is below <minimum-level>. Prints:
#        NEEDS_CONFIRMATION: elevate from <current> to <minimum-level>
#   2  Bad usage / invalid argument. Prints an error to stderr.
#
# Current level source:
#   .jenga-permission-level.json at the repo root, field `session_level`
#   (the format `jenga-permission-level-switch.sh`, E33_S02_T02, writes: {"session_level": <n>}).
#   Missing file, unreadable file, malformed JSON, or a missing/non-integer
#   `session_level` field are all treated as level 2 (Guarded), the
#   permanent default — this script never fails merely because the level
#   file is absent or malformed.
# ============================================================================

set -euo pipefail

usage() {
  echo "Usage: $(basename "$0") <minimum-level>" >&2
  echo "  <minimum-level> must be an integer 1-5 (the skill's minimum_permission_level)." >&2
}

if [ "$#" -ne 1 ]; then
  usage
  exit 2
fi

MIN_LEVEL="$1"

case "$MIN_LEVEL" in
  1|2|3|4|5) ;;
  *)
    echo "Error: <minimum-level> must be an integer 1-5, got: '$MIN_LEVEL'" >&2
    usage
    exit 2
    ;;
esac

LEVEL_FILE=".jenga-permission-level.json"
CURRENT_LEVEL=2

if [ -f "$LEVEL_FILE" ]; then
  if command -v python3 >/dev/null 2>&1; then
    PARSED=$(python3 -c "
import json, sys
try:
    with open('$LEVEL_FILE') as f:
        data = json.load(f)
    level = data.get('session_level')
    if isinstance(level, bool) or not isinstance(level, int) or not (1 <= level <= 5):
        raise ValueError('invalid session_level')
    print(level)
except Exception:
    print(2)
" 2>/dev/null || echo 2)
    CURRENT_LEVEL="$PARSED"
  else
    # No python3 available — fall back to a permissive grep-based extraction.
    # Any failure to confidently parse an integer 1-5 falls back to level 2.
    GREPPED=$(grep -o '"session_level"[[:space:]]*:[[:space:]]*[0-9]' "$LEVEL_FILE" 2>/dev/null | grep -o '[0-9]$' | head -n1 || true)
    case "$GREPPED" in
      1|2|3|4|5) CURRENT_LEVEL="$GREPPED" ;;
      *) CURRENT_LEVEL=2 ;;
    esac
  fi
fi

if [ "$CURRENT_LEVEL" -ge "$MIN_LEVEL" ]; then
  exit 0
fi

echo "NEEDS_CONFIRMATION: elevate from $CURRENT_LEVEL to $MIN_LEVEL"
exit 1
