#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# scripts/test-links-refresh-check.sh - the `check` step of the test-links refresh workflow (epic E83, task E83_S04_T03)
#
# A workflow `compute` step has no accepted-exit-codes field: any non-zero exit fails the step and the run
# (scripts/workflow/run-compute.sh). scripts/check-test-links.sh exits 1 on a `stale` verdict BY DESIGN, so calling it
# directly would turn "the links are out of date" (the very case the refresh exists for) into a failed run. This wrapper
# absorbs that: it always exits 0 once it has produced an answer, and the verdict travels in its output instead.
#
# It also snapshots the links file as it is BEFORE the extract step regenerates it, so the later diff step has a
# "previous" to compare with (a compute step keeps no state between steps).
#
# USAGE
#   test-links-refresh-check.sh [--root <dir>]
#   test-links-refresh-check.sh -h | --help      print this usage on stdout, exit 0
#   --root <dir>   the repository root to check; default: what scripts/check-test-links.sh defaults to.
#
# STDOUT is ONE JSON object with exactly the three keys the workflow declares as the step's outputs:
#   status     `fresh`, `stale`, or `error` (the checker could not give a verdict: exit 2, e.g. an invalid links file)
#   reasons    one line per reason, `<type>: key=value, ...`, or `none`; for `error` the checker's message
#   snapshot   path of a temporary copy of the links file taken now, or `none` when there is no links file yet.
#              The diff step (test-links-refresh-diff.sh) reads it and deletes it.
#
# EXIT CODES
#   0  an answer was printed (whatever the verdict)
#   2  usage error, or jq is missing / the checker script is absent (nothing printed on stdout)
# Compatible with macOS bash 3.2; needs jq.
# ---------------------------------------------------------------------------
set -u

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHECK="$SELF_DIR/check-test-links.sh"

die2() { printf 'test-links-refresh-check.sh: %s\n' "$*" >&2; exit 2; }

ROOT=""
case "${1:-}" in
  -h|--help) sed -n '2,/^# ----*$/p' "$0" | sed -n '2,$p' | sed 's/^# \{0,1\}//' | sed '$d'; exit 0 ;;
  "") ;;
  --root) [ $# -eq 2 ] || die2 "--root needs a value"; ROOT="$2" ;;
  --root=*) [ $# -eq 1 ] || die2 "unexpected argument"; ROOT="${1#--root=}" ;;
  *) die2 "unknown argument: $1" ;;
esac

command -v jq >/dev/null 2>&1 || die2 "jq is required"
[ -f "$CHECK" ] || die2 "scripts/check-test-links.sh is absent"

ARGS=(--json)
if [ -n "$ROOT" ]; then
  ARGS=(--root "$ROOT" --json)
  TREE="$(cd "$ROOT" && env -u JENGA_PROJECT_ROOT "$SELF_DIR/resolve-root.sh" tree 2>/dev/null)" || TREE="project"
  LINKS="$ROOT/$TREE/knowledge-graph/test-links.json"
else
  R="$("$SELF_DIR/resolve-root.sh" root 2>/dev/null)" || die2 "cannot resolve the project root"
  T="$("$SELF_DIR/resolve-root.sh" tree 2>/dev/null)" || die2 "cannot resolve the project tree"
  LINKS="$R/$T/knowledge-graph/test-links.json"
fi

SNAP="none"
if [ -f "$LINKS" ]; then
  SNAP="$(mktemp "${TMPDIR:-/tmp}/test-links-previous.XXXXXX")" || die2 "cannot create a snapshot file"
  cp "$LINKS" "$SNAP" || { rm -f "$SNAP"; die2 "cannot snapshot the links file"; }
fi

ERRF="$(mktemp "${TMPDIR:-/tmp}/test-links-check-err.XXXXXX")" || die2 "cannot create a temp file"
OUT="$(bash "$CHECK" "${ARGS[@]}" 2>"$ERRF")"
RC=$?
ERR="$(cat "$ERRF")"; rm -f "$ERRF"

if [ "$RC" -eq 0 ] || [ "$RC" -eq 1 ]; then
  if printf '%s' "$OUT" | jq -e '.status' >/dev/null 2>&1; then
    printf '%s' "$OUT" | jq -c --arg snap "$SNAP" '{
      status: .status,
      reasons: (if (.reasons | length) == 0 then "none"
                else (.reasons | map(.type + ": " + (del(.type) | to_entries | map("\(.key)=\(.value)") | join(", "))) | join("\n")) end),
      snapshot: $snap }'
    exit 0
  fi
fi
[ -n "$ERR" ] || ERR="check-test-links.sh exited $RC without a verdict"
jq -cn --arg reasons "$ERR" --arg snap "$SNAP" '{status: "error", reasons: $reasons, snapshot: $snap}'
exit 0
