#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# skills/j-dev-done/scripts/classify-commit-outcome.sh
#
# Deterministic classifier backing `/dev-done` (story E42_S04, task
# E42_S04_T01). `/dev-done` chains `/commit <scope-id>` then `/self-sync`,
# but must NOT proceed to `/self-sync` when `/commit` halted early because
# there was nothing to commit. Per CLAUDE.md's "Skill Implementation
# Principle — Scripts Over Inline Logic", that halt-vs-proceed check is a
# deterministic, repeatable text match — it does not belong as inline
# conditional logic in `skills/j-dev-done/SKILL.md`, so it lives here instead,
# the same way `skills/self-sync/SKILL.md` delegates its own filesystem work
# to `skills/self-sync/scripts/run.js` rather than inlining it.
#
# `/commit` and `/self-sync` are themselves agent-executed skills, not plain
# executables — this script never shells out to invoke either one. It only
# classifies text that the calling agent already captured from `/commit`'s
# output. Invoking `/commit` and `/self-sync` remains `SKILL.md`'s job.
#
# ---------------------------------------------------------------------------
# WHAT IT MATCHES
# ---------------------------------------------------------------------------
# `skills/commit/SKILL.md`'s Instructions section states, verbatim:
#
#   "If no epic, task, or story has been implemented, exit with the message:
#   "No implementation to commit.""
#
# That exact sentence — "No implementation to commit." — is the ONLY halt
# signal this script recognizes. If a future edit to `skills/commit/SKILL.md`
# changes that wording, this script's match must be updated to match, or it
# will silently stop recognizing the halt case (see Dependencies & Risks in
# the task's execution plan).
#
# ---------------------------------------------------------------------------
# INVOCATION
# ---------------------------------------------------------------------------
#   classify-commit-outcome.sh [<captured-commit-output>]
#
# The text `/commit` produced is passed either as the single argument, or
# (when no argument is given) read from stdin in full, e.g.:
#
#   skills/j-dev-done/scripts/classify-commit-outcome.sh <<< "$COMMIT_OUTPUT"
#   printf '%s' "$COMMIT_OUTPUT" | skills/j-dev-done/scripts/classify-commit-outcome.sh
#
# ---------------------------------------------------------------------------
# OUTPUT CONTRACT (stdout, single line, nothing else)
# ---------------------------------------------------------------------------
#   HALT case      stdout is the exact literal message "No implementation to
#                  commit." — the calling agent relays this stdout verbatim
#                  to the user and does NOT invoke `/self-sync`.
#   PROCEED case    stdout is the literal token "PROCEED" — the calling
#                  agent invokes `/self-sync` next.
#
# ---------------------------------------------------------------------------
# EXIT CODES
# ---------------------------------------------------------------------------
#   0   PROCEED — `/commit` completed normally (regardless of whether it
#       reported drift or doc-sync findings along the way); stdout is
#       "PROCEED".
#   1   HALT — `/commit` halted early with the exact "No implementation to
#       commit." message; stdout is that exact message.
#   2   Usage/environment error (e.g. no input at all — neither an argument
#       nor anything on stdin); nothing meaningful on stdout, an error on
#       stderr.
# ---------------------------------------------------------------------------

set -euo pipefail

HALT_MESSAGE="No implementation to commit."

if [ "$#" -gt 1 ]; then
  echo "Usage: $(basename "$0") [<captured-commit-output>]" >&2
  echo "  (or pipe the captured output on stdin with no argument)" >&2
  exit 2
fi

if [ "$#" -eq 1 ]; then
  INPUT="$1"
else
  # No argument — read the full captured output from stdin.
  if [ -t 0 ]; then
    echo "ERROR: no argument given and stdin is a terminal — nothing to classify" >&2
    exit 2
  fi
  INPUT="$(cat)"
fi

if [ -z "$INPUT" ]; then
  echo "ERROR: no commit output provided to classify" >&2
  exit 2
fi

# Trim leading/trailing whitespace from the whole input for the exact-match case.
TRIMMED="$(printf '%s' "$INPUT" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"

if [ "$TRIMMED" = "$HALT_MESSAGE" ]; then
  printf '%s\n' "$HALT_MESSAGE"
  exit 1
fi

# Also match the halt message appearing as its own standalone line anywhere
# in a longer captured response (e.g. wrapped in surrounding agent prose),
# since the calling agent's captured "output text" is free-form, not a
# guaranteed exact-equals string.
while IFS= read -r line; do
  LINE_TRIMMED="$(printf '%s' "$line" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
  if [ "$LINE_TRIMMED" = "$HALT_MESSAGE" ]; then
    printf '%s\n' "$HALT_MESSAGE"
    exit 1
  fi
done <<< "$INPUT"

printf 'PROCEED\n'
exit 0
