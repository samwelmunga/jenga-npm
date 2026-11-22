#!/usr/bin/env bash
# scripts/checklist-required-merge.sh - add the required checklist ids an existing project instance lacks (E99_S04_T05)
#
# Usage:
#   checklist-required-merge.sh --consumer-root <dir> [--package-root <dir>] [--dry-run]
#   checklist-required-merge.sh -h | --help
#
# Why: scripts/checklist.sh reads exactly one registry, the project instance <configs>/checklists.json when it exists,
# else the shipped default (templates/checklists.json). Some shipped scripts hard-require item ids (declared in
# templates/checklist-required-ids.json, E99_S04_T03); a consumer whose instance predates them keeps failing (for
# example foreground-preflight.sh exits 12). Decision E99_S04_T02 (option 3): at postinstall and `jenga sync`
# (lib/sync.js runs this script for both), add to an EXISTING instance only the required ids it lacks.
#
# What it does:
#   - Resolves the configs directory with scripts/resolve-root.sh get configs, run from --consumer-root with
#     JENGA_PROJECT_ROOT unset, so the consumer root decides; the result must lie inside the consumer root.
#     Containment is checked on physical paths (cd -P / pwd -P, portable to macOS and GNU): a configs path that
#     leaves the root through ".." or through a symlinked directory is refused (exit 1); a symlinked configs
#     directory whose target lies inside the root is allowed, and the instance is then written at its physical path.
#     A checklists.json that is itself a symlink is never followed (exit 4), wherever it points.
#   - Only a configs path the operating system resolves as a whole can hold an instance. When any component of it
#     does not exist (for example "not/yet/there", or "missing/../link": the OS fails on "missing" and never reaches
#     "link"), the configs directory does not exist and the script exits 0 with nothing written. The unresolvable
#     part is never normalised as text into an address. Its text form is only checked for containment first, so a
#     path that leaves the root even as text (for example "not/yet/../../../escape-new") is still refused (exit 1).
#   - No instance: does nothing, prints nothing, exits 0. It never creates an instance (the shipped default applies).
#   - Reads the declared ids from <package>/templates/checklist-required-ids.json and each missing item's definition
#     from <package>/templates/checklists.json, copied as the shipped default writes it (only its indentation is
#     adapted to the instance). No provenance key is added: the item is the shipped item, unchanged.
#   - The new items are inserted as text after the last element of the instance's top-level "items" array. Every
#     other byte of the instance stays as it was: no other item is edited, reordered or removed, top-level keys
#     other than "items" are carried through, and an id the instance already holds is never overwritten even when
#     its fields differ from the shipped item. A shipped item that is not required is never added.
#   - Writes under scripts/with-lock.sh on the instance: a candidate file in the same directory, a structural
#     self-check (the candidate parses, its items are the old items followed by the added ones, its other keys are
#     unchanged), scripts/validate-checklists.sh on the candidate, then `mv` over the instance. Any failure removes
#     the candidate and leaves the instance byte-identical.
#   - --dry-run builds and validates the candidate in a throwaway directory under $TMPDIR, prints "would add <id>"
#     lines and writes nothing in the consumer tree (no file, no directory, no lock).
#   - A second run on a merged instance prints nothing and writes nothing.
#   - When --consumer-root is the package itself it prints "skipped: consumer root is the package itself", exits 0.
#
# Output (stdout): one "added <id>" (or "would add <id>") line per added id, in declaration order; nothing when no id
# is missing or there is no instance. Diagnostics go to stderr.
#
# Exit codes:
#   0  done: ids added, would be added (--dry-run), or nothing to do (no instance, nothing missing, package itself;
#      a configs path with a missing component is "no instance" once its text form passes the containment check)
#   1  the configs directory could not be resolved (resolve-root.sh failed, an existing component is not a directory,
#      or a dangling symlink stands where a directory should be), or it lies outside the consumer root: its physical
#      path (after ".." and symlinks) when the whole path exists; when a component is missing, the physical path of
#      the existing leading part followed by the rest normalised as text; nothing is written anywhere
#   2  usage error
#   3  the package source is unusable: python3 or a helper script is missing, the declaration or the shipped default
#      is missing or malformed, or the shipped default lacks a declared id (a packaging regression)
#   4  the instance is unusable: not a regular file (a symlinked checklists.json counts as not regular), not valid
#      JSON, no top-level "items" array, a duplicate top-level key, or it fails scripts/validate-checklists.sh before
#      any change; left untouched
#   5  the candidate failed the self-check or scripts/validate-checklists.sh; the instance is left untouched
#   6  the write failed: the lock could not be acquired, or the candidate could not be created or moved into place
#
# Internal: --apply-locked --instance <file> is how the script re-invokes itself under scripts/with-lock.sh. It is not
# for direct use.
#
# Compatible with macOS bash 3.2. Every child process gets stdin from /dev/null.
set -u

ME="checklist-required-merge.sh"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
SCRIPT_PATH="$SCRIPT_DIR/$(basename -- "${BASH_SOURCE[0]}")"

usage() { sed -n '2,/^set -u$/p' "$SCRIPT_PATH" | sed -e '$d' -e 's/^# \{0,1\}//'; }
die() { local code="$1"; shift; printf '%s: %s\n' "$ME" "$*" >&2; exit "$code"; }

CONSUMER=""; PACKAGE_ROOT=""; DRY=0; APPLY=0; INSTANCE_ARG=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --consumer-root) [ "$#" -ge 2 ] || die 2 "--consumer-root needs a value"; CONSUMER="$2"; shift 2 ;;
    --package-root)  [ "$#" -ge 2 ] || die 2 "--package-root needs a value"; PACKAGE_ROOT="$2"; shift 2 ;;
    --dry-run)       DRY=1; shift ;;
    --apply-locked)  APPLY=1; shift ;;
    --instance)      [ "$#" -ge 2 ] || die 2 "--instance needs a value"; INSTANCE_ARG="$2"; shift 2 ;;
    -h|--help)       usage; exit 0 ;;
    *) printf '%s: unknown argument "%s"\n' "$ME" "$1" >&2; usage >&2; exit 2 ;;
  esac
done
[ -n "$CONSUMER" ] && [ -d "$CONSUMER" ] || die 2 "--consumer-root must be an existing directory"
if [ -n "$PACKAGE_ROOT" ] && [ ! -d "$PACKAGE_ROOT" ]; then die 2 "--package-root must be an existing directory"; fi
[ -n "$PACKAGE_ROOT" ] || PACKAGE_ROOT="$SCRIPT_DIR/.."
CONSUMER="$(cd "$CONSUMER" && pwd -P)"; PACKAGE_ROOT="$(cd "$PACKAGE_ROOT" && pwd -P)"
if [ "$CONSUMER" = "$PACKAGE_ROOT" ]; then echo "skipped: consumer root is the package itself"; exit 0; fi

command -v python3 >/dev/null 2>&1 || die 3 "python3 is required but was not found on PATH"
VALIDATOR="$SCRIPT_DIR/validate-checklists.sh"
WITH_LOCK="$SCRIPT_DIR/with-lock.sh"
RESOLVE_ROOT="$SCRIPT_DIR/resolve-root.sh"
for helper in "$VALIDATOR" "$WITH_LOCK" "$RESOLVE_ROOT"; do
  [ -f "$helper" ] || die 3 "$helper not found"
done
DECLARATION="$PACKAGE_ROOT/templates/checklist-required-ids.json"
SHIPPED="$PACKAGE_ROOT/templates/checklists.json"

# merge_py <mode> <instance> [<candidate>]
#   plan   print one id per line that the instance lacks (declaration order); write nothing
#   build  the same, and write the candidate file (mode copied from the instance) when at least one id is missing
# Exit: 0 ok, 3 package source unusable, 4 instance unusable, 5 self-check failed.
merge_py() {
  python3 - "$1" "$DECLARATION" "$SHIPPED" "$2" "${3:-}" </dev/null <<'PY'
import json
import os
import shutil
import sys

ME = "checklist-required-merge.sh"
mode, declaration_path, shipped_path, instance_path, candidate_path = sys.argv[1:6]
DEC = json.JSONDecoder()
WS = " \t\n\r"


def fail(code, message):
    sys.stderr.write("%s: %s\n" % (ME, message))
    sys.exit(code)


def skip(text, i):
    while i < len(text) and text[i] in WS:
        i += 1
    return i


def members(text):
    """Top-level object members as (key, value_start, value_end) spans, in file order."""
    i = skip(text, 0)
    if text[i:i + 1] != "{":
        raise ValueError("the top level is not an object")
    i = skip(text, i + 1)
    out = []
    if text[i:i + 1] == "}":
        return out
    while True:
        if text[i:i + 1] != '"':
            raise ValueError("expected a key at offset %d" % i)
        key, i = DEC.raw_decode(text, i)
        i = skip(text, i)
        if text[i:i + 1] != ":":
            raise ValueError("expected ':' at offset %d" % i)
        i = skip(text, i + 1)
        _, end = DEC.raw_decode(text, i)
        out.append((key, i, end))
        i = skip(text, end)
        if text[i:i + 1] == ",":
            i = skip(text, i + 1)
            continue
        if text[i:i + 1] == "}":
            return out
        raise ValueError("expected ',' or '}' at offset %d" % i)


def elements(text, start):
    """Element spans (start, end) of the array whose '[' is at text[start]."""
    i = skip(text, start + 1)
    out = []
    if text[i:i + 1] == "]":
        return out
    while True:
        _, end = DEC.raw_decode(text, i)
        out.append((i, end))
        i = skip(text, end)
        if text[i:i + 1] == ",":
            i = skip(text, i + 1)
            continue
        if text[i:i + 1] == "]":
            return out
        raise ValueError("expected ',' or ']' at offset %d" % i)


def line_indent(text, pos):
    """The whitespace before pos on its line, or None when something else precedes pos on that line."""
    nl = text.rfind("\n", 0, pos)
    if nl < 0:
        return None
    lead = text[nl + 1:pos]
    return lead if lead.strip(" \t") == "" else None


def read(path, what, code):
    try:
        with open(path, encoding="utf-8") as handle:
            text = handle.read()
        return text, json.loads(text)
    except (OSError, ValueError) as exc:
        fail(code, "cannot read %s %s: %s" % (what, path, exc))


def items_span(text, what, code):
    try:
        spans = members(text)
    except ValueError as exc:
        fail(code, "%s is not in the expected shape: %s" % (what, exc))
    keys = [k for k, _, _ in spans]
    if len(keys) != len(set(keys)):
        fail(code, "%s has a duplicate top-level key" % what)
    found = [(s, e) for k, s, e in spans if k == "items"]
    if not found or text[found[0][0]] != "[":
        fail(code, '%s has no top-level "items" array' % what)
    return found[0]


# -- package source ------------------------------------------------------------------------------------------------
_, declaration = read(declaration_path, "the required-id declaration", 3)
required = declaration.get("required") if isinstance(declaration, dict) else None
if not isinstance(required, list) or not all(
        isinstance(e, dict) and isinstance(e.get("id"), str) and e["id"] for e in required):
    fail(3, '%s: "required" must be an array of entries with a non-empty "id"' % declaration_path)
required_ids = []
for entry in required:
    if entry["id"] not in required_ids:
        required_ids.append(entry["id"])

shipped_text, shipped = read(shipped_path, "the shipped default", 3)
s_start, _ = items_span(shipped_text, "the shipped default %s" % shipped_path, 3)
s_items = shipped["items"]
s_spans = elements(shipped_text, s_start)
shipped_by_id = {}
for value, span in zip(s_items, s_spans):
    if isinstance(value, dict) and isinstance(value.get("id"), str) and value["id"] not in shipped_by_id:
        shipped_by_id[value["id"]] = (value, span)
lacking = [i for i in required_ids if i not in shipped_by_id]
if lacking:
    fail(3, "the shipped default %s lacks required id(s) %s (a packaging regression); nothing was changed"
         % (shipped_path, ", ".join(lacking)))

# -- instance --------------------------------------------------------------------------------------------------------
inst_text, inst = read(instance_path, "the project instance", 4)
v_start, v_end = items_span(inst_text, "the project instance %s" % instance_path, 4)
inst_items = inst["items"]
present = {it.get("id") for it in inst_items if isinstance(it, dict)}
missing = [i for i in required_ids if i not in present]

if mode == "plan" or not missing:
    for i in missing:
        sys.stdout.write(i + "\n")
    sys.exit(0)

# -- build the candidate ---------------------------------------------------------------------------------------------
i_spans = elements(inst_text, v_start)


def render(item_id, elem_indent):
    value, (a, b) = shipped_by_id[item_id]
    raw = shipped_text[a:b]
    src_indent = line_indent(shipped_text, a)
    if elem_indent is None:
        return json.dumps(value, ensure_ascii=False)
    if src_indent is None:
        raw = json.dumps(value, indent=2, ensure_ascii=False)
        src_indent = ""
    lines = raw.split("\n")
    out = [lines[0]]
    for line in lines[1:]:
        out.append(elem_indent + line[len(src_indent):] if line.startswith(src_indent) else line)
    rendered = "\n".join(out)
    if json.loads(rendered) != value:  # whitespace between tokens only; checked, never assumed
        fail(5, "re-indenting the shipped item %s changed its value" % item_id)
    return rendered


if i_spans:
    first_start, last_end = i_spans[0][0], i_spans[-1][1]
    elem_indent = line_indent(inst_text, first_start)
    sep = "," + ("\n" + elem_indent if elem_indent is not None else " ")
    insert = "".join(sep + render(i, elem_indent) for i in missing)
    head, tail = inst_text[:last_end], inst_text[last_end:]
    candidate_text = head + insert + tail
else:
    # An empty array holds only whitespace between its brackets: replace that interior, keep every other byte.
    nl = inst_text.rfind("\n", 0, v_start)
    line = inst_text[nl + 1:v_start]
    base = line[:len(line) - len(line.lstrip(" \t"))]
    elem_indent = base + "  "
    body = ",\n".join(elem_indent + render(i, elem_indent) for i in missing)
    head, tail = inst_text[:v_start], inst_text[v_end:]
    candidate_text = head + "[\n" + body + "\n" + base + "]" + tail

# Self-check: the candidate parses; other keys equal and in order; items are the old ones followed by the new ones.
try:
    cand = json.loads(candidate_text)
except ValueError as exc:
    fail(5, "the candidate does not parse: %s" % exc)
added_values = [shipped_by_id[i][0] for i in missing]
if (not isinstance(cand, dict) or list(cand.keys()) != list(inst.keys())
        or any(cand[k] != inst[k] for k in inst if k != "items")
        or cand["items"] != inst_items + added_values
        or not candidate_text.startswith(head) or not candidate_text.endswith(tail)):
    fail(5, "the candidate failed the structural self-check; nothing was changed")

with open(candidate_path, "w", encoding="utf-8") as handle:
    handle.write(candidate_text)
shutil.copymode(instance_path, candidate_path)
for i in missing:
    sys.stdout.write(i + "\n")
sys.exit(0)
PY
}

# validate <file>: scripts/validate-checklists.sh, its problem lines passed through on stderr.
validate() { bash "$VALIDATOR" "$1" </dev/null >/dev/null; }

# -- apply under the lock (re-invoked by the main path through with-lock.sh) ------------------------------------------
if [ "$APPLY" -eq 1 ]; then
  [ -n "$INSTANCE_ARG" ] || die 2 "--apply-locked needs --instance"
  INSTANCE="$INSTANCE_ARG"
  [ -f "$INSTANCE" ] && [ ! -L "$INSTANCE" ] || die 4 "$INSTANCE is not a regular file; nothing was changed"
  CANDIDATE="$(mktemp "$(dirname -- "$INSTANCE")/.checklists.json.merge.XXXXXX" 2>/dev/null)" \
    || die 6 "could not create a candidate file next to $INSTANCE; nothing was changed"
  trap 'rm -f "$CANDIDATE"' EXIT
  ids="$(merge_py build "$INSTANCE" "$CANDIDATE")" || exit $?
  [ -n "$ids" ] || exit 0
  validate "$CANDIDATE" || die 5 "the merged registry failed validate-checklists.sh; $INSTANCE was left unchanged"
  mv -f "$CANDIDATE" "$INSTANCE" || die 6 "could not move the candidate over $INSTANCE; it was left unchanged"
  printf '%s\n' "$ids" | sed 's/^/added /'
  exit 0
fi

# physical_path <path>: the physical absolute form of <path> (relative paths are taken from $CONSUMER). The longest
# existing leading part is resolved with `cd -P` / `pwd -P`, so every symlink and ".." in it is followed as the file
# system follows it. Portable to macOS (BSD) and GNU: no realpath, no readlink -f.
# Returns:
#   0  the whole path exists and is a directory; the printed path is where the operating system resolves it.
#   3  a component does not exist, so the operating system cannot resolve the path (it resolves component by
#      component: "missing/.." fails with "No such file or directory", it never cancels out). The printed path is
#      only a lexical estimate (the remaining tail normalised as text, "." dropped, ".." pops one component). The
#      caller may use it to refuse a path that leaves the root even as text, but never as an address: a text-
#      normalised tail can drop "missing/.." and re-enter a symlink the real path never reaches.
#   1  printing nothing: an existing component is not a directory, or the leading part cannot be entered.
physical_path() {
  local p="$1" tail="" tail_seen="" base out comp
  case "$p" in /*) ;; *) p="$CONSUMER/$p" ;; esac
  while [ "$p" != "/" ] && [ "${p%/}" != "$p" ]; do p="${p%/}"; done
  while [ ! -d "$p" ]; do
    # Something exists here (a file, or a symlink whose target is missing): it cannot be the configs directory.
    if [ -e "$p" ] || [ -L "$p" ]; then return 1; fi
    base="${p##*/}"; p="${p%/*}"; [ -n "$p" ] || p="/"
    tail="$base${tail:+/$tail}"
  done
  out="$(cd -P -- "$p" 2>/dev/null && pwd -P)" || return 1
  tail_seen="$tail"
  # Split the tail by parameter expansion, not word splitting, so a component is never glob-expanded.
  while [ -n "$tail" ]; do
    comp="${tail%%/*}"
    if [ "$comp" = "$tail" ]; then tail=""; else tail="${tail#*/}"; fi
    case "$comp" in
      ''|.) ;;
      ..) out="${out%/*}"; [ -n "$out" ] || out="/" ;;
      *) out="${out%/}/$comp" ;;
    esac
  done
  printf '%s\n' "$out"
  [ -z "$tail_seen" ] || return 3
}

# -- main ------------------------------------------------------------------------------------------------------------
CONFIGS_RAW="$(cd "$CONSUMER" && env -u JENGA_PROJECT_ROOT bash "$RESOLVE_ROOT" get configs </dev/null)" \
  || die 1 "could not resolve the configs directory of $CONSUMER"
# Containment is decided on physical paths ($CONSUMER is already `pwd -P`): a configs path that reaches outside
# through ".." or through a symlinked directory is refused like an absolute outside path. A symlinked configs
# directory whose target lies inside the consumer root is allowed; the instance is then addressed by its physical path.
# A configs path the operating system cannot resolve (a component is missing, physical_path exit 3) holds no
# instance. Its lexical estimate is still checked for containment, so a path that leaves the root even as text keeps
# exit 1, but it is never used as an address: after the check the script exits 0 with nothing written.
CONFIGS="$(physical_path "$CONFIGS_RAW")"; pp_status=$?
case "$pp_status" in
  0|3) ;;
  *) die 1 "could not resolve the configs directory $CONFIGS_RAW of $CONSUMER; nothing was changed" ;;
esac
case "$CONFIGS" in
  "$CONSUMER"/*) ;;
  *) die 1 "the configs directory $CONFIGS_RAW resolves to $CONFIGS, outside the consumer root $CONSUMER;" \
          "nothing was changed" ;;
esac
# The configs directory does not exist as the operating system resolves it: no instance, nothing to add.
[ "$pp_status" -eq 0 ] || exit 0
INSTANCE="$CONFIGS/checklists.json"

# No instance: the shipped default applies as a whole, so there is nothing to add and nothing is created.
if [ ! -e "$INSTANCE" ] && [ ! -L "$INSTANCE" ]; then exit 0; fi
[ -f "$INSTANCE" ] && [ ! -L "$INSTANCE" ] || die 4 "$INSTANCE is not a regular file; nothing was changed"

ids="$(merge_py plan "$INSTANCE")" || exit $?
[ -n "$ids" ] || exit 0

validate "$INSTANCE" || die 4 "$INSTANCE is not a valid checklist registry (validate-checklists.sh); it was left unchanged"

if [ "$DRY" -eq 1 ]; then
  scratch="$(mktemp -d "${TMPDIR:-/tmp}/checklist-required-merge.XXXXXX")" || die 6 "could not create a scratch directory"
  trap 'rm -rf "$scratch"' EXIT
  cp -p "$INSTANCE" "$scratch/checklists.json" || die 6 "could not copy $INSTANCE to a scratch directory"
  merge_py build "$scratch/checklists.json" "$scratch/candidate.json" >/dev/null || exit $?
  validate "$scratch/candidate.json" || die 5 "the merged registry would fail validate-checklists.sh; nothing was changed"
  printf '%s\n' "$ids" | sed 's/^/would add /'
  exit 0
fi

bash "$WITH_LOCK" "$INSTANCE" -- bash "$SCRIPT_PATH" --apply-locked --instance "$INSTANCE" \
  --consumer-root "$CONSUMER" --package-root "$PACKAGE_ROOT" </dev/null
status=$?
case "$status" in
  0|3|4|5|6) exit "$status" ;;
  *) die 6 "could not acquire the lock on $INSTANCE (with-lock.sh exit $status); nothing was changed" ;;
esac
