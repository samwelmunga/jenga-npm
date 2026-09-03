#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# scripts/consume-context-digest.sh
#
# Read-and-delete helper for the resolved_context digest handoff convention
# (E49_S01). The receiving subagent (the one whose sender object carries a
# resolved_context / resolved_context_path pointing at a file under
# project/queue/context/) calls this once, as part of reading its own sender
# object, to fetch the digest content and immediately mark the file consumed
# — mirroring project/queue/handoffs/'s single-use lifecycle rather than
# leaving cleanup to a convention every receiver has to remember to follow.
#
# Atomic claim: before reading, the target file is renamed to a
# `.claimed.$$` sibling in the same directory (same TOCTOU-safe pattern
# hooks/on_session_end.sh section 4 already uses when routing
# project/queue/handoffs/ files). `mv` between two paths on the same
# filesystem is a rename(2) syscall — the kernel guarantees exactly one
# concurrent claimer wins. If the rename fails, another process already
# consumed (or is consuming) this file; this invocation exits 3 without
# printing anything, rather than risking a double-read of a file that's
# about to disappear out from under it.
#
# This script does NOT sweep for abandoned digests nobody ever consumes —
# that backstop is scripts/sweep-stale-context-digests.sh, invoked from
# hooks/on_session_end.sh.
#
# Usage:
#   consume-context-digest.sh <path-to-digest-file>
#   consume-context-digest.sh --raw <path-to-digest-file>
#
# Options:
#   --raw    print only the digest field's text (not the full JSON envelope)
#   -h, --help
#
# Output (stdout):
#   the digest file's full JSON envelope (default), or just its `digest`
#   field's text with --raw
#
# Exit codes:
#   0  digest read and file deleted
#   1  usage error
#   2  target file does not exist (already consumed, or never written)
#   3  target file was claimed by a concurrent consumer first
#   4  target file is not valid JSON / missing expected fields
# ---------------------------------------------------------------------------

set -euo pipefail

SELF="$(basename "$0")"

die() {
  local code="$1"; shift
  printf '%s: error: %s\n' "$SELF" "$*" >&2
  exit "$code"
}

usage() {
  sed -n '/^# Usage:/,/^# Exit codes:/p' "$0" | sed 's/^# \{0,1\}//' >&2
  exit 1
}

command -v jq >/dev/null 2>&1 || die 1 "jq is required but not found on PATH"

RAW=0
TARGET=""

while [ "$#" -gt 0 ]; do
  case "$1" in
    --raw)
      RAW=1; shift ;;
    -h|--help)
      usage ;;
    -*)
      die 1 "unknown option: $1" ;;
    *)
      [ -z "$TARGET" ] || die 1 "unexpected extra argument: $1"
      TARGET="$1"; shift ;;
  esac
done

[ -n "$TARGET" ] || usage
[ -f "$TARGET" ] || die 2 "digest file not found: $TARGET (already consumed, or never written)"

CLAIMED_FILE="${TARGET}.claimed.$$"
if ! mv "$TARGET" "$CLAIMED_FILE" 2>/dev/null; then
  die 3 "digest file '$TARGET' was claimed by a concurrent consumer — skipping"
fi

# Always attempt to remove the claimed temp file, whether jq succeeds or not,
# so a malformed digest can't leave a permanent orphan behind.
cleanup() {
  rm -f "$CLAIMED_FILE" 2>/dev/null || true
}
trap cleanup EXIT

if [ "$RAW" -eq 1 ]; then
  DIGEST_TEXT=$(jq -r '.digest // empty' "$CLAIMED_FILE" 2>/dev/null) || die 4 "'$TARGET' is not valid digest JSON"
  [ -n "$DIGEST_TEXT" ] || die 4 "'$TARGET' has no 'digest' field"
  printf '%s\n' "$DIGEST_TEXT"
else
  jq -e '.' "$CLAIMED_FILE" >/dev/null 2>&1 || die 4 "'$TARGET' is not valid JSON"
  cat "$CLAIMED_FILE"
fi
