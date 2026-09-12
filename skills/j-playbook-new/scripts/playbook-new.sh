#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# skills/j-playbook-new/scripts/playbook-new.sh
#
# Deterministic helper behind the `j.playbook-new` guided wizard (E53_S09_T02). Per CLAUDE.md's
# "Scripts Over Inline Logic" principle, every mechanical step of the wizard -- id slug/uniqueness
# validation, skill-name validation against the real catalog, and the JSON write itself -- lives
# here rather than as inline agent prose in skills/j-playbook-new/SKILL.md. The agent driving the
# wizard calls this script once per step and interprets its JSON result; it never re-implements
# any of this logic itself.
#
# Reuses, never re-implements, the two existing single-source-of-truth catalogs:
#   - skills/jenga/scripts/load-playbooks.sh   (merged builtin+project playbook catalog, E53_S09_T01)
#   - skills/jenga/scripts/load-nl-catalog.sh  (the real, generated skill catalog /jenga's own
#                                                natural-language matching already uses)
#
# ---------------------------------------------------------------------------
# USAGE
# ---------------------------------------------------------------------------
#   playbook-new.sh validate-id <id>
#
# Checks <id> is slug-safe (the same pattern skills/jenga/playbooks/schema.json requires:
# ^[a-z0-9]+(-[a-z0-9]+)*$) and does not collide with any id already present in the merged catalog
# (skills/jenga/scripts/load-playbooks.sh, no arguments -- built-in and project sources both) OR an
# existing (possibly currently invalid, and therefore catalog-invisible) file at
# project/.playbooks/<id>.json. Prints exactly one JSON object to stdout:
#   {"valid": true}
#   {"valid": false, "reason": "<human-readable reason>"}
# Exit 0 for BOTH outcomes -- mirrors load-playbooks.sh's own `lookup` mode convention of
# reserving a non-zero exit for usage/setup errors only, never for a normal negative validation
# result the caller is expected to branch on.
#
#   playbook-new.sh validate-skill <name>
#
# Checks <name> is a real, currently-loadable skill per skills/jenga/scripts/load-nl-catalog.sh's
# generated catalog -- the exact source /jenga's own natural-language matching already uses, never
# a hand-maintained list. Prints:
#   {"valid": true}
#   {"valid": false, "reason": "..."}
# Exit 0 for both outcomes, same convention as validate-id.
#
#   playbook-new.sh write
#
# Reads a single JSON object from stdin:
#   {"id": "...", "name": "...", "description": "...", "keywords": ["..."],
#    "examples": ["..."], "steps": ["...", "..."]}
# Pre-validates it against the same required-field / non-empty-list / steps-shape rules
# skills/jenga/playbooks/schema.json declares (id slug pattern, all six required fields present,
# keywords/examples non-empty lists of non-empty strings, steps a list of >= 2 non-empty strings --
# this wizard authors bare-string steps only, per this task's v1 scope cut) BEFORE writing anything
# to disk. This is a defensive, redundant pre-check only -- the actual source of truth for validity
# remains load-playbooks.sh's own load-time validation, which the wizard's own self-validation step
# (SKILL.md step 8) always runs afterward regardless of this result. Creates project/.playbooks/ if
# it does not yet exist, and refuses to overwrite an already-existing file for the same id. On
# success, writes project/.playbooks/<id>.json (pretty-printed) and prints
# {"written": true, "path": "<absolute path>"}. On any shape/overwrite failure, prints
# {"written": false, "reason": "..."} and writes nothing. Exit 0 for both outcomes.
#
# ---------------------------------------------------------------------------
# PROJECT ROOT RESOLUTION
# ---------------------------------------------------------------------------
# Honors JENGA_PLAYBOOKS_TEST_ROOT -- the SAME override variable load-playbooks.sh itself defines
# (see that script's header "TESTING OVERRIDE"), not a second, script-specific one -- so a fixture
# pointing this script at a throwaway project root also makes load-playbooks.sh (invoked internally
# by validate-id, and by the wizard's own later self-validation step) resolve project/.playbooks/
# under that same root. Never set this variable in a real invocation.
#
# ---------------------------------------------------------------------------
# EXIT CODES
# ---------------------------------------------------------------------------
#   0   a result JSON object was printed to stdout (whether valid:true/false or written:true/false)
#   2   usage error, or a real setup failure (missing python3, the sibling load-playbooks.sh /
#       load-nl-catalog.sh scripts could not be located, one of them exited non-zero, or the
#       project/.playbooks/ directory could not be created)
#
# ---------------------------------------------------------------------------

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOAD_PLAYBOOKS="$SCRIPT_DIR/../../jenga/scripts/load-playbooks.sh"
LOAD_NL_CATALOG="$SCRIPT_DIR/../../jenga/scripts/load-nl-catalog.sh"

if [ ! -f "$LOAD_PLAYBOOKS" ]; then
  echo "Error: could not locate load-playbooks.sh at $LOAD_PLAYBOOKS" >&2
  exit 2
fi
if [ ! -f "$LOAD_NL_CATALOG" ]; then
  echo "Error: could not locate load-nl-catalog.sh at $LOAD_NL_CATALOG" >&2
  exit 2
fi

if ! command -v python3 >/dev/null 2>&1; then
  echo "Error: python3 is required by playbook-new.sh" >&2
  exit 2
fi

if [ -n "${JENGA_PLAYBOOKS_TEST_ROOT:-}" ]; then
  # Test-only override -- see header "PROJECT ROOT RESOLUTION" above. Never set in a real
  # invocation.
  PROJECT_DIR="$JENGA_PLAYBOOKS_TEST_ROOT"
else
  PROJECT_DIR="${JENGA_PROJECT_DIR:-${CLAUDE_PROJECT_DIR:-$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel 2>/dev/null || pwd)}}"
fi
PLAYBOOKS_TARGET_DIR="$PROJECT_DIR/project/.playbooks"

if [ $# -lt 1 ]; then
  echo "Usage: $(basename "$0") <validate-id|validate-skill|write> [args...]" >&2
  exit 2
fi
MODE="$1"
shift

PY_SCRIPT="$(mktemp -t playbook-new-XXXXXX.py)"
trap 'rm -f "$PY_SCRIPT"' EXIT

cat > "$PY_SCRIPT" <<'PY'
import json
import os
import re
import sys

mode = sys.argv[1]
SLUG_RE = re.compile(r'^[a-z0-9]+(-[a-z0-9]+)*$')


def emit(obj):
    print(json.dumps(obj))


if mode == "validate-id":
    target_id = sys.argv[2]
    playbooks_target_dir = sys.argv[3]

    if not SLUG_RE.match(target_id):
        emit({
            "valid": False,
            "reason": (
                f"'{target_id}' is not slug-safe -- must match ^[a-z0-9]+(-[a-z0-9]+)*$ "
                f"(lowercase letters, digits, single hyphens between segments)"
            ),
        })
        sys.exit(0)

    existing_file = os.path.join(playbooks_target_dir, f"{target_id}.json")
    if os.path.isfile(existing_file):
        emit({
            "valid": False,
            "reason": (
                f"a file already exists at {existing_file} -- choose a different id or edit "
                f"that file directly"
            ),
        })
        sys.exit(0)

    try:
        catalog = json.load(sys.stdin)
    except Exception as e:
        emit({
            "valid": False,
            "reason": f"could not read the playbook catalog to check for collisions ({e})",
        })
        sys.exit(0)

    for entry in catalog:
        if entry.get("id") == target_id:
            src = entry.get("source", "unknown")
            emit({
                "valid": False,
                "reason": (
                    f"id '{target_id}' collides with an already-loaded {src} playbook (see "
                    f"skills/jenga/scripts/load-playbooks.sh's merged catalog) -- choose a "
                    f"different id"
                ),
            })
            sys.exit(0)

    emit({"valid": True})
    sys.exit(0)

elif mode == "validate-skill":
    target_name = sys.argv[2]

    try:
        nl_catalog = json.load(sys.stdin)
    except Exception as e:
        emit({"valid": False, "reason": f"could not read the generated skill catalog ({e})"})
        sys.exit(0)

    for entry in nl_catalog:
        if entry.get("name") == target_name:
            emit({"valid": True})
            sys.exit(0)

    emit({
        "valid": False,
        "reason": (
            f"'{target_name}' is not a recognized skill directory name in the generated skill "
            f"catalog (skills/jenga/scripts/load-nl-catalog.sh) -- check spelling and the exact "
            f"directory-name form the catalog currently lists"
        ),
    })
    sys.exit(0)

elif mode == "write":
    playbooks_target_dir = sys.argv[2]

    try:
        payload = json.load(sys.stdin)
    except Exception as e:
        emit({"written": False, "reason": f"stdin was not valid JSON ({e})"})
        sys.exit(0)

    if not isinstance(payload, dict):
        emit({"written": False, "reason": "stdin JSON must be an object"})
        sys.exit(0)

    required_fields = ["id", "name", "description", "keywords", "examples", "steps"]
    missing = [f for f in required_fields if f not in payload]
    if missing:
        emit({"written": False, "reason": f"missing required field(s) {missing}"})
        sys.exit(0)

    target_id = payload["id"]
    if not isinstance(target_id, str) or not SLUG_RE.match(target_id):
        emit({
            "written": False,
            "reason": f"id '{target_id}' is not slug-safe -- must match ^[a-z0-9]+(-[a-z0-9]+)*$",
        })
        sys.exit(0)

    for field in ("name", "description"):
        if not isinstance(payload[field], str) or not payload[field]:
            emit({"written": False, "reason": f"'{field}' must be a non-empty string"})
            sys.exit(0)

    for field in ("keywords", "examples"):
        value = payload[field]
        if (
            not isinstance(value, list)
            or len(value) == 0
            or not all(isinstance(v, str) and v for v in value)
        ):
            emit({
                "written": False,
                "reason": f"'{field}' must be a non-empty list of non-empty strings",
            })
            sys.exit(0)

    steps = payload["steps"]
    if not isinstance(steps, list) or len(steps) < 2 or not all(isinstance(s, str) and s for s in steps):
        emit({
            "written": False,
            "reason": (
                "'steps' must be a list of at least 2 non-empty strings (bare skill-name steps "
                "only -- this wizard authors no StepObject fields, per this task's v1 scope cut)"
            ),
        })
        sys.exit(0)

    target_file = os.path.join(playbooks_target_dir, f"{target_id}.json")
    if os.path.isfile(target_file):
        emit({
            "written": False,
            "reason": f"a file already exists at {target_file} -- refusing to overwrite",
        })
        sys.exit(0)

    try:
        os.makedirs(playbooks_target_dir, exist_ok=True)
    except OSError as e:
        print(f"Error: could not create {playbooks_target_dir}: {e}", file=sys.stderr)
        sys.exit(2)

    ordered = {
        "id": target_id,
        "name": payload["name"],
        "description": payload["description"],
        "keywords": payload["keywords"],
        "examples": payload["examples"],
        "steps": steps,
    }

    try:
        with open(target_file, "w", encoding="utf-8") as fh:
            json.dump(ordered, fh, indent=2)
            fh.write("\n")
    except OSError as e:
        print(f"Error: could not write {target_file}: {e}", file=sys.stderr)
        sys.exit(2)

    emit({"written": True, "path": os.path.abspath(target_file)})
    sys.exit(0)

else:
    print(f"Error: unrecognized mode '{mode}' (usage: validate-id|validate-skill|write)", file=sys.stderr)
    sys.exit(2)
PY

case "$MODE" in
  validate-id)
    if [ $# -lt 1 ] || [ -z "${1:-}" ]; then
      echo "Usage: $(basename "$0") validate-id <id>" >&2
      exit 2
    fi
    TARGET_ID="$1"
    if ! CATALOG_JSON="$("$LOAD_PLAYBOOKS")"; then
      echo "Error: load-playbooks.sh failed while checking id '$TARGET_ID' for collisions" >&2
      exit 2
    fi
    printf '%s' "$CATALOG_JSON" | python3 "$PY_SCRIPT" validate-id "$TARGET_ID" "$PLAYBOOKS_TARGET_DIR"
    ;;
  validate-skill)
    if [ $# -lt 1 ] || [ -z "${1:-}" ]; then
      echo "Usage: $(basename "$0") validate-skill <name>" >&2
      exit 2
    fi
    TARGET_NAME="$1"
    if ! NL_CATALOG_JSON="$("$LOAD_NL_CATALOG")"; then
      echo "Error: load-nl-catalog.sh failed while validating skill name '$TARGET_NAME'" >&2
      exit 2
    fi
    printf '%s' "$NL_CATALOG_JSON" | python3 "$PY_SCRIPT" validate-skill "$TARGET_NAME"
    ;;
  write)
    python3 "$PY_SCRIPT" write "$PLAYBOOKS_TARGET_DIR"
    ;;
  *)
    echo "Error: unrecognized mode '$MODE' (usage: $(basename "$0") <validate-id|validate-skill|write> [args...])" >&2
    exit 2
    ;;
esac
