#!/usr/bin/env bash
# run-engine.sh — mode-agnostic entry point for the /uncharted investigative engine
#
# Usage: run-engine.sh [options] <target>
#        run-engine.sh --help
#
# This is the ONE script the calling agent invokes. It does not reimplement any analysis:
# it orchestrates the three deterministic detectors delivered by E40_S01_T02/T03, merges
# their JSON, renders the understanding document from
# skills/j-uncharted/assets/UNDERSTANDING_DOC_TEMPLATE.md, writes it into
# project/rapports/analysis/, and prints the written path — and nothing else — on stdout.
#
#   enumerate-target.sh     → Target + Structure sections
#   detect-dependencies.sh  → Key Dependencies section
#   detect-tests.sh         → Existing Tests section
#
# All three modes (`segment`, `import`, `onboard`) call this script. That is what makes the
# engine shared: mode changes the filename, the Target section, and the default tree depth —
# never the analysis itself.
#
# MECHANICAL vs JUDGEMENT. This script fills Target, Structure, Key Dependencies and Existing
# Tests from real detector output. It leaves Purpose, Risk Areas and Open Questions as the
# template's `_TODO(agent):_` placeholders. It must never fabricate them; the scrum-master fills
# them in from the mechanical evidence.
#
# Side effects: exactly one file written (the document), plus the merged JSON when --json-out is
# given, plus mkdir -p on the output directory. The three detectors it calls are strictly
# read-only. No application code is ever modified.
#
# ---------------------------------------------------------------------------
# OPTIONS
# ---------------------------------------------------------------------------
#   --mode segment|import|onboard
#         Mode hint. Default: segment. Reflected in the output filename and in the document's
#         Target section. `onboard` additionally defaults --max-depth to 2 (coarse by design).
#   --max-depth N        Tree depth bound, forwarded to enumerate-target.sh.
#                        Default 2 for onboard, 3 otherwise. 0 = unlimited.
#   --top N              Number of largest files to report. Default 10. 0 = all.
#   --no-gitignore       Forwarded to enumerate-target.sh: enumerate .gitignore'd content too.
#   --origin <text>      Value for the Target section's Origin row. Default is derived:
#                        "in-repo", or "outside this repository (<path>)". `import` mode should
#                        pass its acquired source, e.g. --origin "imported from <git url>".
#   --out-dir <dir>      Output directory. Default: <repo-root>/project/rapports/analysis
#   --json-out <file>    Also write the merged raw detector JSON here, for an agent that wants
#                        to reason over the evidence directly. Not written unless requested.
#   --template <file>    Override the understanding-document template. Defaults to
#                        ../assets/UNDERSTANDING_DOC_TEMPLATE.md relative to this script.
#   -h, --help           Show this help and exit 0.
#
# ---------------------------------------------------------------------------
# OUTPUT
# ---------------------------------------------------------------------------
# stdout : the absolute path of the written document. One line. Nothing else — so callers can
#          do  DOC=$(run-engine.sh ...)  safely.
# stderr : notices and skipped-path diagnostics forwarded from the detectors, plus any render
#          warnings. Never silently swallowed, never injected into the document (the seven
#          document headings are fixed, so there is nowhere to put them).
#
# Filename: uncharted-<mode>-<slug>-<YYYYMMDDTHHMMSSZ>.md
#           <slug> is derived from the target's basename. A collision suffix (-2, -3, …) is
#           appended rather than overwriting an existing document.
#
# ---------------------------------------------------------------------------
# TEMPLATE CONTRACT CONSUMED
# ---------------------------------------------------------------------------
#   SCALAR tokens  {{TOKEN}}          substituted once, in place.
#   ROW templates  a table row line ending in `<!-- ROW -->` is repeated once per record and
#                  dropped entirely when there are no records. A row whose tokens this renderer
#                  does not recognise is dropped with a stderr warning — an unsubstituted
#                  {{TOKEN}} must never reach the document.
#   The template's own leading `<!-- OUTPUT CONTRACT ... -->` block is instructions to this
#   renderer, not document content, and is removed from the output. Per-section
#   MECHANICAL/JUDGEMENT comments are kept: they instruct the agent who fills the judgement
#   sections.
#
# Exit codes:
#   0 — success; document written and its path printed
#   1 — usage error (unknown flag, bad mode, missing/duplicate target, bad numeric value)
#   2 — target error (does not exist / not readable)
#   3 — an upstream detector script is missing or failed (its stderr is surfaced)
#   4 — render or write failure (template missing, heading check failed, unwritable output or
#       --json-out directory). No document is left behind on this path: both destinations are
#       validated before any detector runs, and the document is the last thing written.
#
# Requires: bash, python3, and the three sibling detector scripts. jq is NOT required.

set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)

MODE="segment"
MAX_DEPTH=""
TOP=10
NO_GITIGNORE=0
ORIGIN=""
OUT_DIR=""
JSON_OUT=""
TEMPLATE="$SCRIPT_DIR/../assets/UNDERSTANDING_DOC_TEMPLATE.md"
TARGET=""

usage() {
  cat <<EOF
Usage: $(basename "$0") [options] <target>

Run the shared /uncharted investigative engine against <target> (a file, a directory, or a
repository root). Invokes enumerate-target.sh, detect-dependencies.sh and detect-tests.sh,
renders the understanding document, and prints the written path on stdout.

Options:
  --mode MODE       segment | import | onboard   (default: segment)
  --max-depth N     tree depth bound (default: 2 for onboard, 3 otherwise; 0 = unlimited)
  --top N           largest-files count (default: 10; 0 = all)
  --no-gitignore    enumerate .gitignore'd content too
  --origin TEXT     Origin value for the Target section (default: derived)
  --out-dir DIR     output directory (default: <repo-root>/project/rapports/analysis)
  --json-out FILE   also write the merged raw detector JSON here
  --template FILE   override the understanding-document template
  -h, --help        show this help and exit

Exit codes: 0 success, 1 usage error, 2 target error, 3 detector failure, 4 render/write failure.
EOF
}

die_usage() {
  echo "Error: $1" >&2
  echo >&2
  usage >&2
  exit 1
}

require_int() {
  case "$2" in
    ''|*[!0-9]*) die_usage "$1 requires a non-negative integer, got \"$2\"" ;;
  esac
}

require_value() {
  # require_value <flag> <remaining-arg-count>
  [ "$2" -ge 2 ] || die_usage "$1 requires a value"
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --mode)        require_value "--mode" "$#";        MODE="$2"; shift 2 ;;
    --mode=*)      MODE="${1#*=}"; shift ;;
    --max-depth)   require_value "--max-depth" "$#";   require_int "--max-depth" "$2"; MAX_DEPTH="$2"; shift 2 ;;
    --max-depth=*) require_int "--max-depth" "${1#*=}"; MAX_DEPTH="${1#*=}"; shift ;;
    --top)         require_value "--top" "$#";         require_int "--top" "$2"; TOP="$2"; shift 2 ;;
    --top=*)       require_int "--top" "${1#*=}";      TOP="${1#*=}"; shift ;;
    --no-gitignore) NO_GITIGNORE=1; shift ;;
    --origin)      require_value "--origin" "$#";      ORIGIN="$2"; shift 2 ;;
    --origin=*)    ORIGIN="${1#*=}"; shift ;;
    --out-dir)     require_value "--out-dir" "$#";     OUT_DIR="$2"; shift 2 ;;
    --out-dir=*)   OUT_DIR="${1#*=}"; shift ;;
    --json-out)    require_value "--json-out" "$#";    JSON_OUT="$2"; shift 2 ;;
    --json-out=*)  JSON_OUT="${1#*=}"; shift ;;
    --template)    require_value "--template" "$#";    TEMPLATE="$2"; shift 2 ;;
    --template=*)  TEMPLATE="${1#*=}"; shift ;;
    -h|--help)     usage; exit 0 ;;
    --)
      shift
      [ "$#" -eq 1 ] || die_usage "exactly one target is required"
      TARGET="$1"; shift ;;
    -*)
      die_usage "unknown option \"$1\"" ;;
    *)
      [ -z "$TARGET" ] || die_usage "exactly one target is required (got \"$TARGET\" and \"$1\")"
      TARGET="$1"; shift ;;
  esac
done

case "$MODE" in
  segment|import|onboard) ;;
  *) die_usage "--mode must be one of segment, import, onboard (got \"$MODE\")" ;;
esac

[ -n "$TARGET" ] || die_usage "a target is required"

if [ ! -e "$TARGET" ]; then
  echo "Error: target does not exist: $TARGET" >&2
  exit 2
fi
if [ ! -r "$TARGET" ]; then
  echo "Error: target is not readable: $TARGET" >&2
  exit 2
fi

# `onboard` is coarse-first by design (E40 epic): it wants subsystems, not a per-file listing.
if [ -z "$MAX_DEPTH" ]; then
  if [ "$MODE" = "onboard" ]; then MAX_DEPTH=2; else MAX_DEPTH=3; fi
fi

if [ ! -f "$TEMPLATE" ]; then
  echo "Error: understanding-document template not found: $TEMPLATE" >&2
  exit 4
fi
TEMPLATE=$(cd -- "$(dirname -- "$TEMPLATE")" && pwd -P)/$(basename -- "$TEMPLATE")

# --- repo root ----------------------------------------------------------------------------------
# Anchored on THIS SCRIPT, not on the target: the analysis rapport belongs to the project that owns
# the engine, even when the target lives outside it (import mode staging areas, out-of-repo paths).
REPO_ROOT=$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel 2>/dev/null || true)
[ -n "$REPO_ROOT" ] || REPO_ROOT="$(pwd -P)"

[ -n "$OUT_DIR" ] || OUT_DIR="$REPO_ROOT/project/rapports/analysis"
mkdir -p "$OUT_DIR" 2>/dev/null || {
  echo "Error: could not create output directory: $OUT_DIR" >&2
  exit 4
}
[ -w "$OUT_DIR" ] || { echo "Error: output directory is not writable: $OUT_DIR" >&2; exit 4; }
OUT_DIR=$(cd -- "$OUT_DIR" && pwd -P)

# Pre-flight the --json-out destination too. Checking it here, before any detector runs, is what
# keeps the exit-4 contract honest: a bad path fails fast with nothing written, rather than
# surfacing after the document has already been created.
if [ -n "$JSON_OUT" ]; then
  JSON_OUT_DIR=$(dirname -- "$JSON_OUT")
  if [ ! -d "$JSON_OUT_DIR" ]; then
    echo "Error: --json-out directory does not exist: $JSON_OUT_DIR" >&2
    exit 4
  fi
  if [ ! -w "$JSON_OUT_DIR" ]; then
    echo "Error: --json-out directory is not writable: $JSON_OUT_DIR" >&2
    exit 4
  fi
  JSON_OUT=$(cd -- "$JSON_OUT_DIR" && pwd -P)/$(basename -- "$JSON_OUT")
fi

# --- run the three detectors --------------------------------------------------------------------
TMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/uncharted-engine.XXXXXX")
cleanup() { rm -rf "$TMP_DIR"; }
trap cleanup EXIT

run_detector() {
  # run_detector <script-name> <output-file> [args...]
  local name="$1" out="$2"; shift 2
  local path="$SCRIPT_DIR/$name" rc=0
  if [ ! -f "$path" ]; then
    echo "Error: required detector script is missing: $path" >&2
    exit 3
  fi
  bash "$path" "$@" >"$out" 2>"$TMP_DIR/$name.err" || rc=$?
  if [ "$rc" -ne 0 ]; then
    echo "Error: $name exited $rc for target: $TARGET" >&2
    sed 's/^/  ['"$name"'] /' "$TMP_DIR/$name.err" >&2 || true
    exit 3
  fi
  if [ -s "$TMP_DIR/$name.err" ]; then
    sed 's/^/  ['"$name"'] /' "$TMP_DIR/$name.err" >&2 || true
  fi
}

GITIGNORE_ARGS=()
[ "$NO_GITIGNORE" -eq 1 ] && GITIGNORE_ARGS+=(--no-gitignore)

run_detector enumerate-target.sh "$TMP_DIR/enumerate.json" \
  --max-depth "$MAX_DEPTH" --top "$TOP" "${GITIGNORE_ARGS[@]+"${GITIGNORE_ARGS[@]}"}" -- "$TARGET"
run_detector detect-dependencies.sh "$TMP_DIR/dependencies.json" "$TARGET"
run_detector detect-tests.sh "$TMP_DIR/tests.json" "$TARGET"

# --- output path --------------------------------------------------------------------------------
# Resolve before slugging: a target of "." or "path/to/dir/" would otherwise slug to nothing.
if [ -d "$TARGET" ]; then
  RESOLVED_TARGET=$(cd -- "$TARGET" && pwd -P)
else
  RESOLVED_TARGET=$(cd -- "$(dirname -- "$TARGET")" && pwd -P)/$(basename -- "$TARGET")
fi
BASE=$(basename -- "$RESOLVED_TARGET")
SLUG=$(printf '%s' "$BASE" \
  | tr '[:upper:]' '[:lower:]' \
  | sed -e 's/[^a-z0-9]\{1,\}/-/g' -e 's/^-*//' -e 's/-*$//' \
  | cut -c1-40)
[ -n "$SLUG" ] || SLUG="target"

STAMP=$(date -u +%Y%m%dT%H%M%SZ)
ISO_TS=$(date -u +%Y-%m-%dT%H:%M:%SZ)

OUT_FILE="$OUT_DIR/uncharted-$MODE-$SLUG-$STAMP.md"
n=2
while [ -e "$OUT_FILE" ]; do
  OUT_FILE="$OUT_DIR/uncharted-$MODE-$SLUG-$STAMP-$n.md"
  n=$((n + 1))
done

# --- render -------------------------------------------------------------------------------------
PY_SRC=$(cat <<'PY'
import json
import os
import re
import sys

(tpl_path, enum_path, deps_path, tests_path, mode, origin_arg,
 timestamp, out_path, repo_root, json_out) = sys.argv[1:11]

warnings = []
notices = []

EXT_ROW_CAP = 20
LIST_CAP = 25
TREE_LINE_CAP = 200


def load(path, label):
    try:
        with open(path, encoding="utf-8") as fh:
            return json.load(fh)
    except (OSError, ValueError) as exc:
        sys.stderr.write("Error: could not parse %s output: %s\n" % (label, exc))
        sys.exit(4)


enum = load(enum_path, "enumerate-target.sh")
deps = load(deps_path, "detect-dependencies.sh")
tests = load(tests_path, "detect-tests.sh")

root = repo_root.rstrip("/")


def rel(path):
    """Repo-relative when the path is inside the engine's repo, absolute otherwise."""
    if not path:
        return path
    if path == root:
        return "."
    if path.startswith(root + "/"):
        return path[len(root) + 1:]
    return path


def code(s):
    return "`%s`" % s


def num(n):
    return "{:,}".format(n)


def bullets(items, empty):
    if not items:
        return empty
    shown = items[:LIST_CAP]
    out = ["- " + i for i in shown]
    if len(items) > len(shown):
        out.append("- _… %d more; re-run with `--json-out` for the full list._"
                   % (len(items) - len(shown)))
    return "\n".join(out)


# --- Target ---------------------------------------------------------------------------------
target_abs = enum.get("target", "")
target_type = enum.get("target_type", "unknown")
target_rel = rel(target_abs)
target_name = target_rel if target_rel not in ("", ".") else os.path.basename(target_abs) or target_abs

if origin_arg:
    origin = origin_arg
elif target_abs == root or target_abs.startswith(root + "/"):
    origin = "in-repo"
else:
    origin = "outside this repository (`%s`)" % target_abs


def board_linkage():
    """Mechanical: does any board item's text mention this target's repo-relative path?"""
    if target_type == "repo_root" or target_rel in ("", "."):
        # A substring scan for "." would match every board file; say nothing rather than lie.
        return "n/a — target is the repository root"
    if not (target_abs == root or target_abs.startswith(root + "/")):
        return "unlinked — target is outside this repository"
    board = os.path.join(root, "project", "board")
    if not os.path.isdir(board):
        return "unlinked (no `project/board/` in this repository)"
    ids = set()
    for dirpath, _dirnames, filenames in os.walk(board):
        for fn in filenames:
            if not fn.endswith(".md"):
                continue
            try:
                with open(os.path.join(dirpath, fn), encoding="utf-8", errors="replace") as fh:
                    text = fh.read()
            except OSError:
                continue
            if target_rel in text:
                m = re.match(r"^(E\d+(?:_S\d+)?(?:_T\d+)?)", fn)
                ids.add(m.group(1) if m else fn[:-3])
    if not ids:
        return "unlinked"
    ordered = sorted(ids)
    shown = ordered[:8]
    out = "linked to " + ", ".join(code(i) for i in shown)
    if len(ordered) > len(shown):
        out += " (+%d more)" % (len(ordered) - len(shown))
    return out


# --- Structure ------------------------------------------------------------------------------
ext_rows = [{"EXT": code(e.get("extension", "(none)")), "EXT_COUNT": num(e.get("files", 0))}
            for e in enum.get("extensions", [])]
if len(ext_rows) > EXT_ROW_CAP:
    hidden = len(ext_rows) - EXT_ROW_CAP
    ext_rows = ext_rows[:EXT_ROW_CAP]
    ext_rows.append({"EXT": "_… %d more extensions_" % hidden, "EXT_COUNT": "—"})

largest_rows = []
for f in enum.get("largest_files", []):
    lines = "— (binary, %s bytes)" % num(f.get("bytes", 0)) if f.get("binary") else num(f.get("lines", 0))
    largest_rows.append({"LARGEST_FILE": f.get("path", ""), "LARGEST_FILE_LINES": lines})


def render_tree():
    entries = enum.get("tree", [])
    if not entries:
        return "(no files enumerated)"
    # A file target's "tree" is the one file itself; a root label would just repeat its name.
    is_file = target_type == "file"
    lines = [] if is_file else [target_name + "/"]
    for e in entries[:TREE_LINE_CAP]:
        depth = e.get("depth", 1)
        indent = "" if is_file else "  " * depth
        name = e["path"].rsplit("/", 1)[-1]
        if e.get("type") == "directory":
            count = e.get("file_count", 0)
            line = "%s%s/  (%s file%s)" % (indent, name, num(count), "" if count == 1 else "s")
            if e.get("truncated"):
                line += "  [truncated]"
        elif e.get("binary"):
            line = "%s%s  (binary, %s bytes)" % (indent, name, num(e.get("bytes", 0)))
        else:
            n_lines = e.get("lines", 0)
            line = "%s%s  (%s line%s)" % (indent, name, num(n_lines), "" if n_lines == 1 else "s")
        lines.append(line)
    if len(entries) > TREE_LINE_CAP:
        lines.append("… %d further entries not shown (renderer line cap)"
                     % (len(entries) - TREE_LINE_CAP))
    if enum.get("tree_truncated"):
        lines.append("… tree bounded at max depth %s; deeper entries exist"
                     % enum.get("max_depth"))
    return "\n".join(lines)


# --- Key Dependencies -----------------------------------------------------------------------
def dep_sources(entry):
    src = entry.get("sources") or []
    return " (e.g. %s)" % ", ".join(code(s) for s in src[:3]) if src else ""


internal_items = []
for d in deps.get("internal", []):
    resolved = d.get("resolved")
    target_part = code(resolved) if resolved else "_unresolved_"
    internal_items.append("%s → %s — %d occurrence(s), %s%s" % (
        code(d.get("raw", "")), target_part, d.get("occurrences", 0),
        d.get("language", "unknown"), dep_sources(d)))

external_items = []
for d in deps.get("external", []):
    external_items.append("%s — %s, %d occurrence(s), %s%s" % (
        code(d.get("name", "")), d.get("kind", "unknown"), d.get("occurrences", 0),
        d.get("language", "unknown"), dep_sources(d)))

if deps.get("unrecognised"):
    empty_dep = "_No recognised source language in this target — nothing to extract._"
else:
    empty_dep = "_None detected._"

manifest_items = []
for m in deps.get("manifests", []):
    declared = m.get("declared_dependencies")
    if declared is None:
        decl = "declared dependencies not parsed"
    else:
        decl = "declares %d dependenc%s" % (len(declared), "y" if len(declared) == 1 else "ies")
    where = "in the target" if m.get("distance", 0) == 0 else "%d level(s) above the target" % m.get("distance", 0)
    manifest_items.append("%s — %s; %s" % (code(m.get("path", m.get("name", ""))), where, decl))

# --- Existing Tests -------------------------------------------------------------------------
coverage_status = tests.get("coverage_status", "unknown")
coverage_summary = tests.get("coverage_summary", "")
coverage_cell = code(coverage_status) + (" — %s" % coverage_summary if coverage_summary else "")

test_items = ["%s (inside the target)" % code(p) for p in tests.get("target_test_files", [])]
for r in tests.get("referencing_test_files", []):
    matched = r.get("matched") or []
    suffix = " — matches: %s" % ", ".join(code(m) for m in matched[:5]) if matched else ""
    test_items.append("%s%s" % (code(r.get("path", "")), suffix))

if test_items:
    test_block = bullets(test_items, "")
    ref_names = tests.get("reference_names") or []
    if ref_names:
        test_block += "\n\n_Matched against reference name(s): %s._" % ", ".join(
            code(n) for n in ref_names[:8])
else:
    if coverage_status == "repo_tests_only":
        test_block = ("_None. The repository contains %s test file(s), but none of them "
                      "reference this target._" % num(tests.get("repo_test_file_count", 0)))
    elif coverage_status == "no_tests_in_repo":
        test_block = "_None. No test files were found anywhere in the repository._"
    else:
        test_block = "_None._"

runner_items = []
for c in tests.get("test_runner_configs", []):
    detail = c.get("detail")
    runner_items.append("%s — runner: %s%s" % (
        code(c.get("path", c.get("name", ""))), c.get("runner", "unknown"),
        " (%s)" % detail if detail else ""))

# --- token maps ------------------------------------------------------------------------------
SCALARS = {
    "TARGET_NAME": target_name,
    "MODE": mode,
    "TIMESTAMP": timestamp,
    "TARGET_PATH": target_rel,
    "TARGET_TYPE": target_type,
    "BOARD_LINKAGE": board_linkage(),
    "ORIGIN": origin,
    "FILE_COUNT": num(enum.get("total_files", 0)),
    "MAX_DEPTH": "unlimited" if enum.get("max_depth", 0) == 0 else str(enum.get("max_depth")),
    "DIRECTORY_TREE": render_tree(),
    "INTERNAL_DEPENDENCIES": bullets(internal_items, empty_dep),
    "EXTERNAL_DEPENDENCIES": bullets(external_items, empty_dep),
    "MANIFEST_FILES": bullets(manifest_items, "_None found in or above the target._"),
    "TEST_COVERAGE_STATUS": coverage_cell,
    "TEST_FILES": test_block,
    "TEST_RUNNER_CONFIG": bullets(runner_items, "_None detected._"),
}

ROW_SPECS = [({"EXT", "EXT_COUNT"}, ext_rows),
             ({"LARGEST_FILE", "LARGEST_FILE_LINES"}, largest_rows)]

TOKEN_RE = re.compile(r"\{\{([A-Z0-9_]+)\}\}")
ROW_SENTINEL = "<!-- ROW -->"

# --- render ----------------------------------------------------------------------------------
try:
    with open(tpl_path, encoding="utf-8") as fh:
        template = fh.read()
except OSError as exc:
    sys.stderr.write("Error: could not read template: %s\n" % exc)
    sys.exit(4)

# Drop the template's own contract block: it is instruction to this renderer, not document
# content, and it contains a literal {{DOUBLE_BRACE}} that would look like a missed substitution.
# The block is matched by its LINE-ANCHORED delimiters (`<!--` and `-->` each alone on a line).
# A plain non-greedy `<!--.*?-->` would stop at the indented `<!-- ROW -->` quoted *inside* the
# block and leave its tail behind as document text.
BLOCK_COMMENT_RE = re.compile(r"^<!--[ \t]*\n.*?^-->[ \t]*\n?", re.S | re.M)
for m in BLOCK_COMMENT_RE.finditer(template):
    if "OUTPUT CONTRACT" in m.group(0):
        template = template[:m.start()] + template[m.end():]
        break
else:
    warnings.append("template has no line-anchored OUTPUT CONTRACT block to strip")

out_lines = []
for line in template.split("\n"):
    if ROW_SENTINEL not in line:
        out_lines.append(line)
        continue
    row_tpl = line.replace(ROW_SENTINEL, "").rstrip()
    tokens = set(TOKEN_RE.findall(row_tpl))
    records = None
    for spec_tokens, spec_records in ROW_SPECS:
        if tokens & spec_tokens:
            records = spec_records
            break
    if records is None:
        # An unknown repeating row — added to the template after this renderer was written.
        # Dropping it is the only safe move: emitting it would leak raw {{TOKEN}}s.
        warnings.append("dropped unrecognised ROW template: %s" % row_tpl.strip())
        continue
    for rec in records:
        rendered = row_tpl
        for tok, val in rec.items():
            rendered = rendered.replace("{{%s}}" % tok, val)
        out_lines.append(rendered)

document = "\n".join(out_lines)


def substitute(match):
    tok = match.group(1)
    if tok in SCALARS:
        return SCALARS[tok]
    warnings.append("no value for token {{%s}}" % tok)
    return "_(not provided by the engine)_"


document = TOKEN_RE.sub(substitute, document)

# --- self-check: the seven headings are the document's contract with downstream consumers ----
REQUIRED = ["## Target", "## Purpose", "## Structure", "## Key Dependencies",
            "## Existing Tests", "## Risk Areas", "## Open Questions"]
present = [ln.rstrip() for ln in document.split("\n")]
missing = [h for h in REQUIRED if h not in present]
if missing:
    sys.stderr.write("Error: rendered document is missing required heading(s): %s\n"
                     % ", ".join(missing))
    sys.exit(4)

if json_out:
    merged = {
        "engine": {
            "script": "run-engine.sh",
            "version": 1,
            "mode": mode,
            "timestamp": timestamp,
            "target": target_abs,
            "target_relative": target_rel,
            "origin": origin,
            "document": out_path,
            "warnings": warnings,
        },
        "enumerate": enum,
        "dependencies": deps,
        "tests": tests,
    }
    try:
        with open(json_out, "w", encoding="utf-8") as fh:
            json.dump(merged, fh, indent=2, ensure_ascii=False)
            fh.write("\n")
    except OSError as exc:
        sys.stderr.write("Error: could not write --json-out file: %s\n" % exc)
        sys.exit(4)

# The document is written LAST, deliberately. It is the script's advertised output, so it must be
# the final side effect: any earlier failure then exits non-zero with nothing left behind, which is
# what the exit-4 contract promises.
try:
    with open(out_path, "w", encoding="utf-8") as fh:
        fh.write(document.rstrip("\n") + "\n")
except OSError as exc:
    sys.stderr.write("Error: could not write document: %s\n" % exc)
    sys.exit(4)

# --- diagnostics to stderr, never into the document ------------------------------------------
for reason, info in sorted((enum.get("skipped") or {}).items()):
    notices.append("enumerate-target.sh skipped %d path(s): %s" % (info.get("count", 0), reason))
for n in deps.get("notices", []) or []:
    notices.append("detect-dependencies.sh: %s" % n)
for n in tests.get("notices", []) or []:
    notices.append("detect-tests.sh: %s" % n)
for w in warnings:
    sys.stderr.write("Warning: %s\n" % w)
for n in notices:
    sys.stderr.write("Notice: %s\n" % n)

print(out_path)
PY
)

python3 -c "$PY_SRC" \
  "$TEMPLATE" "$TMP_DIR/enumerate.json" "$TMP_DIR/dependencies.json" "$TMP_DIR/tests.json" \
  "$MODE" "$ORIGIN" "$ISO_TS" "$OUT_FILE" "$REPO_ROOT" "$JSON_OUT"
