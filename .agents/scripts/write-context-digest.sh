#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# scripts/write-context-digest.sh
#
# Write helper for the resolved_context digest handoff convention (E49_S01).
# A sending agent (scrum-master dispatching to developer, developer
# dispatching to tester) calls this to persist a short digest of context it
# has already resolved, so the receiving subagent doesn't have to cold-re-read
# the same source documents. The receiving agent's sender object then carries
# a reference to (or holds) the resulting file path in its `resolved_context`
# field — see templates/SCRUM_BOARD_SCHEMA.md's resolved_context subsection.
#
# Physical convention (already documented by E49_S01_T01, implemented here):
#   project/queue/context/<agent>-<session_id>-<task_id>.json
# — the exact same filename shape as project/queue/handoffs/, for the same
# reason: <session_id> alone is already collision-free (each session has a
# unique id and writes its digest at most once per task), <task_id> is
# appended for human debuggability.
#
# Size-cap discipline: templates/SCRUM_BOARD_SCHEMA.md documents a ~100-line
# / few-hundred-token cap on resolved_context — "a digest, not a dump". This
# script REJECTS (does not truncate) content over the cap. Truncating would
# silently cut a digest off mid-thought and could mislead the receiver into
# treating a partial thought as complete; a loud, immediate failure lets the
# sender shorten the digest itself, which is the only party that actually
# knows what's safe to cut.
#
# Usage:
#   write-context-digest.sh --agent <agent> --session-id <id> --task-id <id>
#                            [--content <text> | --content-file <path>]
#                            [--max-lines <n>]
#   <producer> | write-context-digest.sh --agent <agent> --session-id <id> --task-id <id>
#
# If neither --content nor --content-file is given, digest content is read
# from stdin (mirrors skills/uncharted/scripts/import-source.sh's snippet
# convention).
#
# Options:
#   --agent <agent>         scrum-master | developer | tester (required)
#   --session-id <id>       writing session's id, verbatim (required)
#   --task-id <id>          primary task ID this digest concerns (required)
#   --content <text>        digest content inline
#   --content-file <path>   digest content read from this file
#   --max-lines <n>         override the default 100-line cap
#                            (env: WRITE_CONTEXT_DIGEST_MAX_LINES)
#   --queue-dir <dir>       override project/queue (default: resolved via
#                            JENGA_PROJECT_DIR / git toplevel)
#   -h, --help              show this help
#
# Output (stdout):
#   <absolute path to the written digest file>   (only line printed on success)
#
# Exit codes:
#   0  digest written
#   1  usage error (missing/invalid flag)
#   2  environment error (jq unavailable, cannot create project/queue/context)
#   3  empty digest content
#   4  digest exceeds the line cap (rejected, not truncated)
#   5  write failed (atomic rename step)
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

command -v jq >/dev/null 2>&1 || die 2 "jq is required but not found on PATH"

# ---------------------------------------------------------------------------
# Resolve project root (mirrors lib/resolve-project-dir.sh's own probing
# order without requiring callers to source it, since this script must also
# work standalone from a plain shell during manual verification).
# ---------------------------------------------------------------------------
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

AGENT=""
SESSION_ID=""
TASK_ID=""
CONTENT=""
CONTENT_SET=0
CONTENT_FILE=""
MAX_LINES="${WRITE_CONTEXT_DIGEST_MAX_LINES:-100}"
QUEUE_DIR=""

while [ "$#" -gt 0 ]; do
  case "$1" in
    --agent)
      [ "$#" -ge 2 ] || die 1 "--agent requires a value"
      AGENT="$2"; shift 2 ;;
    --agent=*)
      AGENT="${1#--agent=}"; shift ;;
    --session-id)
      [ "$#" -ge 2 ] || die 1 "--session-id requires a value"
      SESSION_ID="$2"; shift 2 ;;
    --session-id=*)
      SESSION_ID="${1#--session-id=}"; shift ;;
    --task-id)
      [ "$#" -ge 2 ] || die 1 "--task-id requires a value"
      TASK_ID="$2"; shift 2 ;;
    --task-id=*)
      TASK_ID="${1#--task-id=}"; shift ;;
    --content)
      [ "$#" -ge 2 ] || die 1 "--content requires a value"
      CONTENT="$2"; CONTENT_SET=1; shift 2 ;;
    --content=*)
      CONTENT="${1#--content=}"; CONTENT_SET=1; shift ;;
    --content-file)
      [ "$#" -ge 2 ] || die 1 "--content-file requires a value"
      CONTENT_FILE="$2"; shift 2 ;;
    --content-file=*)
      CONTENT_FILE="${1#--content-file=}"; shift ;;
    --max-lines)
      [ "$#" -ge 2 ] || die 1 "--max-lines requires a value"
      MAX_LINES="$2"; shift 2 ;;
    --max-lines=*)
      MAX_LINES="${1#--max-lines=}"; shift ;;
    --queue-dir)
      [ "$#" -ge 2 ] || die 1 "--queue-dir requires a value"
      QUEUE_DIR="$2"; shift 2 ;;
    --queue-dir=*)
      QUEUE_DIR="${1#--queue-dir=}"; shift ;;
    -h|--help)
      usage ;;
    *)
      die 1 "unknown argument: $1" ;;
  esac
done

[ -n "$AGENT" ] || die 1 "--agent is required"
case "$AGENT" in
  scrum-master|developer|tester) ;;
  *) die 1 "invalid --agent '$AGENT' (expected scrum-master, developer, or tester)" ;;
esac
[ -n "$SESSION_ID" ] || die 1 "--session-id is required"
[ -n "$TASK_ID" ] || die 1 "--task-id is required"

case "$MAX_LINES" in
  ''|*[!0-9]*) die 1 "--max-lines must be a positive integer, got '$MAX_LINES'" ;;
esac
[ "$MAX_LINES" -gt 0 ] || die 1 "--max-lines must be a positive integer, got '$MAX_LINES'"

# Session id / task id are used verbatim in a filename below — refuse path
# separators or traversal rather than silently mangling or escaping them.
case "$SESSION_ID" in
  */*|*..*) die 1 "invalid --session-id '$SESSION_ID': must not contain '/' or '..'" ;;
esac
case "$TASK_ID" in
  */*|*..*) die 1 "invalid --task-id '$TASK_ID': must not contain '/' or '..'" ;;
esac

# ---------------------------------------------------------------------------
# Resolve digest content: --content, then --content-file, then stdin.
# ---------------------------------------------------------------------------
if [ -n "$CONTENT_FILE" ]; then
  [ "$CONTENT_SET" -eq 0 ] || die 1 "--content and --content-file are mutually exclusive"
  [ -f "$CONTENT_FILE" ] || die 1 "--content-file '$CONTENT_FILE' does not exist"
  CONTENT="$(cat "$CONTENT_FILE")"
  CONTENT_SET=1
fi

if [ "$CONTENT_SET" -eq 0 ]; then
  CONTENT="$(cat)"
fi

[ -n "$CONTENT" ] || die 3 "digest content is empty — nothing to write"

LINE_COUNT=$(printf '%s\n' "$CONTENT" | wc -l | tr -d ' ')
if [ "$LINE_COUNT" -gt "$MAX_LINES" ]; then
  die 4 "digest is $LINE_COUNT lines, exceeding the $MAX_LINES-line cap documented in templates/SCRUM_BOARD_SCHEMA.md's resolved_context subsection (\"a digest, not a dump\") — shorten it rather than raising --max-lines/WRITE_CONTEXT_DIGEST_MAX_LINES, which exists for genuine exceptions only"
fi

# ---------------------------------------------------------------------------
# Resolve destination and write atomically.
# ---------------------------------------------------------------------------
PROJECT_DIR="$(resolve_project_dir)"
[ -n "$QUEUE_DIR" ] || QUEUE_DIR="$PROJECT_DIR/project/queue"
CONTEXT_DIR="$QUEUE_DIR/context"

mkdir -p "$CONTEXT_DIR" 2>/dev/null || die 2 "could not create $CONTEXT_DIR"

DEST_FILE="$CONTEXT_DIR/${AGENT}-${SESSION_ID}-${TASK_ID}.json"
TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

TMP_FILE=$(mktemp "$CONTEXT_DIR/.digest_tmp.XXXXXX") || die 5 "could not create temp file in $CONTEXT_DIR"

if ! jq -n \
  --arg agent "$AGENT" \
  --arg session_id "$SESSION_ID" \
  --arg task_id "$TASK_ID" \
  --arg date "$TIMESTAMP" \
  --arg digest "$CONTENT" \
  --argjson line_count "$LINE_COUNT" \
  '{
    agent: $agent,
    session_id: $session_id,
    task_id: $task_id,
    date: $date,
    line_count: $line_count,
    digest: $digest
  }' > "$TMP_FILE"; then
  rm -f "$TMP_FILE"
  die 5 "failed to build digest JSON"
fi

if ! mv "$TMP_FILE" "$DEST_FILE"; then
  rm -f "$TMP_FILE"
  die 5 "failed to move temp file into place at $DEST_FILE"
fi

printf '%s\n' "$DEST_FILE"
