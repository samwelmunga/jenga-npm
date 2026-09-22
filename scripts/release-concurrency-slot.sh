#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# scripts/release-concurrency-slot.sh
#
# Release a role-scoped concurrency slot previously acquired via
# scripts/acquire-concurrency-slot.sh, for E32_S15 (Per-Session Concurrency
# Cap for Developer/Tester Dispatch). Removes the caller's holder entry from
# project/queue/concurrency-slots-<session_id>.json, unconditionally and
# idempotently — mirroring scripts/with-lock.sh's own idempotent-cleanup
# discipline (no error if the counter file, the role, or the holder entry is
# already absent).
#
# The counter file belongs to exactly the session_id in its own filename.
# This script never reads or writes a counter file for any session_id other
# than the one passed as its own argument.
#
# Usage:
#   scripts/release-concurrency-slot.sh <role> <holder-id> <session_id>
#
# Exit codes:
#   0  released (or already absent — idempotent no-op is still success)
#   1  usage error (bad arguments)
#   2  scripts/with-lock.sh could not acquire the lock within its timeout
#   5  environment error (jq missing)
# ---------------------------------------------------------------------------

set -euo pipefail

SELF="$(basename "$0")"

die() {
  local code="$1"; shift
  printf '%s: error: %s\n' "$SELF" "$*" >&2
  exit "$code"
}

usage() {
  echo "Usage: $0 <role> <holder-id> <session_id>" >&2
  exit 1
}

# Mirrors scripts/acquire-concurrency-slot.sh's own project-root resolution
# (and scripts/write-context-digest.sh's before it) for consistency.
resolve_project_dir() {
  if [ -n "${JENGA_PROJECT_DIR:-}" ]; then
    printf '%s\n' "$JENGA_PROJECT_DIR"
    return 0
  fi
  if [ -n "${CLAUDE_PROJECT_DIR:-}" ]; then
    printf '%s\n' "$CLAUDE_PROJECT_DIR"
    return 0
  fi
  git rev-parse --show-toplevel 2>/dev/null || pwd
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_ABS_PATH="$SCRIPT_DIR/$(basename "${BASH_SOURCE[0]}")"

# ---------------------------------------------------------------------------
# Resolve with-lock.sh.
#
# scripts/postinstall.js mirrors only skills/ and agents/ into a consumer's
# .claude/ and .agents/ — scripts/ (which owns with-lock.sh) is never copied
# there, so a consumer install has no <consumer>/scripts/with-lock.sh at all.
# Probing "$PROJECT_DIR/scripts/with-lock.sh" alone therefore hard-fails every
# consumer install, even though the file ships fine inside the package.
#
# The sibling probe is what fixes that: with-lock.sh always lands in the same
# directory as this script, in a monorepo checkout AND inside the installed
# npm package. The remaining two tiers mirror the three-tier shape already
# used by skills/j-uncharted/scripts/elicitation-state.sh.
# ---------------------------------------------------------------------------
resolve_with_lock() {
  local candidate
  for candidate in \
    "$SCRIPT_DIR/with-lock.sh" \
    "$PROJECT_DIR/scripts/with-lock.sh" \
    "$PROJECT_DIR/node_modules/@jenga-ai/agent/scripts/with-lock.sh"
  do
    if [ -f "$candidate" ]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done
  return 1
}

# ---------------------------------------------------------------------------
# Internal locked-mutation entrypoint. Not intended to be invoked directly —
# scripts/with-lock.sh calls back into this same script with this hidden
# subcommand once the lock on the counter file is held.
# ---------------------------------------------------------------------------
if [ "${1:-}" = "__locked-release" ]; then
  shift
  ROLE="$1"
  HOLDER_ID="$2"
  COUNTER_FILE="$3"

  command -v jq >/dev/null 2>&1 || die 5 "jq is required but not found on PATH"

  # Race: the file may have been removed between the outer existence check
  # and actually acquiring the lock. That's still a no-op success, not an
  # error — release is idempotent by contract.
  [ -f "$COUNTER_FILE" ] || exit 0

  TMP_FILE="$(mktemp "${COUNTER_FILE}.tmp.XXXXXX")"
  jq \
    --arg role "$ROLE" \
    --arg holder "$HOLDER_ID" \
    '
    if has($role) then
      .[$role].holders |= ((. // {}) | del(.[$holder]))
    else
      .
    end
    ' "$COUNTER_FILE" > "$TMP_FILE"
  mv "$TMP_FILE" "$COUNTER_FILE"
  exit 0
fi

# ---------------------------------------------------------------------------
# Public entrypoint
# ---------------------------------------------------------------------------
[ "$#" -eq 3 ] || usage

ROLE="$1"
HOLDER_ID="$2"
SESSION_ID="$3"

case "$ROLE" in
  developer|tester) ;;
  *) die 1 "invalid role '$ROLE' (expected developer or tester)" ;;
esac

[ -n "$HOLDER_ID" ] || die 1 "<holder-id> must not be empty"
[ -n "$SESSION_ID" ] || die 1 "<session_id> must not be empty"

case "$SESSION_ID" in
  */*|*..*) die 1 "invalid <session_id> '$SESSION_ID': must not contain '/' or '..'" ;;
esac

PROJECT_DIR="$(resolve_project_dir)"
COUNTER_FILE="$PROJECT_DIR/project/queue/concurrency-slots-${SESSION_ID}.json"

command -v jq >/dev/null 2>&1 || die 5 "jq is required but not found on PATH"
WITH_LOCK="$(resolve_with_lock)" \
  || die 5 "with-lock.sh not found (looked in $SCRIPT_DIR, $PROJECT_DIR/scripts, and $PROJECT_DIR/node_modules/@jenga-ai/agent/scripts)"

# No counter file at all yet: nothing to release, idempotent no-op, no lock
# needed.
[ -f "$COUNTER_FILE" ] || exit 0

set +e
"$WITH_LOCK" "$COUNTER_FILE" -- \
  "$SCRIPT_ABS_PATH" __locked-release "$ROLE" "$HOLDER_ID" "$COUNTER_FILE"
STATUS=$?
set -e

exit "$STATUS"
