#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# st-test-mock-board.sh - a step of the `deploy-stage` workflow: replace the mock board data in the
# ST-Test consumer project with a fresh set, so the board-reading steps that follow (j.dashboard-share,
# j.status, j.status E01) have a board with a known shape to show.
#
# This is a thin wrapper. The generator, the shape it produces and the way it recognises (and so
# removes) mock data from earlier runs all live in the ST-Test project itself, where they are
# documented: see the "Mock board data" section of <st-test-path>/README.md. Read that section, not this
# file, to learn what the data looks like or how to run it by hand:
#
#     <st-test-path>/scripts/mock-board.sh <generate | clean | reset>
#
# This wrapper runs `reset` (remove the mock data of earlier runs, then generate), and nothing else.
# Only items the generator itself wrote are ever removed; ST-Test's real board is never touched.
#
# stdout is a short report (the step's output); the generator's own progress goes to stderr.
#
# Usage: st-test-mock-board.sh <st-test-path>
#
# Exit: 0 the mock board was regenerated; 1 the generator refused (for example a real board item uses
# an id the mock data needs); 2 setup error (no consumer directory, or no generator script in it).
# ---------------------------------------------------------------------------
set -uo pipefail

ST_PATH="${1:-}"

die() { printf 'st-test-mock-board: %s\n' "$1" >&2; exit "${2:-2}"; }

[ -n "$ST_PATH" ] || die "usage: st-test-mock-board.sh <st-test-path>"
CONSUMER="$(cd "$ST_PATH" 2>/dev/null && pwd)" || die "no such consumer directory: $ST_PATH"
GENERATOR="$CONSUMER/scripts/mock-board.sh"
[ -f "$GENERATOR" ] || die "no scripts/mock-board.sh in $CONSUMER; see the \"Mock board data\" section of $CONSUMER/README.md"

OUT="$(bash "$GENERATOR" reset 2>&1)"
RC=$?
if [ "$RC" -ne 0 ]; then
  printf '%s\n' "$OUT" >&2
  printf 'st-test-mock-board: the generator exited %s; see the "Mock board data" section of %s/README.md\n' "$RC" "$CONSUMER" >&2
  exit 1
fi

printf 'ST-Test mock board regenerated in %s\n%s\n' "$CONSUMER" "$OUT"
