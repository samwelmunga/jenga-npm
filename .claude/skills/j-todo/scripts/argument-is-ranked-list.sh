#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# skills/j-todo/scripts/argument-is-ranked-list.sh
#
# Classifier for `j-todo`'s conditional `output_types` declaration (E63_S01_T04). `/todo`'s normal
# behavior (adding a mission to the board) produces no forwardable output -- only the distinct
# `--ranked-list` invocation (E63_S01_T03) does, by printing `scripts/render-ranked-list.sh`'s
# `ranked_list`-typed output verbatim (see `skills/j-todo/SKILL.md`'s "--ranked-list Flag" section).
#
# Declaring `output_types: ranked_list` unconditionally would misdescribe every normal /todo
# invocation as a ranked_list producer, violating E53_S11's honesty-over-breadth policy. This script
# is the classifier `skills/j-todo/SKILL.md`'s `output_types` keys off of instead, per
# `docs/skill-authoring.md`'s conditional `{when, type}` form -- the same pattern `j.jenga` already
# uses for `detect-nl-intent.sh`.
#
# Neither built-in predicate (`argument_empty` / `argument_nonempty`) fits here: `--ranked-list` is a
# non-empty argument, but so is mission text and `--trivial ...` -- both of which still produce
# `/todo`'s normal (undeclared-type) output, not `ranked_list`. `argument_nonempty` alone cannot tell
# those apart, so this dedicated classifier exists to draw that one distinction.
#
# ---------------------------------------------------------------------------
# WHAT THIS SCRIPT IS FOR (read before assuming it gates runtime routing)
# ---------------------------------------------------------------------------
# `skills/jenga/scripts/load-playbooks.sh` only ever checks that a classifier-script `when` value
# resolves to an existing, executable file on disk under this skill's own `scripts/` directory -- it
# never runs this script to decide which `output_types` branch actually fires (see
# `docs/skill-authoring.md`'s "output_types" and "forward_from resolution" sections for the exact,
# narrow claim that load-time check does and does not make). This script exists so that structural
# check has a real file to find, and so the classification it names is genuinely correct if anything
# ever does execute it (e.g. a future runtime-verification path) -- not because anything wires its
# exit code into routing today. `skills/j-todo/SKILL.md`'s own step 0 short-circuit is what actually
# decides the `--ranked-list` branch at real invocation time; this script's job is narrower and
# purely descriptive.
#
# ---------------------------------------------------------------------------
# USAGE
# ---------------------------------------------------------------------------
#   skills/j-todo/scripts/argument-is-ranked-list.sh "<raw /todo invocation argument>"
#
# ---------------------------------------------------------------------------
# OUTPUT CONTRACT
# ---------------------------------------------------------------------------
# stdout is always a single JSON object:
#
#   {"classification": "ranked_list"}   -- exit 0 -- the argument, trimmed, is exactly `--ranked-list`
#   {"classification": "normal"}        -- exit 1 -- anything else, including an empty argument,
#                                           mission text, or `--trivial ...`
#
# ---------------------------------------------------------------------------
# EXIT CODES
# ---------------------------------------------------------------------------
#   0   "ranked_list" classification (see above)
#   1   "normal" classification (see above) -- a legitimate outcome, not an error
#   2   usage error (no argument given)
#
# ---------------------------------------------------------------------------

set -euo pipefail

if [ $# -lt 1 ]; then
  echo 'Usage: argument-is-ranked-list.sh "<raw /todo invocation argument>"' >&2
  exit 2
fi

RAW_INPUT="$1"

# Trim leading/trailing whitespace only -- no other normalization. `--ranked-list` "takes no other
# arguments" per skills/j-todo/SKILL.md, so anything beyond the flag itself (e.g. trailing mission
# text accidentally combined with it) is deliberately NOT classified as ranked_list here.
TRIMMED="$(printf '%s' "$RAW_INPUT" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"

if [ "$TRIMMED" = "--ranked-list" ]; then
  echo '{"classification": "ranked_list"}'
  exit 0
fi

echo '{"classification": "normal"}'
exit 1
