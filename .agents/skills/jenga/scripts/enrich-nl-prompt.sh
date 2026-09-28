#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# skills/jenga/scripts/enrich-nl-prompt.sh
#
# Deterministic board + documentation enrichment scan for `/jenga`'s natural-language branch,
# ported from `/route`'s Steps 3-5 (E53_S13_T01). `/route` is being retired in this same story
# (E53_S13_T02) — this script is how its board-context and documentation enrichment survives, as
# an OPT-IN capability behind `/jenga`'s `--enrich` flag (see `skills/jenga/SKILL.md`'s Phase 0.75
# natural-language branch). The default, unflagged NL path never invokes this script.
#
# Per CLAUDE.md's "Scripts Over Inline Logic" principle, the board scan and docs scan are
# deterministic and belong here — the agent's job is limited to invoking this script and
# assembling the enriched prompt from its structured output, exactly as it already does for
# `board-scan.sh`/`detect-nl-intent.sh`/`match-playbook.sh` elsewhere in this directory.
#
# ---------------------------------------------------------------------------
# USAGE
# ---------------------------------------------------------------------------
#   skills/jenga/scripts/enrich-nl-prompt.sh "<raw prompt text>"
#
# The argument is the same raw natural-language text `detect-nl-intent.sh` classified as
# `nl_intent` (its `raw_argument` field) — passed through verbatim, not re-cleaned here.
#
# ---------------------------------------------------------------------------
# ALGORITHM
# ---------------------------------------------------------------------------
# Board half (`/route`'s Step 3) — reuses `skills/jenga/scripts/board-scan.sh` verbatim for the
# board inventory (no duplicate board-scanning logic is introduced here). The prompt is tokenized
# (lowercased, stopword-filtered) and an item is a match if any prompt token appears as a substring
# of its `title` or `summary` field. Items with `status` of `Archived` or `Cancelled` are excluded.
# Results are capped at the top 5, in `board-scan.sh`'s own stable order (epics, then stories, then
# tasks; lexical by filename within each type).
#
# Docs half (`/route`'s Step 4) — scans `project/documentation/plans/`,
# `project/documentation/summaries/`, `project/documentation/examples/`, and `docs/` (non-recursive
# within each) for files whose filename OR first top-level heading contains a prompt token.
# Results are capped at the top 3, in directory-then-lexical-filename order.
#
# ---------------------------------------------------------------------------
# OUTPUT SCHEMA (stable)
# ---------------------------------------------------------------------------
# stdout is always a single JSON object. Nothing else is ever written to stdout.
#
#   {
#     "board_items": [
#       {"id": "E12_S03", "type": "story", "status": "Pending", "title": "...",
#        "file": "project/board/stories/E12_S03_....md"},
#       ...                                                    // up to 5
#     ],
#     "docs": [
#       {"path": "docs/skill-authoring.md", "summary": "<first heading or filename>"},
#       ...                                                    // up to 3
#     ],
#     "board_items_found": 2,     // total matches BEFORE the top-5 cap
#     "docs_found": 1             // total matches BEFORE the top-3 cap
#   }
#
# An empty result (`board_items: []`, `docs: []`, both counts 0) is a normal, non-error outcome —
# it means the prompt simply didn't match anything on the board or in docs. Exit code is 0 in that
# case, same as any other successful scan.
#
# ---------------------------------------------------------------------------
# EXIT CODES
# ---------------------------------------------------------------------------
#   0   scan completed (stdout is always valid JSON on this path, including the empty-match case)
#   1   usage error (no argument given), or a setup problem: `board-scan.sh` missing/failing, or
#       python3 unavailable — real setup problems, not classification outcomes.
#
# ---------------------------------------------------------------------------

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BOARD_SCAN="$SCRIPT_DIR/board-scan.sh"

if [ $# -lt 1 ] || [ -z "${1:-}" ]; then
  echo 'Usage: enrich-nl-prompt.sh "<raw prompt text>"' >&2
  exit 1
fi

RAW_PROMPT="$1"

if [ ! -x "$BOARD_SCAN" ]; then
  echo "Error: board-scan.sh not found or not executable at $BOARD_SCAN" >&2
  exit 1
fi

if ! command -v python3 >/dev/null 2>&1; then
  echo "Error: python3 is required by enrich-nl-prompt.sh" >&2
  exit 1
fi

# Resolve JENGA_PROJECT_DIR the same way every other script in this directory does
# (CLAUDE_PROJECT_DIR -> git toplevel -> cwd).
if [ -f "$SCRIPT_DIR/../../../lib/resolve-project-dir.sh" ]; then
  # shellcheck source=lib/resolve-project-dir.sh
  source "$SCRIPT_DIR/../../../lib/resolve-project-dir.sh"
elif [ -n "${CLAUDE_PROJECT_DIR:-}" ]; then
  JENGA_PROJECT_DIR="$CLAUDE_PROJECT_DIR"
else
  JENGA_PROJECT_DIR="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel 2>/dev/null || pwd)"
fi

BOARD_JSON="$("$BOARD_SCAN")"

PY_SCRIPT="$(mktemp -t enrich-nl-prompt-XXXXXX.py)"
trap 'rm -f "$PY_SCRIPT"' EXIT

cat > "$PY_SCRIPT" <<'PY'
import json
import re
import sys
from pathlib import Path

project_root = Path(sys.argv[1])
raw_prompt = sys.argv[2]
board_json = sys.stdin.read()

STOPWORDS = {
    "a", "an", "the", "to", "and", "or", "of", "in", "on", "for", "this", "that",
    "is", "it", "its", "with", "from", "into", "i", "my", "me", "we", "our",
    "you", "your", "then", "so", "be", "as", "at", "by", "up", "out", "all",
    "let", "lets", "let's", "go", "want", "please", "help", "would", "like",
}


def tokenize(text):
    words = re.findall(r"[a-z0-9']+", text.lower())
    return {w for w in words if w not in STOPWORDS and len(w) > 1}


prompt_tokens = tokenize(raw_prompt)

# ---------------------------------------------------------------------------
# Board half
# ---------------------------------------------------------------------------
try:
    board_items = json.loads(board_json)
except Exception as e:
    print(f"Error: could not parse board-scan.sh output as JSON: {e}", file=sys.stderr)
    sys.exit(1)

EXCLUDED_STATUSES = {"Archived", "Cancelled"}


def item_matches(item):
    haystack = f"{item.get('title', '')} {item.get('summary', '')}".lower()
    return any(tok in haystack for tok in prompt_tokens)


matched_board = [
    item for item in board_items
    if item.get("status") not in EXCLUDED_STATUSES and item_matches(item)
]

board_items_found = len(matched_board)
top_board_items = [
    {
        "id": item.get("id", ""),
        "type": item.get("type", ""),
        "status": item.get("status", ""),
        "title": item.get("title", ""),
        "file": item.get("file", ""),
    }
    for item in matched_board[:5]
]

# ---------------------------------------------------------------------------
# Docs half
# ---------------------------------------------------------------------------
DOC_DIRS = [
    "project/documentation/plans",
    "project/documentation/summaries",
    "project/documentation/examples",
    "docs",
]

HEADING_RE = re.compile(r'^#+\s+(.*\S)\s*$')


def first_heading(path):
    try:
        with path.open(encoding="utf-8") as f:
            for line in f:
                m = HEADING_RE.match(line.rstrip("\n"))
                if m:
                    return m.group(1)
    except Exception:
        pass
    return ""


matched_docs = []
for rel_dir in DOC_DIRS:
    dir_path = project_root / rel_dir
    if not dir_path.is_dir():
        continue
    for f in sorted(dir_path.glob("*.md")):
        heading = first_heading(f)
        haystack = f"{f.stem} {heading}".lower()
        if any(tok in haystack for tok in prompt_tokens):
            try:
                rel_file = f.relative_to(project_root).as_posix()
            except ValueError:
                rel_file = f.as_posix()
            matched_docs.append({
                "path": rel_file,
                "summary": heading or f.stem,
            })

docs_found = len(matched_docs)
top_docs = matched_docs[:3]

result = {
    "board_items": top_board_items,
    "docs": top_docs,
    "board_items_found": board_items_found,
    "docs_found": docs_found,
}

json.dump(result, sys.stdout, indent=2)
sys.stdout.write("\n")
PY

python3 "$PY_SCRIPT" "$JENGA_PROJECT_DIR" "$RAW_PROMPT" <<< "$BOARD_JSON"
