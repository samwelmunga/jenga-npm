#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# scripts/acquire-concurrency-slot.sh
#
# Acquire a role-scoped concurrency slot against a single orchestrating
# session's counter file, for E32_S15 (Per-Session Concurrency Cap for
# Developer/Tester Dispatch). Generalizes the existing per-epic boolean
# bundle lock ("Epic-Level Bundle Lock" in skills/do/SKILL.md) into a
# per-role bounded counter with multiple named holders.
#
# The counter file lives at:
#   project/queue/concurrency-slots-<session_id>.json
# and has the shape:
#   {
#     "developer": {"cap": <int>, "holders": {"<holder-id>": "<ISO ts>"}},
#     "tester":    {"cap": <int>, "holders": {"<holder-id>": "<ISO ts>"}}
#   }
#
# The counter file belongs to exactly the session_id in its own filename.
# This script never reads or writes a counter file for any session_id other
# than the one passed as its own argument.
#
# Behavior:
#   1. Before the cap check, any holder entry in the target role's holders
#      map older than slot_ttl_minutes (project/configs/scope-thresholds.json)
#      is dropped ("stale reclaim") — guards against a crashed subagent
#      leaking its slot within THIS session; not a cross-session mechanism.
#   2. If the role's holder count (after reclaim) is >= its cap, this script
#      exits non-zero and mutates the counter file NOT AT ALL (not even to
#      persist the stale-reclaim result) — a denied acquire is a pure no-op
#      on disk.
#   3. Otherwise a "<holder-id>: <current ISO timestamp>" entry is added
#      under the role and the script exits 0. If the counter file doesn't
#      exist yet, it is created and seeded with both roles' cap values (read
#      fresh from scope-thresholds.json) and empty holders maps.
#
# The whole reclaim + cap-check + mutate sequence runs as ONE atomic critical
# section under a single scripts/with-lock.sh invocation (this script
# re-invokes itself with an internal subcommand as the wrapped command) —
# never as two separate locked calls — so there is no TOCTOU gap between
# checking the cap and writing the new holder entry.
#
# Usage:
#   scripts/acquire-concurrency-slot.sh <role> <holder-id> <session_id>
#
# Exit codes:
#   0  slot acquired — holder entry added (or counter file created + seeded)
#   1  usage error (bad arguments)
#   2  scripts/with-lock.sh could not acquire the lock within its timeout —
#      the acquire attempt never ran, counter file untouched
#   3  role is at/over cap after stale-reclaim — slot NOT acquired, counter
#      file untouched (no mutation, per acceptance criteria)
#   5  environment error (jq missing, scope-thresholds.json missing/invalid,
#      project root unresolvable)
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

# ---------------------------------------------------------------------------
# Resolve project root (mirrors scripts/write-context-digest.sh's own
# probing order: JENGA_PROJECT_DIR -> CLAUDE_PROJECT_DIR -> git toplevel ->
# pwd — kept consistent so this script behaves the same whether invoked
# directly, from a skill, or from another script).
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

# Absolute path to this script itself, so the lock-holding re-invocation
# below works regardless of how this script was originally invoked (a
# relative path, a PATH lookup, etc.) and regardless of cwd.
SCRIPT_ABS_PATH="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"

# ---------------------------------------------------------------------------
# Internal locked-mutation entrypoint. Not intended to be invoked directly —
# scripts/with-lock.sh calls back into this same script with this hidden
# subcommand once (and only once) the lock on the counter file is held. This
# is what makes reclaim + cap-check + mutate a single atomic operation
# instead of two racy locked calls.
# ---------------------------------------------------------------------------
if [ "${1:-}" = "__locked-acquire" ]; then
  shift
  ROLE="$1"
  HOLDER_ID="$2"
  COUNTER_FILE="$3"
  CONFIG_FILE="$4"

  command -v jq >/dev/null 2>&1 || die 5 "jq is required but not found on PATH"
  [ -f "$CONFIG_FILE" ] || die 5 "config file not found: $CONFIG_FILE"

  DEV_CAP="$(jq -r '.max_concurrent_developers // empty' "$CONFIG_FILE")"
  TESTER_CAP="$(jq -r '.max_concurrent_testers // empty' "$CONFIG_FILE")"
  TTL_MINUTES="$(jq -r '.slot_ttl_minutes // empty' "$CONFIG_FILE")"

  case "$DEV_CAP" in ''|*[!0-9]*) die 5 "invalid or missing max_concurrent_developers in $CONFIG_FILE" ;; esac
  case "$TESTER_CAP" in ''|*[!0-9]*) die 5 "invalid or missing max_concurrent_testers in $CONFIG_FILE" ;; esac
  case "$TTL_MINUTES" in ''|*[!0-9]*) die 5 "invalid or missing slot_ttl_minutes in $CONFIG_FILE" ;; esac

  case "$ROLE" in
    developer) CAP="$DEV_CAP" ;;
    tester) CAP="$TESTER_CAP" ;;
    *) die 1 "invalid role '$ROLE' (expected developer or tester)" ;;
  esac

  TTL_SECONDS=$(( TTL_MINUTES * 60 ))
  NOW_EPOCH="$(date -u +%s)"
  NOW_ISO="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"

  # Base document: the existing counter file, or an in-memory seed if the
  # file doesn't exist yet. The seed is NOT written to disk here — it only
  # gets persisted below, and only on a successful acquire.
  if [ -f "$COUNTER_FILE" ]; then
    BASE_JSON="$(cat "$COUNTER_FILE")"
  else
    BASE_JSON="$(jq -n \
      --argjson dev_cap "$DEV_CAP" \
      --argjson tester_cap "$TESTER_CAP" \
      '{developer: {cap: $dev_cap, holders: {}}, tester: {cap: $tester_cap, holders: {}}}')"
  fi

  # Compute the reclaimed+decision document entirely in memory. Nothing is
  # written to $COUNTER_FILE by this jq invocation.
  DECISION_JSON="$(printf '%s' "$BASE_JSON" | jq \
    --arg role "$ROLE" \
    --arg holder "$HOLDER_ID" \
    --arg now_iso "$NOW_ISO" \
    --argjson now_epoch "$NOW_EPOCH" \
    --argjson ttl_seconds "$TTL_SECONDS" \
    --argjson cap "$CAP" \
    '
    # Self-heal the role cap to the freshly-read config value, and drop any
    # stale holder (older than ttl_seconds) before the cap check.
    .[$role].cap = $cap
    | .[$role].holders = ((.[$role].holders // {})
        | with_entries(select((.value | fromdateiso8601) >= ($now_epoch - $ttl_seconds))))
    | (.[$role].holders | length) as $count
    | if $count >= $cap then
        {ok: false, doc: .}
      else
        {ok: true, doc: (.[$role].holders[$holder] = $now_iso)}
      end
    ')"

  OK="$(printf '%s' "$DECISION_JSON" | jq -r '.ok')"

  if [ "$OK" != "true" ]; then
    # At/over cap: exit non-zero, counter file untouched (no write at all).
    exit 3
  fi

  # Success: persist atomically (temp file + rename in the same directory).
  mkdir -p "$(dirname "$COUNTER_FILE")" 2>/dev/null || true
  TMP_FILE="$(mktemp "${COUNTER_FILE}.tmp.XXXXXX")"
  printf '%s' "$DECISION_JSON" | jq '.doc' > "$TMP_FILE"
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

# session_id is used verbatim in a filename below — refuse path separators
# or traversal rather than silently mangling or escaping it (mirrors
# scripts/write-context-digest.sh's own path-safety checks).
case "$SESSION_ID" in
  */*|*..*) die 1 "invalid <session_id> '$SESSION_ID': must not contain '/' or '..'" ;;
esac

PROJECT_DIR="$(resolve_project_dir)"
COUNTER_FILE="$PROJECT_DIR/project/queue/concurrency-slots-${SESSION_ID}.json"
CONFIG_FILE="$PROJECT_DIR/project/configs/scope-thresholds.json"

command -v jq >/dev/null 2>&1 || die 5 "jq is required but not found on PATH"
[ -x "$PROJECT_DIR/scripts/with-lock.sh" ] || [ -f "$PROJECT_DIR/scripts/with-lock.sh" ] \
  || die 5 "scripts/with-lock.sh not found at $PROJECT_DIR/scripts/with-lock.sh"

mkdir -p "$PROJECT_DIR/project/queue" 2>/dev/null || true

set +e
"$PROJECT_DIR/scripts/with-lock.sh" "$COUNTER_FILE" -- \
  "$SCRIPT_ABS_PATH" __locked-acquire "$ROLE" "$HOLDER_ID" "$COUNTER_FILE" "$CONFIG_FILE"
STATUS=$?
set -e

exit "$STATUS"
