#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# skills/j-todo/scripts/argument-is-not-ranked-list.sh
#
# Classifier for the OTHER half of j-todo's conditional `output_types` declaration
# (E63_S01_T04, corrected). `output_types: id_list` was deliberately declared on j-todo by
# `E53_S11_T01` ("j-todo (none) -> id_list (emits board item ids)") -- /todo's normal
# mission-capture flow genuinely does produce a forwardable board-item id, and that claim is
# still true after E63_S01_T03 added --ranked-list. It must stay declared, not be silently
# dropped when the ranked_list branch is added alongside it.
#
# This script is the "when" for that id_list branch. It is the exact logical complement of
# `argument-is-ranked-list.sh` -- deliberately implemented as a thin delegate to that script
# rather than a second, independently-written check, so the two branches can never quietly
# drift apart on what "--ranked-list" means. There is exactly one place that decision is made
# (argument-is-ranked-list.sh); this script only inverts its verdict.
#
# Why not the built-in `argument_nonempty` predicate instead of a real script: `--ranked-list`
# is ALSO a non-empty argument, so `argument_nonempty -> id_list` would be a false claim for
# that one specific invocation shape (its actual output is ranked_list, never id_list). Using
# the built-in here would pass load-playbooks.sh's structural check trivially (no script to
# find), but it would misdescribe the one case this task exists to carve out -- exactly the
# honesty-over-breadth violation E53_S11 rejects. A dedicated classifier that excludes
# `--ranked-list` precisely is the honest choice.
#
# ---------------------------------------------------------------------------
# USAGE
# ---------------------------------------------------------------------------
#   skills/j-todo/scripts/argument-is-not-ranked-list.sh "<raw /todo invocation argument>"
#
# ---------------------------------------------------------------------------
# OUTPUT CONTRACT
# ---------------------------------------------------------------------------
# stdout is always a single JSON object:
#
#   {"classification": "normal"}       -- exit 0 -- the argument is anything OTHER than exactly
#                                          `--ranked-list` (empty, mission text, `--trivial ...`,
#                                          etc.) -- /todo's normal mission-capture flow applies.
#   {"classification": "ranked_list"}  -- exit 1 -- the argument IS exactly `--ranked-list`; the
#                                          complement branch (argument-is-ranked-list.sh) applies
#                                          instead, not this one.
#
# ---------------------------------------------------------------------------
# EXIT CODES
# ---------------------------------------------------------------------------
#   0   "normal" classification (see above)
#   1   "ranked_list" classification (see above) -- a legitimate outcome, not an error
#   2   usage error (no argument given), or the delegate script is missing/unreadable, or the
#       delegate exited with an exit code this script does not recognize
#
# ---------------------------------------------------------------------------

set -euo pipefail

if [ $# -lt 1 ]; then
  echo 'Usage: argument-is-not-ranked-list.sh "<raw /todo invocation argument>"' >&2
  exit 2
fi

RAW_INPUT="$1"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RANKED_LIST_CLASSIFIER="$SCRIPT_DIR/argument-is-ranked-list.sh"

if [ ! -f "$RANKED_LIST_CLASSIFIER" ]; then
  echo "Error: argument-is-ranked-list.sh not found at $RANKED_LIST_CLASSIFIER" >&2
  exit 2
fi

# Guard the capture explicitly so `set -e` doesn't abort this script on the delegate's own
# legitimate non-zero exit (1 == "normal" from the delegate's point of view).
set +e
bash "$RANKED_LIST_CLASSIFIER" "$RAW_INPUT" >/dev/null 2>&1
DELEGATE_EXIT=$?
set -e

case "$DELEGATE_EXIT" in
  0)
    # Delegate says "ranked_list" -- the complement is false.
    echo '{"classification": "ranked_list"}'
    exit 1
    ;;
  1)
    # Delegate says "normal" -- the complement is true.
    echo '{"classification": "normal"}'
    exit 0
    ;;
  *)
    echo "Error: argument-is-ranked-list.sh exited with unexpected status $DELEGATE_EXIT" >&2
    exit 2
    ;;
esac
