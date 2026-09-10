#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# skills/jenga/scripts/match-playbook.sh
#
# Deterministic PLAYBOOK matcher for `/jenga`'s natural-language branch (E53_S02_T02). Runs the
# same three-pass matching *philosophy* as `skills/route/SKILL.md`'s Step 2 (keyword ->
# example similarity -> description), but scoped to the playbook catalog produced by
# `load-playbooks.sh` (E53_S02_T01) instead of the single-skill catalog `load-nl-catalog.sh`
# produces for `/route`/`/jenga`'s existing single-skill matching.
#
# ---------------------------------------------------------------------------
# THIS IS A FALLBACK — READ BEFORE WIRING (E53_S02_T04)
# ---------------------------------------------------------------------------
# This script is invoked ONLY after `/jenga`'s existing single-skill match (against
# `load-nl-catalog.sh`'s catalog, per E53_S01_T03) has already been attempted and did NOT produce
# a confident result (no match, or an ambiguous multi-way tie). It never runs ahead of, or in
# place of, single-skill matching — a confident single-skill match always wins and this script is
# never even invoked in that case. This mirrors the story's own framing: playbooks are proposed
# only when intent "does not cleanly resolve to one skill."
#
# ---------------------------------------------------------------------------
# USAGE
# ---------------------------------------------------------------------------
#   skills/jenga/scripts/match-playbook.sh "<raw prompt>"
#
# The argument is the same raw natural-language argument `detect-nl-intent.sh` classified as
# `nl_intent` (its `raw_argument` field) — passed through verbatim, not re-cleaned here.
#
# ---------------------------------------------------------------------------
# MATCHING ALGORITHM (deterministic — a shell/python script cannot do semantic judgment the way
# an agent can, so this is a concrete, repeatable heuristic standing in for /route's Step 2 prose)
# ---------------------------------------------------------------------------
# Three passes are run in order against the full playbook catalog (from `load-playbooks.sh`).
# Each pass narrows the candidate pool; the first pass to produce a single unique leader commits
# to that result. A pass that produces a TIE narrows the pool to just the tied candidates and
# falls through to the next pass as a tie-breaker (rather than immediately declaring ambiguity) —
# only if the FINAL pass (description match) still can't break the tie is the result "ambiguous".
# If the final pass finds NO signal at all (every candidate scores 0) but an earlier pass had
# already established a real tie among 2+ candidates (on a genuine positive score, not a
# default/empty pool), that pre-existing tie is reported as "ambiguous" rather than discarded as
# "no_match" — the final pass adding no new information does not erase the real signal a prior
# pass already found. "no_match" is reserved for when NO pass ever found any positive signal.
#
#   Pass 1 — Keyword match: score = count of this playbook's `keywords` entries that appear as a
#            case-insensitive substring of the raw prompt. Playbooks scoring 0 are dropped from
#            the pool for this pass. If exactly one playbook has the (positive) max score -> match.
#            If the pool is empty (no playbook matched any keyword) -> proceed to Pass 2 over the
#            FULL catalog. If tied among 2+ -> proceed to Pass 2 restricted to the TIED set.
#
#   Pass 2 — Example similarity: score = the highest Jaccard token-overlap ratio (lowercased,
#            stopword-filtered word sets) between the prompt and any one of the playbook's
#            `examples`. Scores below MIN_SIMILARITY are treated as 0 (non-candidates). Same
#            unique-max / tie / empty-pool handling as Pass 1, operating on the current pool.
#
#   Pass 3 — Description match: same Jaccard token-overlap approach, against each playbook's
#            single `description` string instead of its `examples` list. This is the FINAL pass:
#            a unique max -> match; a tie among 2+ -> "ambiguous"; an empty pool / all-zero scores
#            -> "no_match".
#
# ---------------------------------------------------------------------------
# OUTPUT SCHEMA
# ---------------------------------------------------------------------------
# stdout is always a single JSON object, one of:
#
#   {"classification": "playbook_match", "playbook_id": "brainstorm-to-mirror",
#    "name": "Idea to Public Release", "steps": ["j-brainstorm", "j-todo", "j-do", "j-dev-done", "j-mirror-public"]}
#
#   {"classification": "ambiguous", "candidates": [{"playbook_id": "...", "name": "..."}, ...]}
#
#   {"classification": "no_match"}
#
# Nothing else is ever written to stdout — errors/warnings go to stderr only.
#
# ---------------------------------------------------------------------------
# EXIT CODES
# ---------------------------------------------------------------------------
#   0   any of the three classifications above (all are legitimate outcomes, not errors)
#   2   usage error (no argument given), or a real setup failure (`load-playbooks.sh` failed,
#       python3 unavailable)
#
# ---------------------------------------------------------------------------

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOAD_PLAYBOOKS="$SCRIPT_DIR/load-playbooks.sh"

if [ $# -lt 1 ] || [ -z "${1:-}" ]; then
  echo 'Usage: match-playbook.sh "<raw prompt>"' >&2
  exit 2
fi

RAW_PROMPT="$1"

if [ ! -x "$LOAD_PLAYBOOKS" ] && [ ! -f "$LOAD_PLAYBOOKS" ]; then
  echo "Error: load-playbooks.sh not found at $LOAD_PLAYBOOKS" >&2
  exit 2
fi

if ! command -v python3 >/dev/null 2>&1; then
  echo "Error: python3 is required by match-playbook.sh" >&2
  exit 2
fi

CATALOG_JSON="$(bash "$LOAD_PLAYBOOKS")" || {
  echo "Error: load-playbooks.sh failed" >&2
  exit 2
}

PY_SCRIPT="$(mktemp -t match-playbook-XXXXXX.py)"
trap 'rm -f "$PY_SCRIPT"' EXIT

cat > "$PY_SCRIPT" <<'PY'
import json
import re
import sys

raw_prompt = sys.argv[1]
catalog_json = sys.stdin.read()

try:
    catalog = json.loads(catalog_json)
except Exception as e:
    print(f"Error: could not parse load-playbooks.sh output as JSON: {e}", file=sys.stderr)
    sys.exit(2)

if not isinstance(catalog, list):
    print("Error: load-playbooks.sh produced a non-array result", file=sys.stderr)
    sys.exit(2)

if len(catalog) == 0:
    print(json.dumps({"classification": "no_match"}))
    sys.exit(0)

MIN_SIMILARITY = 0.15

STOPWORDS = {
    "a", "an", "the", "to", "and", "or", "of", "in", "on", "for", "this", "that",
    "is", "it", "its", "with", "from", "into", "i", "my", "me", "we", "our",
    "you", "your", "then", "so", "be", "as", "at", "by", "up", "out", "all",
    "let", "lets", "let's", "go", "want", "please", "help", "would", "like",
}


def tokenize(text):
    words = re.findall(r"[a-z0-9']+", text.lower())
    return {w for w in words if w not in STOPWORDS and len(w) > 1}


def jaccard(a_tokens, b_tokens):
    if not a_tokens or not b_tokens:
        return 0.0
    inter = len(a_tokens & b_tokens)
    union = len(a_tokens | b_tokens)
    return inter / union if union else 0.0


prompt_lower = raw_prompt.lower()
prompt_tokens = tokenize(raw_prompt)

pool = list(catalog)


def resolve_pool(scored_pool):
    """Given a list of (playbook, score) with score > 0 meaning 'candidate', return
    ('unique', playbook) | ('tie', [playbooks]) | ('empty', None)."""
    positive = [(pb, s) for pb, s in scored_pool if s > 0]
    if not positive:
        return ("empty", None)
    max_score = max(s for _, s in positive)
    leaders = [pb for pb, s in positive if s == max_score]
    if len(leaders) == 1:
        return ("unique", leaders[0])
    return ("tie", leaders)


def emit_match(pb):
    print(json.dumps({
        "classification": "playbook_match",
        "playbook_id": pb["id"],
        "name": pb["name"],
        "steps": pb["steps"],
    }))
    sys.exit(0)


def emit_ambiguous(pbs):
    print(json.dumps({
        "classification": "ambiguous",
        "candidates": [{"playbook_id": pb["id"], "name": pb["name"]} for pb in pbs],
    }))
    sys.exit(0)


def emit_no_match():
    print(json.dumps({"classification": "no_match"}))
    sys.exit(0)


# `narrowed_by_tie` tracks whether ANY earlier pass established a genuine tie among 2+
# candidates on real signal (a positive score, not a default/empty pool). This matters for the
# final pass below: if Pass 3 can't further discriminate (all scores drop to 0 — e.g. two
# playbooks share near-identical description text relative to a short prompt), that must NOT be
# reported as "no_match" when a real tie already existed upstream — the correct outcome is
# "ambiguous" over that already-established candidate set. "no_match" is reserved for the case
# where NO pass ever found any positive signal at all.
narrowed_by_tie = False

# --- Pass 1: keyword match -------------------------------------------------
pass1_scores = []
for pb in pool:
    score = sum(1 for kw in pb["keywords"] if kw.lower() in prompt_lower)
    pass1_scores.append((pb, score))

outcome, result = resolve_pool(pass1_scores)
if outcome == "unique":
    emit_match(result)
elif outcome == "tie":
    pool = result  # narrow to tied candidates, fall through to Pass 2 as tie-breaker
    narrowed_by_tie = True
# else "empty" -> pool stays the FULL catalog for Pass 2

# --- Pass 2: example similarity --------------------------------------------
pass2_scores = []
for pb in pool:
    best = 0.0
    for example in pb["examples"]:
        sim = jaccard(prompt_tokens, tokenize(example))
        if sim > best:
            best = sim
    pass2_scores.append((pb, best if best >= MIN_SIMILARITY else 0.0))

outcome, result = resolve_pool(pass2_scores)
if outcome == "unique":
    emit_match(result)
elif outcome == "tie":
    pool = result  # narrow further, fall through to Pass 3 as tie-breaker
    narrowed_by_tie = True
# else "empty" -> pool stays whatever it was entering Pass 2 for Pass 3 (narrowed_by_tie
# unchanged — an empty pass2 outcome adds no new tie signal of its own)

# --- Pass 3: description match (final pass) --------------------------------
pass3_scores = []
for pb in pool:
    sim = jaccard(prompt_tokens, tokenize(pb["description"]))
    pass3_scores.append((pb, sim if sim >= MIN_SIMILARITY else 0.0))

outcome, result = resolve_pool(pass3_scores)
if outcome == "unique":
    emit_match(result)
elif outcome == "tie":
    emit_ambiguous(result)
elif narrowed_by_tie and len(pool) > 1:
    # Pass 3 added no further discriminating signal, but an earlier pass already established a
    # real tie among these exact candidates -- report that tie rather than discarding it.
    emit_ambiguous(pool)
else:
    emit_no_match()
PY

python3 "$PY_SCRIPT" "$RAW_PROMPT" <<< "$CATALOG_JSON"
exit $?
