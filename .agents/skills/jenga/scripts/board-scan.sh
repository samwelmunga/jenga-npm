#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# skills/jenga/scripts/board-scan.sh
#
# Deterministic board inventory for `/jenga`'s interactive scope-selection
# flow (E45). Walks project/board/epics/, project/board/stories/, and
# project/board/tasks/ and emits a structured JSON array describing every
# item on the board.
#
# This is the SINGLE SOURCE OF TRUTH for board contents in E45. Per this
# repo's "Scripts Over Inline Logic" principle, no other script or agent
# instruction may re-scan the board independently — every consumer below
# reads this script's stdout instead:
#
#   - E45_S01_T02 (fuzzy-ID grammar parser)      resolves user-typed IDs
#     against the `id`/`type` fields this script emits.
#   - E45_S01_T03 (cascade resolver)             expands an epic/story
#     selection to eligible descendants using `epic_id`/`story_id`/`status`.
#   - E45_S02_T01 (interactive picker)           renders the numbered
#     hierarchical checklist from this inventory.
#   - E45_S02_T02 (confirmation-tree renderer)   renders the nested
#     Epic > Story > Task confirmation tree from this inventory.
#
# ---------------------------------------------------------------------------
# USAGE
# ---------------------------------------------------------------------------
#   skills/jenga/scripts/board-scan.sh
#
# No arguments. Reads project/board/ under the resolved project root (see
# lib/resolve-project-dir.sh — honours CLAUDE_PROJECT_DIR / the git repo
# root / cwd, in that priority order).
#
# ---------------------------------------------------------------------------
# OUTPUT SCHEMA (stable — downstream scripts depend on these exact names)
# ---------------------------------------------------------------------------
# stdout is a single JSON array. Nothing else is ever written to stdout.
# Each element is an object:
#
#   {
#     "id":       "E45_S01_T01",          // the item's own board ID
#     "type":     "epic" | "story" | "task",
#     "epic_id":  "E45",                   // this item's epic: itself (epic),
#                                           // its parent (story/task), or
#                                           // null if the frontmatter omits it
#     "story_id": "E45_S01",               // this item's story: itself
#                                           // (story), its parent (task),
#                                           // or null for epics / if absent
#     "title":    "Board scanner script — structured inventory ...",
#     "status":   "Pending",               // verbatim value of the
#                                           // frontmatter `status:` field
#     "summary":  "Everything else in E45 reads this script's output ...",
#     "file":     "project/board/tasks/E45_S01_T01_board-scanner-script.md"
#   }
#
# Field notes:
#   - `epic_id` / `story_id` are ALWAYS PRESENT KEYS, whose value is `null`
#     when not applicable/absent — never an omitted key. Consumers should
#     use a null-safe read (e.g. `.epic_id // empty` in jq), not assume the
#     key exists with a non-null value.
#   - `summary` is a single-line, best-effort excerpt:
#       * epic  -> first non-empty, non-heading line after "## Purpose"
#       * story -> first non-empty line after the "# Story: <Title>"
#                  heading and before the next "##" heading (the
#                  "As a ... I want ... so that ..." statement)
#       * task  -> first non-empty, non-heading line after "## Description"
#     `summary` is "" (empty string, never absent) when no matching section
#     is found.
#   - `file` is repo-relative (relative to the resolved project root), using
#     forward slashes, suitable for display or re-opening the source file.
#   - Array order: epics first, then stories, then tasks; within each type,
#     files are sorted lexically by filename (stable across runs).
#
# ---------------------------------------------------------------------------
# ERROR HANDLING
# ---------------------------------------------------------------------------
# A single board file that fails to parse (unreadable, or missing the `id`
# frontmatter key) is SKIPPED and reported as a warning on stderr — it does
# NOT abort the scan or corrupt stdout. This is a deliberate design choice:
# the picker and confirmation renderer need a scan that degrades gracefully
# on one malformed file rather than producing no output for the whole board.
#
# Exit codes:
#   0   scan completed (stdout is always valid JSON on this path, even if
#       some files were skipped with stderr warnings, and even if the
#       result is an empty array because no board files exist yet)
#   1   the board root (project/board/) does not exist at all, or python3
#       is not available — both are real setup problems, not per-file noise
#
# ---------------------------------------------------------------------------

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Resolve JENGA_PROJECT_DIR the same way every other script in this repo
# does (CLAUDE_PROJECT_DIR -> git toplevel -> cwd). Falls back to locating
# the repo root relative to this script if the shared helper is missing.
if [ -f "$SCRIPT_DIR/../../../lib/resolve-project-dir.sh" ]; then
  # shellcheck source=lib/resolve-project-dir.sh
  source "$SCRIPT_DIR/../../../lib/resolve-project-dir.sh"
elif [ -n "${CLAUDE_PROJECT_DIR:-}" ]; then
  JENGA_PROJECT_DIR="$CLAUDE_PROJECT_DIR"
else
  JENGA_PROJECT_DIR="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel 2>/dev/null || pwd)"
fi

BOARD_DIR="$JENGA_PROJECT_DIR/project/board"

if [ ! -d "$BOARD_DIR" ]; then
  echo "Error: board directory not found at $BOARD_DIR" >&2
  exit 1
fi

if ! command -v python3 >/dev/null 2>&1; then
  echo "Error: python3 is required by board-scan.sh" >&2
  exit 1
fi

python3 - "$JENGA_PROJECT_DIR" "$BOARD_DIR" <<'PY'
import json
import re
import sys
from pathlib import Path

project_root = Path(sys.argv[1])
board_dir = Path(sys.argv[2])

FRONTMATTER_RE = re.compile(r'^---\n(.*?)\n---\n?(.*)$', re.DOTALL)
TOP_LEVEL_KV_RE = re.compile(r'^([A-Za-z_][A-Za-z0-9_]*):[ \t]*(.*)$')


def parse_frontmatter(text):
    """Return (fields_dict, body_text). Only top-level `key: value` lines
    are captured (indented list items such as `  - E01_S02` are skipped
    intentionally — this scanner reads each board file directly and does
    not need to follow parent->children ID lists)."""
    m = FRONTMATTER_RE.match(text)
    if not m:
        return {}, text
    fm_text, body = m.group(1), m.group(2)
    fields = {}
    for line in fm_text.splitlines():
        if not line or line[0] in (' ', '\t', '#'):
            continue
        km = TOP_LEVEL_KV_RE.match(line)
        if not km:
            continue
        key, val = km.group(1), km.group(2).strip()
        val = val.strip('"').strip("'")
        fields[key] = val
    return fields, body


def first_line_after_heading(body, heading_re):
    """First non-empty line strictly after a line matching heading_re, up
    to (not including) the next '#'-prefixed heading line."""
    lines = body.splitlines()
    for i, line in enumerate(lines):
        if heading_re.match(line.strip()):
            for candidate in lines[i + 1:]:
                stripped = candidate.strip()
                if not stripped:
                    continue
                if stripped.startswith('#'):
                    return ""
                return stripped
            return ""
    return ""


PURPOSE_HEADING_RE = re.compile(r'^##\s+Purpose\s*$', re.IGNORECASE)
DESCRIPTION_HEADING_RE = re.compile(r'^##\s+Description\s*$', re.IGNORECASE)
TITLE_HEADING_RE = re.compile(r'^#\s+Story:.*$', re.IGNORECASE)


def summarize(item_type, body):
    if item_type == "epic":
        return first_line_after_heading(body, PURPOSE_HEADING_RE)
    if item_type == "task":
        return first_line_after_heading(body, DESCRIPTION_HEADING_RE)
    # story: first non-empty line after the "# Story: <Title>" heading and
    # before the next "##" heading.
    return first_line_after_heading(body, TITLE_HEADING_RE)


TYPE_DIRS = [
    ("epic", board_dir / "epics"),
    ("story", board_dir / "stories"),
    ("task", board_dir / "tasks"),
]

items = []

for item_type, dir_path in TYPE_DIRS:
    if not dir_path.is_dir():
        continue
    for f in sorted(dir_path.glob("*.md")):
        try:
            text = f.read_text(encoding="utf-8")
        except Exception as e:
            print(f"Warning: skipping {f}: read error: {e}", file=sys.stderr)
            continue

        fields, body = parse_frontmatter(text)
        item_id = fields.get("id", "")
        if not item_id:
            print(f"Warning: skipping {f}: missing 'id' in frontmatter", file=sys.stderr)
            continue

        if item_type == "epic":
            epic_id = item_id
            story_id = None
        elif item_type == "story":
            epic_id = fields.get("epic_id") or None
            story_id = item_id
        else:
            epic_id = fields.get("epic_id") or None
            story_id = fields.get("story_id") or None

        try:
            rel_file = f.relative_to(project_root).as_posix()
        except ValueError:
            rel_file = f.as_posix()

        items.append({
            "id": item_id,
            "type": item_type,
            "epic_id": epic_id,
            "story_id": story_id,
            "title": fields.get("title", ""),
            "status": fields.get("status", ""),
            "summary": summarize(item_type, body),
            "file": rel_file,
        })

json.dump(items, sys.stdout, indent=2)
sys.stdout.write("\n")
PY
