#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# scripts/sweep-stale-context-digests.sh
#
# Staleness-cleanup backstop for project/queue/context/ digest files
# (E49_S01_T02). The PRIMARY cleanup path is scripts/consume-context-digest.sh,
# called by the receiving subagent once it has read its digest. This script
# exists for the cases that leaves uncovered:
#   - a digest whose intended receiving session never starts (e.g. the
#     dispatch it was written for was abandoned or superseded)
#   - a receiver that reads the raw file directly instead of going through
#     consume-context-digest.sh and forgets to delete it
#
# Invoked from hooks/on_session_end.sh on every session end (any agent), so
# it runs far more often than any single digest's realistic lifetime — a
# digest is meant to be consumed by the very next session dispatched for its
# task, not to sit for a full day. Age-based (mtime), not consumption-based:
# unlike project/queue/handoffs/ (routed and deleted deterministically, same
# hook invocation, by on_session_end.sh section 4), a digest's consumer is a
# LATER session that hasn't necessarily started yet when an unrelated
# session's SessionEnd hook fires — so this sweep must not delete a digest
# just because some other session ended in the meantime. The default
# threshold (24h) is deliberately generous for that reason.
#
# Usage:
#   sweep-stale-context-digests.sh [--context-dir <dir>] [--max-age-seconds <n>]
#
# Options:
#   --context-dir <dir>       override project/queue/context (default:
#                             resolved via JENGA_PROJECT_DIR / git toplevel)
#   --max-age-seconds <n>     override the default 86400s (24h) threshold
#                             (env: CONTEXT_DIGEST_STALE_SECONDS)
#   -h, --help
#
# Output (stdout): one line per file removed: "removed: <path> (age <n>s)"
#
# Exit codes:
#   0  ran successfully (including the common case of nothing to remove)
#   1  usage error
# ---------------------------------------------------------------------------

set -u

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

CONTEXT_DIR=""
MAX_AGE_SECONDS="${CONTEXT_DIGEST_STALE_SECONDS:-86400}"

while [ "$#" -gt 0 ]; do
  case "$1" in
    --context-dir)
      [ "$#" -ge 2 ] || die 1 "--context-dir requires a value"
      CONTEXT_DIR="$2"; shift 2 ;;
    --context-dir=*)
      CONTEXT_DIR="${1#--context-dir=}"; shift ;;
    --max-age-seconds)
      [ "$#" -ge 2 ] || die 1 "--max-age-seconds requires a value"
      MAX_AGE_SECONDS="$2"; shift 2 ;;
    --max-age-seconds=*)
      MAX_AGE_SECONDS="${1#--max-age-seconds=}"; shift ;;
    -h|--help)
      usage ;;
    *)
      die 1 "unknown argument: $1" ;;
  esac
done

case "$MAX_AGE_SECONDS" in
  ''|*[!0-9]*) die 1 "--max-age-seconds must be a non-negative integer, got '$MAX_AGE_SECONDS'" ;;
esac

if [ -z "$CONTEXT_DIR" ]; then
  PROJECT_DIR="$(resolve_project_dir)"
  CONTEXT_DIR="$PROJECT_DIR/project/queue/context"
fi

[ -d "$CONTEXT_DIR" ] || exit 0

# Portable mtime lookup: GNU stat (Linux) uses -c, BSD stat (macOS) uses -f —
# same fallback pattern as scripts/with-lock.sh's lock_mtime_epoch().
file_mtime_epoch() {
  stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null
}

now_epoch() {
  date +%s
}

NOW="$(now_epoch)"

for FILE in "$CONTEXT_DIR"/*.json; do
  [ -e "$FILE" ] || continue
  # Never sweep a file mid-claim by consume-context-digest.sh — that script
  # renames its target to a .claimed.$$ sibling before reading it, and this
  # glob (*.json) doesn't match that suffix, so in-flight claims are already
  # excluded structurally. This comment documents that rather than adding a
  # redundant runtime check.

  MTIME="$(file_mtime_epoch "$FILE")" || continue
  AGE=$(( NOW - MTIME ))

  if [ "$AGE" -ge "$MAX_AGE_SECONDS" ]; then
    if rm -f "$FILE" 2>/dev/null; then
      echo "removed: $FILE (age ${AGE}s)"
    fi
  fi
done

exit 0
