#!/usr/bin/env bash
# write-backfilled-epics.sh — turn apply-subsystem-cap.sh's kept subsystem list into board epics
#
# Usage: write-backfilled-epics.sh [options] [<cap-report.json>]
#        apply-subsystem-cap.sh ... | write-backfilled-epics.sh [options]
#        write-backfilled-epics.sh --help
#
# The last mile of `/uncharted onboard`: apply-subsystem-cap.sh (E40_S04_T03) decides WHICH
# discovered subsystems become epics. This script is the ONLY thing that actually writes those
# epics to the board. It performs no discovery, no scoring, and no cap decision of its own —
# it consumes apply-subsystem-cap.sh's JSON output (its "kept" array) and renders one epic file
# per entry, following the Epic format in templates/SCRUM_BOARD_SCHEMA.md exactly.
#
# ---------------------------------------------------------------------------
# THE HARD CONSTRAINT
# ---------------------------------------------------------------------------
# `onboard` mode must NEVER modify, move, rename, delete, or restructure the consumer's
# application code. Its entire output surface is project/board/, project/rapports/analysis/,
# and project/PROJECT_SUMMARY.md. This script is the one that actually touches disk in the
# epic-generation step, so it is where that guarantee is made STRUCTURAL rather than only
# documented in skills/j-uncharted/SKILL.md:
#
#   - The epics directory (--epics-dir, default <repo-root>/project/board/epics) and the
#     --json-out path, if given, are both canonicalised and checked BEFORE any file is written.
#     Either one resolving outside <repo-root>/project/ is a hard failure — exit 3, nothing
#     written — not a warning.
#   - The script never reads, deletes, or touches anything under the analysed codebase itself.
#     Its only inputs are apply-subsystem-cap.sh's JSON (an already-computed decision) and the
#     existing project/board/epics/ directory (to avoid ID collisions).
#
# There is deliberately no flag to point --epics-dir or --json-out outside project/ and have the
# guard look the other way. If a caller needs epics written somewhere else, that is a different
# script's problem, not an override of this one's.
#
# ---------------------------------------------------------------------------
# INPUT
# ---------------------------------------------------------------------------
# apply-subsystem-cap.sh's JSON report, from a file argument or stdin (`-`, or no argument). The
# field consumed is `kept` — an array of {rank, path, absolute_path, score, files, lines}. This
# is deliberately the SAME field set apply-subsystem-cap.sh's own header documents; nothing here
# assumes a richer shape (discover-subsystems.sh's fuller per-candidate fields — manifests,
# test_paths, doc_paths, signals — are NOT present in `kept` and are not depended on). Each
# generated epic's Purpose section says so explicitly, so nobody reading a backfilled epic
# mistakes a coarse discovery signal for a deep investigation.
#
# `root` / `root_absolute`, when present, label which codebase was onboarded.
#
# ---------------------------------------------------------------------------
# OPTIONS
# ---------------------------------------------------------------------------
#   --epics-dir DIR   Where epic files are written. Default: <repo-root>/project/board/epics.
#                     Must resolve under <repo-root>/project/ or the run is refused.
#   --json-out FILE   Also write this script's JSON summary to FILE. stdout gets it regardless.
#                     Must resolve under <repo-root>/project/ or the run is refused.
#   --dry-run         Compute IDs and render epic content, but write nothing. Still validates and
#                     reports the write-path guard as it would apply to a real run.
#   --label TEXT      Human label for the analysed codebase, used in each epic's Purpose section.
#                     Default: the report's own `root` (or `root_absolute`'s basename).
#   -h, --help        Show this help and exit 0.
#
# ---------------------------------------------------------------------------
# EPIC ID CONTINUATION
# ---------------------------------------------------------------------------
# Epic IDs must continue the existing board's numbering, never collide with an epic already on
# it. The next free ID is one past the HIGHEST `E##` found in filenames under BOTH --epics-dir
# and the canonical <repo-root>/project/board/epics (the same directory in the common case;
# checking both means a --epics-dir override used for a dry-run/test pass can never later collide
# with the real board). IDs are assigned to `kept` entries in array order (rank order).
#
# ---------------------------------------------------------------------------
# OUTPUT (stdout, JSON)
# ---------------------------------------------------------------------------
# {
#   "script": "write-backfilled-epics.sh",
#   "version": 1,
#   "epics_dir": "<absolute path>",
#   "dry_run": <bool>,
#   "epic_count": <int>,
#   "epics": [ { "id", "path", "title", "source_path", "rank", "score", "files", "lines" }, ... ],
#   "notices": [ "<non-fatal diagnostic>", ... ]
# }
#
# ---------------------------------------------------------------------------
# EXIT CODES
# ---------------------------------------------------------------------------
#   0 — success (including a `kept` array of length zero: 0 epics is a valid outcome)
#   1 — usage error: unknown flag, missing value
#   2 — input error: report missing/unreadable, unparseable JSON, or no `kept` array
#   3 — write-path guard: --epics-dir or --json-out resolved outside <repo-root>/project/
#   4 — write failure: an epic file could not be written, or an existing epic file could not be
#       read while computing ID continuation
#
# Examples:
#   discover-subsystems.sh . | apply-subsystem-cap.sh --rapport "$DOC" | write-backfilled-epics.sh
#   apply-subsystem-cap.sh --json-out cap.json ... && write-backfilled-epics.sh cap.json
#   write-backfilled-epics.sh --dry-run --epics-dir project/rapports/analysis/scratch-epics cap.json
#
# Requires: bash, git, python3. jq is NOT required — JSON is parsed and emitted by python3.

set -euo pipefail

EPICS_DIR=""
JSON_OUT=""
DRY_RUN=0
LABEL=""
INPUT=""

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)

usage() {
  cat <<EOF
Usage: $(basename "$0") [options] [<cap-report.json>]

Render one backfilled epic file per apply-subsystem-cap.sh "kept" entry, under
<repo-root>/project/board/epics by default. Refuses to write anywhere outside
<repo-root>/project/ — that guard cannot be overridden by flag.

Arguments:
  <cap-report.json>   apply-subsystem-cap.sh JSON output. Omit, or pass "-", to read stdin.

Options:
  --epics-dir DIR      Output directory for epic files (default: <repo-root>/project/board/epics)
  --json-out FILE      Also write this script's JSON summary to FILE
  --dry-run            Compute and print, but write no epic files
  --label TEXT         Human label for the analysed codebase (default: the report's own root)
  -h, --help           Show this help and exit

Exit codes: 0 success, 1 usage error, 2 input error, 3 write-path guard, 4 write failure.
EOF
}

die_usage() {
  echo "Error: $1" >&2
  echo >&2
  usage >&2
  exit 1
}

require_value() {
  # require_value <flag> <remaining-arg-count>
  [ "$2" -ge 2 ] || die_usage "$1 requires a value"
}

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------

while [ "$#" -gt 0 ]; do
  case "$1" in
    --epics-dir)   require_value "--epics-dir" "$#"; EPICS_DIR="$2"; shift 2 ;;
    --epics-dir=*) EPICS_DIR="${1#*=}"; shift ;;
    --json-out)    require_value "--json-out" "$#";  JSON_OUT="$2"; shift 2 ;;
    --json-out=*)  JSON_OUT="${1#*=}"; shift ;;
    --label)       require_value "--label" "$#";     LABEL="$2"; shift 2 ;;
    --label=*)     LABEL="${1#*=}"; shift ;;
    --dry-run)     DRY_RUN=1; shift ;;
    -h|--help)     usage; exit 0 ;;
    --)
      shift
      [ "$#" -le 1 ] || die_usage "at most one input report is accepted"
      [ "$#" -eq 0 ] || INPUT="$1"
      break ;;
    -)
      INPUT="-"; shift ;;
    -*)
      die_usage "unknown option \"$1\"" ;;
    *)
      [ -z "$INPUT" ] || die_usage "at most one input report is accepted (got \"$INPUT\" and \"$1\")"
      INPUT="$1"; shift ;;
  esac
done

# ---------------------------------------------------------------------------
# Input resolution
# ---------------------------------------------------------------------------

if [ -z "$INPUT" ] || [ "$INPUT" = "-" ]; then
  INPUT="-"
else
  if [ ! -e "$INPUT" ]; then
    echo "Error: input report does not exist: $INPUT" >&2
    echo "       Expected apply-subsystem-cap.sh JSON output." >&2
    exit 2
  fi
  if [ ! -f "$INPUT" ] || [ ! -r "$INPUT" ]; then
    echo "Error: input report is not a readable file: $INPUT" >&2
    exit 2
  fi
  INPUT=$(cd -- "$(dirname -- "$INPUT")" && pwd -P)/$(basename -- "$INPUT")
fi

# ---------------------------------------------------------------------------
# Repo root and write-path guard — anchored on THIS SCRIPT, not on the analysed root, matching
# apply-subsystem-cap.sh's convention: the board belongs to the project that owns the engine.
# ---------------------------------------------------------------------------

REPO_ROOT=$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel 2>/dev/null || true)
[ -n "$REPO_ROOT" ] || REPO_ROOT="$(pwd -P)"

PROJECT_DIR="$REPO_ROOT/project"
mkdir -p "$PROJECT_DIR" 2>/dev/null || {
  echo "Error: could not create project directory: $PROJECT_DIR" >&2
  exit 4
}
PROJECT_DIR_REAL=$(cd -- "$PROJECT_DIR" && pwd -P)

CANONICAL_EPICS_DIR="$PROJECT_DIR_REAL/board/epics"

[ -n "$EPICS_DIR" ] || EPICS_DIR="$CANONICAL_EPICS_DIR"

# resolve_path_no_mkdir <path> — canonicalise <path> WITHOUT creating anything on disk. Existing
# ancestor components have their symlinks resolved (via Python's os.path.realpath, which is safe
# to call on a path that does not fully exist — it resolves what it can and appends the rest
# literally); a not-yet-existing tail is normalised lexically (".."/"." collapsed) so relative
# escapes like "project/../src" are still caught even before "project/" exists.
resolve_path_no_mkdir() {
  python3 -c 'import os, sys; print(os.path.realpath(sys.argv[1]))' "$1"
}

# guard_under_project_dir <path> <human-label> — refuse, loudly and BEFORE ANY FILESYSTEM WRITE,
# if <path> does not resolve under PROJECT_DIR_REAL. This is the one guard the task exists to
# make structural rather than aspirational, so the order matters as much as the check itself:
# resolution happens first and touches nothing; `mkdir -p` runs only after the path has already
# been accepted. An earlier version of this guard called `mkdir -p` before the check and so
# created an (empty) directory outside project/ on every rejected path, even under --dry-run —
# exactly the kind of write this guard exists to prevent. No flag combination may reintroduce
# that ordering.
guard_under_project_dir() {
  local raw="$1" label="$2" real
  real=$(resolve_path_no_mkdir "$raw")
  case "$real" in
    "$PROJECT_DIR_REAL"/*|"$PROJECT_DIR_REAL")
      ;;
    *)
      echo "Error: refusing to write $label outside project/." >&2
      echo "       Resolved path: $real" >&2
      echo "       Allowed root:  $PROJECT_DIR_REAL" >&2
      echo "       onboard mode's entire output surface is project/board/, project/rapports/analysis/," >&2
      echo "       and project/PROJECT_SUMMARY.md — it must never write anywhere else, including any" >&2
      echo "       location that could be mistaken for the consumer's application code." >&2
      echo "       Nothing was created on disk for this rejected path." >&2
      exit 3
      ;;
  esac
  mkdir -p "$real" 2>/dev/null || {
    echo "Error: could not create $label: $real" >&2
    exit 4
  }
  printf '%s\n' "$real"
}

EPICS_DIR_REAL=$(guard_under_project_dir "$EPICS_DIR" "the epics directory")

if [ -n "$JSON_OUT" ]; then
  JSON_OUT_DIR=$(dirname -- "$JSON_OUT")
  JSON_OUT_DIR_REAL=$(guard_under_project_dir "$JSON_OUT_DIR" "the --json-out directory")
  JSON_OUT="$JSON_OUT_DIR_REAL/$(basename -- "$JSON_OUT")"
fi

ISO_DATE=$(date -u +%Y-%m-%d)

# ---------------------------------------------------------------------------
# Render — the python source is captured into a variable and run with `python3 -c`, exactly as
# apply-subsystem-cap.sh does, because this script must be able to read stdin itself
# (`... | write-backfilled-epics.sh`), which a `python3 - <<PY` heredoc would occupy.
# ---------------------------------------------------------------------------

PY_SRC=$(cat <<'PY'
import json
import os
import re
import sys

(INPUT, EPICS_DIR, CANONICAL_EPICS_DIR, JSON_OUT, DRY_RUN_S, LABEL, TODAY) = sys.argv[1:8]
DRY_RUN = DRY_RUN_S == "1"

notices = []

# --- read apply-subsystem-cap.sh's report ---------------------------------------------------

try:
    if INPUT == "-":
        raw = sys.stdin.read()
        origin = "stdin"
    else:
        with open(INPUT, "r", encoding="utf-8") as fh:
            raw = fh.read()
        origin = INPUT
except OSError as exc:
    sys.stderr.write("Error: could not read input report: %s\n" % exc)
    sys.exit(2)

if not raw.strip():
    sys.stderr.write("Error: input report is empty (%s).\n" % origin)
    sys.stderr.write("       Expected apply-subsystem-cap.sh JSON output.\n")
    sys.exit(2)

try:
    report = json.loads(raw)
except ValueError as exc:
    sys.stderr.write("Error: input report is not valid JSON (%s): %s\n" % (origin, exc))
    sys.exit(2)

if not isinstance(report, dict) or not isinstance(report.get("kept"), list):
    sys.stderr.write("Error: input report has no \"kept\" array (%s).\n" % origin)
    sys.stderr.write("       This does not look like apply-subsystem-cap.sh output. Pipe\n")
    sys.stderr.write("       discover-subsystems.sh's output through apply-subsystem-cap.sh first.\n")
    sys.exit(2)

produced_by = report.get("script")
if produced_by and produced_by != "apply-subsystem-cap.sh":
    notices.append(
        "Input reports itself as \"%s\" rather than apply-subsystem-cap.sh; proceeding on the "
        "strength of its \"kept\" array." % produced_by)

kept = [c for c in report["kept"] if isinstance(c, dict)]
root = report.get("root") or report.get("root_absolute") or "(unknown root)"
root_absolute = report.get("root_absolute") or ""
if LABEL:
    label = LABEL
elif root not in (".", "", "./"):
    label = root
else:
    label = os.path.basename(root_absolute.rstrip("/")) or root

# --- epic ID continuation -------------------------------------------------------------------
# Scan BOTH the target epics dir and the canonical project/board/epics for the highest existing
# E## so a scratch --epics-dir used for a dry run can never later collide with the real board.

EPIC_FILENAME_RE = re.compile(r"^E(\d{2,})_.+\.md$")

def highest_epic_number(directory):
    highest = 0
    try:
        names = os.listdir(directory)
    except OSError:
        return 0
    for name in names:
        m = EPIC_FILENAME_RE.match(name)
        if m:
            highest = max(highest, int(m.group(1)))
    return highest

next_id = 1 + max(highest_epic_number(EPICS_DIR), highest_epic_number(CANONICAL_EPICS_DIR))


def slugify(text):
    s = re.sub(r"[^A-Za-z0-9]+", "-", str(text)).strip("-").lower()
    return (s or "subsystem")[:48]


def humanize_path(path):
    parts = [p for p in re.split(r"[\\/]+", path) if p and p not in (".", "..")]
    if not parts:
        return path or "(root)"
    words = []
    for part in parts:
        words.append(" ".join(w.capitalize() for w in re.split(r"[-_]+", part) if w) or part)
    return " / ".join(words)


def fmt_score(v):
    return ("%.2f" % v) if isinstance(v, (int, float)) else "unknown"


def fmt_count(v):
    return ("%d" % v) if isinstance(v, int) else "unknown"


epics = []

for entry in kept:
    path = entry.get("path") or "(unknown path)"
    rank = entry.get("rank")
    score = entry.get("score")
    files = entry.get("files")
    lines = entry.get("lines")

    epic_id = "E%02d" % next_id
    next_id += 1

    title = humanize_path(path)
    slug = slugify(path.replace("/", "-").replace("\\", "-"))
    filename = "%s_%s.md" % (epic_id, slug)
    dest_path = os.path.join(EPICS_DIR, filename)

    body = []
    body.append("---")
    body.append("id: %s" % epic_id)
    body.append("title: %s" % title)
    body.append("status: Pending")
    body.append("date_created: %s" % TODAY)
    body.append("date_started:")
    body.append("date_completed:")
    body.append("dates_previously_completed:")
    body.append("reopened_on:")
    body.append("reopened_reason:")
    body.append("docs: []")
    body.append("epic_scope_approval: false")
    body.append("provenance: backfilled")
    body.append("stories: []")
    body.append("---")
    body.append("")
    body.append("# Epic: %s" % title)
    body.append("")
    body.append("## Purpose")
    body.append(
        "`%s` (in `%s`) was identified by `/uncharted onboard`'s coarse subsystem discovery pass "
        "as an existing, cohesive subsystem of this codebase with no prior Jenga board "
        "provenance. This epic exists to bring it under board provenance — understanding what it "
        "already does and integrating it with the rest of the project's board — not to build new "
        "functionality. See the `provenance: backfilled` field above." % (path, label))
    body.append("")
    body.append(
        "**Discovery evidence (from `discover-subsystems.sh` via `apply-subsystem-cap.sh`):**")
    body.append("- Path: `%s`" % path)
    body.append("- Discovery rank: %s (score %s/100)" % (fmt_count(rank), fmt_score(score)))
    body.append("- Size: %s files, %s lines" % (fmt_count(files), fmt_count(lines)))
    body.append("")
    body.append(
        "This evidence is coarse by design — `onboard`'s cap step carries only path, rank, "
        "score, and file/line counts, not the fuller per-subsystem signals (manifests, test "
        "coverage, documentation) that `discover-subsystems.sh` computes internally. Run "
        "`/uncharted segment %s` for a full understanding document (purpose, structure, "
        "dependencies, existing tests, risk areas) before breaking this epic into stories." % path)
    body.append("")
    body.append("## Definition of Done")
    body.append(
        "- [ ] An `/uncharted segment` understanding document exists for `%s`, covering its "
        "purpose, structure, dependencies, and existing test coverage" % path)
    body.append(
        "- [ ] Any risk areas or undocumented behaviour surfaced by that document are captured "
        "as follow-up stories or tasks under this epic")
    body.append(
        "- [ ] This epic's stories and tasks describe understanding and integration work — "
        "documenting behaviour, closing test gaps, establishing board provenance — and not "
        "original construction; an incomplete-looking checklist here does not mean unbuilt "
        "functionality")
    body.append("- [ ] This subsystem's application code is unchanged by the act of backfilling this epic")
    body.append("")

    content = "\n".join(body)

    if not DRY_RUN:
        if os.path.exists(dest_path):
            sys.stderr.write("Error: refusing to overwrite existing epic file: %s\n" % dest_path)
            sys.exit(4)
        try:
            with open(dest_path, "w", encoding="utf-8") as fh:
                fh.write(content)
        except OSError as exc:
            sys.stderr.write("Error: could not write epic file %s: %s\n" % (dest_path, exc))
            sys.exit(4)

    epics.append({
        "id": epic_id,
        "path": dest_path,
        "title": title,
        "source_path": path,
        "rank": rank,
        "score": score,
        "files": files,
        "lines": lines,
    })

result = {
    "script": "write-backfilled-epics.sh",
    "version": 1,
    "epics_dir": EPICS_DIR,
    "dry_run": DRY_RUN,
    "epic_count": len(epics),
    "epics": epics,
    "notices": notices,
}

if JSON_OUT:
    try:
        with open(JSON_OUT, "w", encoding="utf-8") as fh:
            json.dump(result, fh, indent=2, ensure_ascii=False)
            fh.write("\n")
    except OSError as exc:
        sys.stderr.write("Error: could not write --json-out file: %s\n" % exc)
        sys.exit(4)

json.dump(result, sys.stdout, indent=2, ensure_ascii=False)
sys.stdout.write("\n")

if DRY_RUN:
    sys.stderr.write("Notice: --dry-run — %d epic file(s) computed but not written.\n" % len(epics))
else:
    sys.stderr.write("Notice: wrote %d backfilled epic file(s) to %s\n" % (len(epics), EPICS_DIR))
for n in notices:
    sys.stderr.write("Notice: %s\n" % n)
PY
)

python3 -c "$PY_SRC" \
  "$INPUT" "$EPICS_DIR_REAL" "$CANONICAL_EPICS_DIR" "$JSON_OUT" "$DRY_RUN" "$LABEL" "$ISO_DATE"
