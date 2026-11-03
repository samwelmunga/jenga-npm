#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# skills/j-checklist/scripts/checklist-print.sh - print a pre-flight checklist registry (epic E67, story E67_S10,
# task E67_S10_T01)
#
# The read path of the j.checklist management surface. It renders the registry currently in force as a human-readable
# list: one situation, or every situation grouped under its own heading. It is the human counterpart of
# `scripts/checklist.sh list`, which emits five TAB-separated machine fields for the checker and the hook.
#
# READ-ONLY. It never writes the registry, never writes a tick and never runs an item's verify command.
#
# ---------------------------------------------------------------------------
# USAGE
# ---------------------------------------------------------------------------
#   checklist-print.sh                          every situation, grouped (same as --all)
#   checklist-print.sh --all [--run <run-id>]
#   checklist-print.sh <situation> [--run <run-id>]
#   checklist-print.sh -h | --help | help       print this usage on stdout, exit 0
#
# <situation> is a lifecycle phase: one of the base vocabulary (pre-commit, pre-task, pre-release, pre-reconcile) or a
# name declared in the loaded registry's own top-level "situations".
# --run <run-id> (or JENGA_CHECKLIST_RUN_ID) names the run whose run-scoped ticks are shown, as for checklist.sh.
#
# ---------------------------------------------------------------------------
# THE LINE FORM IS NOT IN THIS FILE
# ---------------------------------------------------------------------------
# Every character of an item line, a group heading and an empty-group line comes from the render template,
# templates/checklist-render.json (its own header documents the placeholders and the ranked_list constraint on the line
# form). This script only substitutes named placeholders into it, so changing how a list reads is a data edit.
#
# Template: JENGA_CHECKLIST_RENDER_TEMPLATE if set (test seam), else templates/checklist-render.json of the package
# this script ships in, else ./templates/checklist-render.json, else ./node_modules/@jenga-ai/agent/templates/
# checklist-render.json (the dual-path idiom).
#
# ---------------------------------------------------------------------------
# OUTPUT
# ---------------------------------------------------------------------------
#   <situation>   the items naming it, in registry order, one line each, no heading. The output is a valid
#                 `ranked_list` (templates/playbook-types.json): every line matches the type's per_line rule.
#   --all         for every known situation (base vocabulary first, then those the registry declares): the template's
#                 heading, then that situation's items, or the template's empty-group line when none names it. Groups
#                 are separated as the template says. Numbering restarts at 1 in each group, so a group never mixes
#                 situations; an item naming several situations appears once under each.
#   The template's ticked checkbox is used when `checklist.sh list` reports the item as ticked, its unticked one
#   otherwise. Tick state is read through that command (the single tick-state seam), pinned to the exact registry file
#   being rendered, so what is printed is what the checker would see. Output is assembled in full and printed once:
#   stdout is never partial.
#
# ---------------------------------------------------------------------------
# REGISTRY RESOLUTION (the same as scripts/checklist.sh, which this script does not modify)
# ---------------------------------------------------------------------------
#   project instance  JENGA_CHECKLISTS_FILE if set, else <`scripts/resolve-root.sh get configs`>/checklists.json
#   else the shipped default  JENGA_CHECKLISTS_DEFAULT_FILE if set, else <package>/templates/checklists.json, else
#   ./templates/checklists.json, else ./node_modules/@jenga-ai/agent/templates/checklists.json
# Selection is whole-file; nothing is merged. The registry is validated by scripts/validate-checklists.sh before
# anything is printed.
#
# ---------------------------------------------------------------------------
# EXIT CODES
# ---------------------------------------------------------------------------
#   0  printed (a known situation that no item names prints nothing in single-situation form, exit 0; no registry
#      file at all prints nothing on stdout, exit 0, with one note on stderr)
#   1  the registry is invalid or unreadable: the validator's own problem lines are on stderr, stdout is empty
#   2  usage error
#   3  unknown situation (the same exit as `checklist.sh list`); stdout is empty
#   4  the render template or a helper script could not be found, or the template is malformed
#   5  the project configs directory could not be resolved
#
# Compatible with macOS bash 3.2.
# ---------------------------------------------------------------------------

set -u
export LC_ALL=C

SELF="$(basename "$0")"
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PACKAGE_ROOT="$(cd "$SELF_DIR/../../.." && pwd)"
TEMPLATE_REL="templates/checklist-render.json"
DEFAULT_REL="templates/checklists.json"

usage() {
  cat <<'EOF'
usage:
  checklist-print.sh [--all] [--run <run-id>]       every situation, grouped
  checklist-print.sh <situation> [--run <run-id>]   one situation
  checklist-print.sh -h | --help | help
EOF
}

# Prints the first existing path among <package>/$1, ./$1 and ./node_modules/@jenga-ai/agent/$1 (nothing if none).
find_in_package() {
  local rel="$1" candidate
  for candidate in "$PACKAGE_ROOT/$rel" "$rel" "node_modules/@jenga-ai/agent/$rel"; do
    if [ -f "$candidate" ]; then
      printf '%s' "$candidate"
      return 0
    fi
  done
  return 1
}

SITUATION=""
ALL=0
RUN_ID="${JENGA_CHECKLIST_RUN_ID:-}"

while [ "$#" -gt 0 ]; do
  case "$1" in
    -h | --help | help)
      usage
      exit 0
      ;;
    --all)
      ALL=1
      shift
      ;;
    --run)
      if [ "$#" -lt 2 ] || [ -z "$2" ]; then
        printf '%s: --run needs a non-empty value\n' "$SELF" >&2
        exit 2
      fi
      RUN_ID="$2"
      shift 2
      ;;
    --run=*)
      RUN_ID="${1#--run=}"
      if [ -z "$RUN_ID" ]; then
        printf '%s: --run needs a non-empty value\n' "$SELF" >&2
        exit 2
      fi
      shift
      ;;
    -*)
      printf '%s: unknown option "%s"\n' "$SELF" "$1" >&2
      usage >&2
      exit 2
      ;;
    *)
      if [ -n "$SITUATION" ]; then
        printf '%s: takes at most one <situation>\n' "$SELF" >&2
        usage >&2
        exit 2
      fi
      SITUATION="$1"
      shift
      ;;
  esac
done

if [ "$ALL" -eq 1 ] && [ -n "$SITUATION" ]; then
  printf '%s: --all and a <situation> are mutually exclusive\n' "$SELF" >&2
  usage >&2
  exit 2
fi

# --- helpers --------------------------------------------------------------------------------------------------

CHECKLIST_SH="$(find_in_package scripts/checklist.sh)" || {
  printf '%s: scripts/checklist.sh not found (looked in the package, ./scripts and node_modules/@jenga-ai/agent/scripts)\n' "$SELF" >&2
  exit 4
}
VALIDATOR="$(find_in_package scripts/validate-checklists.sh)" || {
  printf '%s: scripts/validate-checklists.sh not found\n' "$SELF" >&2
  exit 4
}
RESOLVE_ROOT="$(find_in_package scripts/resolve-root.sh)" || {
  printf '%s: scripts/resolve-root.sh not found\n' "$SELF" >&2
  exit 4
}

if [ -n "${JENGA_CHECKLIST_RENDER_TEMPLATE:-}" ]; then
  TEMPLATE="$JENGA_CHECKLIST_RENDER_TEMPLATE"
else
  TEMPLATE="$(find_in_package "$TEMPLATE_REL")" || TEMPLATE=""
fi
if [ -z "$TEMPLATE" ] || [ ! -f "$TEMPLATE" ]; then
  printf '%s: render template %s not found (looked in the package, ./templates and node_modules/@jenga-ai/agent/templates)\n' \
    "$SELF" "$TEMPLATE_REL" >&2
  exit 4
fi

# --- registry selection (mirrors checklist.sh select_registry) ---------------------------------------------------

if [ -n "${JENGA_CHECKLISTS_FILE:-}" ]; then
  project_file="$JENGA_CHECKLISTS_FILE"
else
  if ! configs="$(bash "$RESOLVE_ROOT" get configs)" || [ -z "$configs" ]; then
    printf '%s: could not resolve the project configs directory via resolve-root.sh\n' "$SELF" >&2
    exit 5
  fi
  project_file="$configs/checklists.json"
fi

REGISTRY=""
if [ -f "$project_file" ]; then
  REGISTRY="$project_file"
else
  if [ -n "${JENGA_CHECKLISTS_DEFAULT_FILE:-}" ]; then
    default_file="$JENGA_CHECKLISTS_DEFAULT_FILE"
  else
    default_file="$(find_in_package "$DEFAULT_REL")" || default_file=""
  fi
  if [ -n "$default_file" ] && [ -f "$default_file" ]; then
    REGISTRY="$default_file"
  fi
fi

if [ -z "$REGISTRY" ]; then
  printf '%s: no checklist registry found (neither a project instance nor the shipped default); nothing to print\n' "$SELF" >&2
  exit 0
fi

# Validate first. The validator's problem lines (stderr) are passed through untouched; nothing reaches stdout.
if ! bash "$VALIDATOR" "$REGISTRY" >/dev/null; then
  printf '%s: invalid registry %s; refusing to print (fix the problems above)\n' "$SELF" "$REGISTRY" >&2
  exit 1
fi

# --- render ---------------------------------------------------------------------------------------------------------

python3 - "$REGISTRY" "$TEMPLATE" "$CHECKLIST_SH" "$SITUATION" "$ALL" "$RUN_ID" "$SELF" <<'PY'
import json
import os
import re
import subprocess
import sys

registry_path, template_path, checklist_sh, situation, all_flag, run_id, self_name = sys.argv[1:8]

BASE_SITUATIONS = ["pre-commit", "pre-task", "pre-release", "pre-reconcile"]
ITEM_PLACEHOLDERS = {"n", "id", "text", "kind", "enforcement", "tick_scope", "checkbox", "tick_state"}
HEADING_PLACEHOLDERS = {"situation"}


def fail(code, message):
    sys.stderr.write("%s: %s\n" % (self_name, message))
    sys.exit(code)


def load_json(path, what, code):
    try:
        with open(path, "rb") as fh:
            return json.loads(fh.read().decode("utf-8"))
    except (OSError, ValueError) as exc:
        fail(code, "cannot read %s %s: %s" % (what, path, exc))


doc = load_json(registry_path, "registry", 1)
tpl = load_json(template_path, "render template", 4)


def template_string(key):
    value = tpl.get(key) if isinstance(tpl, dict) else None
    if not isinstance(value, str):
        fail(4, "render template %s: \"%s\" is missing or not a string" % (template_path, key))
    return value


def check_placeholders(key, text, allowed):
    for name in re.findall(r"\{([^{}]*)\}", text):
        if name not in allowed:
            fail(4, "render template %s: \"%s\" uses unknown placeholder {%s} (known: %s)"
                 % (template_path, key, name, ", ".join(sorted(allowed))))


item_tpl = template_string("item")
heading_tpl = template_string("group_heading")
empty_tpl = template_string("empty_group")
check_placeholders("item", item_tpl, ITEM_PLACEHOLDERS)
check_placeholders("group_heading", heading_tpl, HEADING_PLACEHOLDERS)
check_placeholders("empty_group", empty_tpl, set())

boxes = tpl.get("checkbox")
if not isinstance(boxes, dict) or not isinstance(boxes.get("ticked"), str) or not isinstance(boxes.get("unticked"), str):
    fail(4, "render template %s: \"checkbox\" must be an object with string \"ticked\" and \"unticked\"" % template_path)
gap = tpl.get("blank_lines_between_groups", 1)
if isinstance(gap, bool) or not isinstance(gap, int) or gap < 0:
    fail(4, "render template %s: \"blank_lines_between_groups\" must be a non-negative integer" % template_path)


def fill(template, values):
    """Single-pass placeholder substitution, so substituted text is never re-scanned."""
    return re.sub(r"\{([^{}]*)\}", lambda m: values[m.group(1)], template)


def flat(value):
    return " ".join(str(value).split())


declared = [s for s in doc.get("situations", []) if s not in BASE_SITUATIONS]
known = BASE_SITUATIONS + declared

if situation and situation not in known:
    sys.stderr.write(
        '%s: unknown situation "%s" (known: %s; extensions come from the "situations" array of %s)\n'
        % (self_name, situation, ", ".join(known), registry_path))
    sys.exit(3)

targets = [situation] if situation else known

# Tick state comes from the checker (the single seam), pinned to the file being rendered.
child_env = dict(os.environ)
child_env["JENGA_CHECKLISTS_FILE"] = registry_path


def tick_states(sit):
    """id -> the checker's tick state for the items naming `sit`. Unreadable degrades to unticked, with a warning."""
    cmd = ["bash", checklist_sh, "list", sit]
    if run_id:
        cmd += ["--run", run_id]
    try:
        proc = subprocess.run(cmd, env=child_env, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                              stderr=subprocess.PIPE, timeout=60)
    except (OSError, subprocess.SubprocessError) as exc:
        sys.stderr.write("%s: warning: tick state is unavailable (%s); showing every item as unticked\n" % (self_name, exc))
        return {}
    if proc.returncode != 0:
        sys.stderr.write("%s: warning: checklist.sh list %s failed (exit %d); showing its items as unticked\n"
                         % (self_name, sit, proc.returncode))
        return {}
    states = {}
    for line in proc.stdout.decode("utf-8", "replace").split("\n"):
        fields = line.split("\t")
        if len(fields) >= 5:
            states[fields[0]] = fields[4]
    return states


def item_lines(sit):
    rows = [item for item in doc["items"] if sit in item["situations"]]
    if not rows:
        return []
    states = tick_states(sit)
    lines = []
    for position, item in enumerate(rows, 1):
        state = states.get(item["id"], "unticked")
        values = {
            "n": str(position),
            "id": item["id"],
            "text": flat(item["text"]),
            "kind": item["kind"],
            "enforcement": item["enforcement"],
            "tick_scope": item["tick_scope"],
            "checkbox": boxes["ticked"] if state.startswith("ticked") else boxes["unticked"],
            "tick_state": state,
        }
        lines.append(fill(item_tpl, values))
    return lines


out = []
if situation:
    out.extend(item_lines(situation))
else:
    for index, sit in enumerate(targets):
        if index > 0:
            out.extend([""] * gap)
        out.append(fill(heading_tpl, {"situation": sit}))
        group = item_lines(sit)
        out.extend(group if group else [empty_tpl])

if out:
    sys.stdout.write("\n".join(out) + "\n")
PY
exit $?
