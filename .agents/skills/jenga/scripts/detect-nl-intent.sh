#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# skills/jenga/scripts/detect-nl-intent.sh
#
# Deterministic classification wrapper around `resolve-id.sh` for `/jenga`'s
# Phase 0.75 entry-mode resolution (E53_S01). Phase 0.75's scoped branch used
# to call `resolve-id.sh` directly and halt the whole invocation the moment
# ANY comma-delimited segment was rejected by the ID grammar. E53_S01 adds a
# new outcome: when EVERY segment is rejected, the raw argument is not a
# malformed ID list at all — it's natural-language intent, which should be
# routed to /jenga's new NL branch (wired up in E53_S01_T03) instead of
# halting.
#
# This script performs exactly that classification and nothing else. Per
# CLAUDE.md's "Skill Implementation Principle — Scripts Over Inline Logic",
# `skills/jenga/SKILL.md` never parses `resolve-id.sh`'s raw JSON array
# itself for this decision — it only ever reads this script's three output
# shapes below.
#
# ---------------------------------------------------------------------------
# USAGE
# ---------------------------------------------------------------------------
#   skills/jenga/scripts/detect-nl-intent.sh "<raw Phase 0.75 argument>"
#
# The argument is passed through verbatim to `resolve-id.sh` — this script
# does not itself split, clean, or reinterpret it. See `resolve-id.sh`'s own
# header for the exact ID grammar and its per-segment output schema.
#
# ---------------------------------------------------------------------------
# CLASSIFICATION CONTRACT (stable — E53_S01_T03 wires against this exactly)
# ---------------------------------------------------------------------------
# `resolve-id.sh`'s JSON array (one object per comma-delimited segment) is
# reduced to exactly ONE of three classifications, based on the distinct set
# of `status` values across all segments:
#
#   1. every segment "resolved"  -> "all_resolved"
#   2. every segment "rejected"  -> "nl_intent"
#   3. a mix of both             -> "mixed"
#
# stdout is always a single JSON object. Nothing else is ever written to
# stdout — errors and warnings go to stderr only.
#
#   "all_resolved":
#     {
#       "classification":   "all_resolved",
#       "resolved_ids":     ["E01_S02", ...],
#       "resolved_ids_csv": "E01_S02,..."
#     }
#     exit 0 — the existing scoped-branch confirmation flow in
#     `skills/jenga/SKILL.md` is unaffected by this script's introduction.
#
#   "nl_intent":
#     {
#       "classification": "nl_intent",
#       "raw_argument":   "<the original $1, verbatim>"
#     }
#     exit 0 — this is the signal E53_S01_T03's new branch uses to enter
#     natural-language matching instead of halting.
#
#   "mixed":
#     {
#       "classification": "mixed",
#       "rejected": [
#         {"input": "<raw segment>", "reason": "<human-readable reason>"},
#         ...
#       ]
#     }
#     exit 1 — preserves the exact current halt-and-report behavior already
#     documented in `skills/jenga/SKILL.md`'s "`resolve-id.sh` rejects one or
#     more segments" edge case. No partial scope is ever assembled from the
#     segments that did resolve.
#
# ---------------------------------------------------------------------------
# EXIT CODES
# ---------------------------------------------------------------------------
#   0   "all_resolved" or "nl_intent" classification (see above)
#   1   "mixed" classification (see above)
#   2   usage error (no argument given) or a `resolve-id.sh` / `board-scan.sh`
#       setup failure — a real setup problem, not a classification outcome.
#       `resolve-id.sh`'s own stderr message (already emitted by it) is what
#       explains the failure; this script does not re-emit a second message
#       on top of it.
#
# ---------------------------------------------------------------------------

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RESOLVE_ID="$SCRIPT_DIR/resolve-id.sh"

if [ $# -lt 1 ] || [ -z "${1:-}" ]; then
  echo 'Usage: detect-nl-intent.sh "<raw Phase 0.75 argument>"' >&2
  exit 2
fi

RAW_INPUT="$1"

if [ ! -x "$RESOLVE_ID" ]; then
  echo "Error: resolve-id.sh not found or not executable at $RESOLVE_ID" >&2
  exit 2
fi

if ! command -v python3 >/dev/null 2>&1; then
  echo "Error: python3 is required by detect-nl-intent.sh" >&2
  exit 2
fi

# resolve-id.sh exits 0 (all resolved) or 1 (at least one rejected) as
# legitimate per-segment outcomes — only exit 2 (usage/setup failure) is a
# real problem here. Guard the capture explicitly so `set -e` doesn't abort
# this script on resolve-id.sh's own exit 1.
set +e
RESOLVE_JSON="$("$RESOLVE_ID" "$RAW_INPUT")"
RESOLVE_EXIT=$?
set -e

if [ "$RESOLVE_EXIT" -eq 2 ]; then
  # resolve-id.sh already wrote a plain-text error to stderr — just
  # propagate its exit code rather than re-deriving a second message.
  exit 2
fi

PY_SCRIPT="$(mktemp -t detect-nl-intent-XXXXXX.py)"
trap 'rm -f "$PY_SCRIPT"' EXIT

cat > "$PY_SCRIPT" <<'PY'
import json
import sys

raw_argument = sys.argv[1]
resolve_json = sys.stdin.read()

try:
    segments = json.loads(resolve_json)
except Exception as e:
    print(f"Error: could not parse resolve-id.sh output as JSON: {e}", file=sys.stderr)
    sys.exit(2)

if not isinstance(segments, list) or len(segments) == 0:
    # resolve-id.sh only emits [] for an empty/whitespace-only argument,
    # which should never reach this script — Phase 0.75 routes an empty
    # argument to the bare branch before detect-nl-intent.sh is ever
    # invoked. Treat this as a setup problem rather than silently guessing
    # a classification for input this script was never meant to see.
    print("Error: resolve-id.sh produced an empty or non-array result", file=sys.stderr)
    sys.exit(2)

statuses = {seg.get("status") for seg in segments}

if statuses == {"resolved"}:
    resolved_ids = [seg["resolved_id"] for seg in segments]
    print(json.dumps({
        "classification": "all_resolved",
        "resolved_ids": resolved_ids,
        "resolved_ids_csv": ",".join(resolved_ids),
    }))
    sys.exit(0)

if statuses == {"rejected"}:
    print(json.dumps({
        "classification": "nl_intent",
        "raw_argument": raw_argument,
    }))
    sys.exit(0)

rejected = [
    {"input": seg.get("input"), "reason": seg.get("reason")}
    for seg in segments
    if seg.get("status") == "rejected"
]
print(json.dumps({
    "classification": "mixed",
    "rejected": rejected,
}))
sys.exit(1)
PY

python3 "$PY_SCRIPT" "$RAW_INPUT" <<< "$RESOLVE_JSON"
exit $?
