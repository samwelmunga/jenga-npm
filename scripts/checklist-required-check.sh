#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# scripts/checklist-required-check.sh - required checklist ids versus the effective registry (E99_S04_T03)
#
# Some shipped scripts hard-require checklist item ids (today scripts/foreground-preflight.sh needs
# checkin-run-before-dispatch and dispatch-cost-and-cadence, and exits 12 without them). Those ids are declared once,
# in templates/checklist-required-ids.json. This script compares that declaration with the registry the checker
# actually reads and names each required id the registry lacks, so the gap shows up in `jenga doctor` instead of as an
# exit 12 in the middle of a /jenga run.
#
# The registry is selected by `scripts/checklist.sh registry`, i.e. checklist.sh's own select_registry: the project
# instance (<configs>/checklists.json) when it exists, else the shipped default (templates/checklists.json), one whole
# file, never merged. This script has no copy of that rule. It only reads: it never writes the registry, never ticks,
# and never runs a verify command.
#
# ---------------------------------------------------------------------------
# USAGE
# ---------------------------------------------------------------------------
#   scripts/checklist-required-check.sh            compare and report
#   scripts/checklist-required-check.sh -h | --help | help   print this usage on stdout, exit 0
#
# Run it from the project whose registry should be checked: checklist.sh resolves the configs directory from the
# working directory (scripts/resolve-root.sh), the same way every other checklist call does. `jenga doctor` runs it
# with the consumer root as its working directory.
#
# ---------------------------------------------------------------------------
# OUTPUT
# ---------------------------------------------------------------------------
#   STDOUT: one line per missing id, in declaration order, four TAB-separated fields:
#       missing <TAB> <id> <TAB> <required_by> <TAB> <registry>
#   <registry> is the path checklist.sh selected, or "none" when there is no registry file at all. Nothing is printed
#   when no id is missing. STDERR carries diagnostics only.
#
# ---------------------------------------------------------------------------
# EXIT CODES
# ---------------------------------------------------------------------------
#   0    every required id is an item of the effective registry (nothing printed)
#   10   at least one required id is missing (one "missing" line each on stdout)
#   1    the declaration or the selected registry is unreadable or not in the expected shape, or checklist.sh could
#        not resolve the configs directory
#   2    usage error (any argument other than -h/--help/help)
#   3    scripts/checklist.sh was not found next to this script
#   4    python3 is not installed
#   A caller that only distinguishes zero from non-zero is on the safe side; `jenga doctor` reports 10 as a warning and
#   any other non-zero as "could not check", and never changes its own exit code for either.
#
# ---------------------------------------------------------------------------
# ENVIRONMENT (test seams; unset in normal use)
# ---------------------------------------------------------------------------
#   JENGA_CHECKLIST_REQUIRED_FILE   read this declaration instead of <package>/templates/checklist-required-ids.json
#   checklist.sh's own seams (JENGA_PROJECT_ROOT, JENGA_CHECKLISTS_FILE, JENGA_CHECKLISTS_DEFAULT_FILE) pass through,
#   because the registry is selected by checklist.sh itself.
#
# Compatible with macOS bash 3.2. Every child process is started with stdin from /dev/null.
# ---------------------------------------------------------------------------

set -u

SELF="checklist-required-check.sh"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PACKAGE_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

usage() {
  cat <<'USAGE'
usage:
  checklist-required-check.sh                 report required checklist ids the effective registry lacks
  checklist-required-check.sh -h | --help | help

stdout: "missing<TAB><id><TAB><required_by><TAB><registry>" per missing id
exit:   0 none missing, 10 some missing, 1 unreadable declaration or registry, 2 usage,
        3 checklist.sh not found, 4 python3 missing
USAGE
}

if [ "$#" -gt 0 ]; then
  case "$1" in
    -h | --help | help)
      usage
      exit 0
      ;;
    *)
      printf '%s: unexpected argument "%s"\n' "$SELF" "$1" >&2
      usage >&2
      exit 2
      ;;
  esac
fi

if ! command -v python3 >/dev/null 2>&1; then
  printf '%s: python3 is required but was not found on PATH\n' "$SELF" >&2
  exit 4
fi

CHECKLIST_SH="$SCRIPT_DIR/checklist.sh"
if [ ! -f "$CHECKLIST_SH" ]; then
  printf '%s: %s not found\n' "$SELF" "$CHECKLIST_SH" >&2
  exit 3
fi

DECLARATION="${JENGA_CHECKLIST_REQUIRED_FILE:-$PACKAGE_ROOT/templates/checklist-required-ids.json}"
if [ ! -f "$DECLARATION" ]; then
  printf '%s: the required-id declaration %s does not exist\n' "$SELF" "$DECLARATION" >&2
  exit 1
fi

# The one registry selection: checklist.sh's own. Its stderr (for instance an unresolvable configs directory)
# passes through unchanged.
registry="$(bash "$CHECKLIST_SH" registry </dev/null)"
status=$?
if [ "$status" -ne 0 ]; then
  printf '%s: checklist.sh registry failed (exit %s); the registry could not be selected\n' "$SELF" "$status" >&2
  exit 1
fi

python3 - "$DECLARATION" "$registry" <<'PY'
import json
import sys

SELF = "checklist-required-check.sh"
declaration_path, registry_path = sys.argv[1], sys.argv[2]


def fail(message):
    sys.stderr.write("%s: %s\n" % (SELF, message))
    sys.exit(1)


def clean(value):
    # One field per column, one line per id, whatever a file contains.
    return " ".join(str(value).replace("\t", " ").split())


try:
    with open(declaration_path, encoding="utf-8") as handle:
        declaration = json.load(handle)
except (OSError, ValueError) as exc:
    fail("cannot read the required-id declaration %s: %s" % (declaration_path, exc))

required = declaration.get("required") if isinstance(declaration, dict) else None
if not isinstance(required, list):
    fail('%s has no "required" array' % declaration_path)
for entry in required:
    if not (isinstance(entry, dict) and isinstance(entry.get("id"), str) and entry["id"]
            and isinstance(entry.get("required_by"), str) and entry["required_by"]):
        fail('%s: every "required" entry needs a non-empty "id" and "required_by"' % declaration_path)

present = set()
if registry_path:
    try:
        with open(registry_path, encoding="utf-8") as handle:
            registry = json.load(handle)
    except (OSError, ValueError) as exc:
        fail("cannot read the checklist registry %s: %s" % (registry_path, exc))
    items = registry.get("items") if isinstance(registry, dict) else None
    if not isinstance(items, list):
        fail('the checklist registry %s has no "items" array' % registry_path)
    present = {item.get("id") for item in items if isinstance(item, dict)}

missing = [entry for entry in required if entry["id"] not in present]
for entry in missing:
    sys.stdout.write("missing\t%s\t%s\t%s\n" % (
        clean(entry["id"]), clean(entry["required_by"]), clean(registry_path) if registry_path else "none"))
sys.exit(10 if missing else 0)
PY
exit $?
