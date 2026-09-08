#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# skills/jenga/scripts/load-playbooks.sh
#
# Deterministic loader for `/jenga`'s multi-skill PLAYBOOK catalog (E53_S02_T01) — the SINGLE
# REQUIRED SOURCE of playbook data for E53_S02_T02's `match-playbook.sh` and E53_S02_T04's wiring
# into `skills/jenga/SKILL.md`. Neither of those may re-scan `skills/jenga/playbooks/` or
# hand-maintain a playbook list of their own; they only ever invoke this script and read its
# stdout, mirroring the single-source contract `load-nl-catalog.sh` already established for the
# single-skill catalog (E53_S01_T02).
#
# A "playbook" is an ORDERED chain of skills (e.g. brainstorm -> todo -> do -> dev-done ->
# mirror-public) that `/jenga`'s natural-language branch may propose, as an editable, confirmable
# numbered list (see `render-playbook-confirmation.sh`, E53_S02_T03), when free-text intent spans
# more than one skill and does not cleanly resolve to a single one.
#
# ---------------------------------------------------------------------------
# DATA SOURCE
# ---------------------------------------------------------------------------
# Every `*.json` file directly under `skills/jenga/playbooks/`, EXCLUDING `schema.json` (which
# documents the required shape — see that file's own header — but is never itself a playbook
# entry). See `schema.json` for the authoritative field list; this script's validation below is
# a runtime mirror of that schema, not a substitute for it.
#
# ---------------------------------------------------------------------------
# USAGE
# ---------------------------------------------------------------------------
#   skills/jenga/scripts/load-playbooks.sh
#
# No arguments. Emits the full JSON playbook catalog array to stdout.
#
# ---------------------------------------------------------------------------
# OUTPUT SCHEMA
# ---------------------------------------------------------------------------
# stdout is a single JSON array, one object per valid playbook:
#
#   [
#     {
#       "id":          "brainstorm-to-mirror",
#       "name":        "Idea to Public Release",
#       "description": "...",
#       "keywords":    ["..."],
#       "examples":    ["..."],
#       "steps":       ["brainstorm", "todo", "do", "dev-done", "mirror-public"]
#     },
#     ...
#   ]
#
# Nothing but this JSON array is ever written to stdout. Skip warnings go to stderr only and are
# non-fatal — a single malformed playbook file never aborts the whole catalog load.
#
# ---------------------------------------------------------------------------
# VALIDATION / SKIP CONDITIONS (each skip is a stderr warning, never fatal)
# ---------------------------------------------------------------------------
#   - File is not valid JSON, or is not a JSON object                      -> skipped
#   - Missing any required field: id, name, description, keywords,
#     examples, steps                                                     -> skipped
#   - `keywords`, `examples`, or `steps` present but empty (or not a
#     list)                                                                -> skipped
#   - `id` does not equal the filename's basename without `.json`          -> skipped
#     (prevents a playbook's identity from silently drifting from its
#     file location)
#   - Any entry in `steps` has no corresponding `skills/<name>/SKILL.md`
#     on disk                                                              -> skipped (the whole
#     playbook is skipped, not just the bad step — a chain with a broken
#     link is not a usable chain)
#
# ---------------------------------------------------------------------------
# EXIT CODES
# ---------------------------------------------------------------------------
#   0   catalog written to stdout (possibly with skip warnings already emitted to stderr;
#       an empty catalog `[]` is a valid, non-error outcome — e.g. every playbook file was
#       malformed, or no playbook files exist yet beyond schema.json)
#   2   usage error, or a real setup failure (playbooks directory missing entirely, or
#       python3 unavailable)
#
# ---------------------------------------------------------------------------

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Resolve the jenga-agent PACKAGE root (where the canonical skills/ tree actually lives) — same
# monorepo-checkout vs. installed-npm-package detection used by
# skills/jenga/scripts/load-nl-catalog.sh's PKG_ROOT resolution and skills/init/scripts/init.sh.
if [ -d "$SCRIPT_DIR/../../../templates" ]; then
  PKG_ROOT="$SCRIPT_DIR/../../.."
elif [ -n "${CLAUDE_PROJECT_DIR:-}" ] && [ -d "${CLAUDE_PROJECT_DIR}/node_modules/@jenga-ai/agent/templates" ]; then
  PKG_ROOT="${CLAUDE_PROJECT_DIR}/node_modules/@jenga-ai/agent"
else
  echo "Error: could not locate the jenga-agent package root (templates/ not found via monorepo checkout or node_modules/@jenga-ai/agent)." >&2
  exit 2
fi

PLAYBOOKS_DIR="$PKG_ROOT/skills/jenga/playbooks"
SKILLS_DIR="$PKG_ROOT/skills"

if [ ! -d "$PLAYBOOKS_DIR" ]; then
  echo "Error: playbooks directory not found at $PLAYBOOKS_DIR" >&2
  exit 2
fi

if ! command -v python3 >/dev/null 2>&1; then
  echo "Error: python3 is required by load-playbooks.sh" >&2
  exit 2
fi

PY_SCRIPT="$(mktemp -t load-playbooks-XXXXXX.py)"
trap 'rm -f "$PY_SCRIPT"' EXIT

cat > "$PY_SCRIPT" <<'PY'
import json
import os
import sys

playbooks_dir = sys.argv[1]
skills_dir = sys.argv[2]

REQUIRED_FIELDS = ["id", "name", "description", "keywords", "examples", "steps"]
LIST_FIELDS = ["keywords", "examples", "steps"]

catalog = []

try:
    filenames = sorted(
        f for f in os.listdir(playbooks_dir)
        if f.endswith(".json") and f != "schema.json"
    )
except OSError as e:
    print(f"Error: could not list {playbooks_dir}: {e}", file=sys.stderr)
    sys.exit(2)

for filename in filenames:
    path = os.path.join(playbooks_dir, filename)
    basename = filename[: -len(".json")]

    try:
        with open(path, encoding="utf-8") as fh:
            data = json.load(fh)
    except Exception as e:
        print(f"Warning: {path} is not valid JSON ({e}) — skipped", file=sys.stderr)
        continue

    if not isinstance(data, dict):
        print(f"Warning: {path} is not a JSON object — skipped", file=sys.stderr)
        continue

    missing = [f for f in REQUIRED_FIELDS if f not in data]
    if missing:
        print(f"Warning: {path} missing required field(s) {missing} — skipped", file=sys.stderr)
        continue

    bad_list = [
        f for f in LIST_FIELDS
        if not isinstance(data.get(f), list) or len(data.get(f)) == 0
    ]
    if bad_list:
        print(f"Warning: {path} field(s) {bad_list} must be non-empty lists — skipped", file=sys.stderr)
        continue

    if data["id"] != basename:
        print(
            f"Warning: {path} has id '{data['id']}' which does not match its filename "
            f"'{basename}.json' — skipped",
            file=sys.stderr,
        )
        continue

    missing_skills = [
        step for step in data["steps"]
        if not os.path.isfile(os.path.join(skills_dir, step, "SKILL.md"))
    ]
    if missing_skills:
        print(
            f"Warning: {path} references nonexistent skill(s) {missing_skills} "
            f"(no skills/<name>/SKILL.md found) — playbook skipped",
            file=sys.stderr,
        )
        continue

    catalog.append({
        "id": data["id"],
        "name": data["name"],
        "description": data["description"],
        "keywords": data["keywords"],
        "examples": data["examples"],
        "steps": data["steps"],
    })

print(json.dumps(catalog, indent=2))
PY

python3 "$PY_SCRIPT" "$PLAYBOOKS_DIR" "$SKILLS_DIR"
exit $?
