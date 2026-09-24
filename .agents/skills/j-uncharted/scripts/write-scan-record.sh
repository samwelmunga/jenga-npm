#!/usr/bin/env bash
# write-scan-record.sh — write a COMMITTED baseline scan-record after a successful onboard/refresh run
#
# Usage: write-scan-record.sh [options] [<report.json>]
#        discover-subsystems.sh <root> | write-scan-record.sh [options]
#        write-scan-record.sh --help
#
# `onboard` mode (and, once E40_S07_T02/T03 land, `refresh` mode) needs a durable, DISKED record
# of what a scan actually found, so a later run can tell what changed since the last one. This
# script is that record's writer, and only that — baseline DISCOVERY (which scan-record is the
# authoritative one to diff against) and DIFF CLASSIFICATION (unchanged/changed/new/removed) are
# separate, not-yet-implemented scripts (E40_S07_T02, E40_S07_T03). This script only writes.
#
# This is deliberately NOT elicitation-state.sh's persistence mechanism. elicitation-state.sh's
# state file is explicit, transient SESSION SCRATCH — git-ignored, meant to survive a pause within
# one elicitation, not to persist meaning between separate onboard/refresh runs weeks or months
# apart. This record is the opposite: COMMITTED to the repository (never git-ignored), and is the
# only thing that gives a future `refresh` run something durable to compare against.
#
# This script performs NO discovery of its own. It consumes discover-subsystems.sh's ranked
# output (the same report apply-subsystem-cap.sh consumes) and contributes only the record write.
# It is read-only against the analysed codebase — its only write is the scan-record file itself.
#
# ---------------------------------------------------------------------------
# INPUT
# ---------------------------------------------------------------------------
# discover-subsystems.sh's JSON report, from a file argument or from stdin (`-`, or no argument) —
# the same input contract apply-subsystem-cap.sh uses, so both scripts can consume the identical
# discover-subsystems.sh invocation in one onboard run. The fields read are the report's `root`
# (repo-relative analysed root) plus each `candidates[]` entry's `path`, `files`, and `lines` —
# real fields discover-subsystems.sh actually emits (see that script's own OUTPUT CONTRACT
# comment), nothing invented. Everything else in the input report is ignored.
#
# ---------------------------------------------------------------------------
# OPTIONS
# ---------------------------------------------------------------------------
#   --out-dir DIR    Where the scan-record is written. Default <repo-root>/project/rapports/analysis
#                    — the same directory the Understanding Document convention uses, kept
#                    distinguishable from it by filename suffix (see OUTPUT below), never by a
#                    separate location.
#   --json-out FILE  Also write the same JSON to this exact path (in addition to the timestamped
#                    file under --out-dir). Not written unless requested.
#   --label TEXT     Human label for the analysed codebase, used only in the output filename's
#                    slug. Default: the report's own `root` (or its basename when `root` is "."
#                    or empty, the same fallback apply-subsystem-cap.sh uses).
#   -h, --help       Show this help and exit 0.
#
# ---------------------------------------------------------------------------
# OUTPUT
# ---------------------------------------------------------------------------
# stdout : the absolute path of the written scan-record file. One line, nothing else — so
#          `PATH=$(write-scan-record.sh ...)` is safe, matching run-engine.sh's own contract.
# stderr : notices and diagnostics only, never document content.
#
# Filename: uncharted-scan-record-<slug>-<YYYYMMDDTHHMMSSZ>.scan-record.json, under
# project/rapports/analysis/ — the SAME directory the Understanding Document uses, but never the
# same file: the `.scan-record.json` suffix (as opposed to a document's `.md`) is what keeps a run
# that produces both from overloading one artifact with two purposes. A name collision gets a
# -2, -3... suffix, the same convention run-engine.sh uses, so repeated runs leave a diffable
# history rather than clobbering each other. This script always writes a FRESH, timestamped file
# per run rather than mutating a prior one in place — baseline DISCOVERY (deciding which prior
# scan-record is the one to diff against) is a separate, later concern (E40_S07_T02); this script's
# only job is to make sure a new one always exists to be found.
#
# ---------------------------------------------------------------------------
# RECORD SHAPE (the written JSON, and what --json-out duplicates)
# ---------------------------------------------------------------------------
# {
#   "script":          "write-scan-record.sh",
#   "version": 1,
#   "baseline_commit":  "<short HEAD SHA>" | null,   // null only when the repo has no commits yet
#   "scanned_at":       "<ISO 8601 UTC timestamp>",
#   "root":             "<repo-relative analysed root, from the input report>",
#   "candidates": [
#     { "path": "<path relative to root>", "files": <int>, "lines": <int> }, ...
#   ],
#   "candidate_count":  <int>,
#   "notices":          [ "<non-fatal diagnostic>", ... ]
# }
#
# `baseline_commit` is `git -C <repo-root> rev-parse --short HEAD` at scan time — the repo that
# OWNS the engine (this repo), matching every sibling script's REPO_ROOT anchor, not the analysed
# root (which `import`-staged or out-of-repo targets may not even share a git history with).
#
# ---------------------------------------------------------------------------
# EXIT CODES
# ---------------------------------------------------------------------------
#   0 — success; scan-record written, its path printed on stdout
#   1 — usage error: unknown flag, missing value, more than one positional input
#   2 — input error: report missing/unreadable/unparseable JSON, or not a discover-subsystems.sh
#       report (no "candidates" array)
#   4 — write failure: --out-dir (or --json-out's directory) could not be created or is not
#       writable. Deliberately fatal: a "successful" run that silently failed to leave a durable
#       record would defeat the entire point of this script, the same reasoning
#       apply-subsystem-cap.sh applies to its own rapport write.
#
# Examples:
#   discover-subsystems.sh . | write-scan-record.sh
#   discover-subsystems.sh . > s.json && write-scan-record.sh --label "my-app" s.json
#   write-scan-record.sh --json-out /tmp/latest-scan-record.json s.json
#
# Requires: bash, git, python3. jq is NOT required — JSON is parsed and emitted by python3.

set -euo pipefail

OUT_DIR=""
JSON_OUT=""
LABEL=""
INPUT=""

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)

usage() {
  cat <<EOF
Usage: $(basename "$0") [options] [<report.json>]

Write a COMMITTED baseline scan-record from discover-subsystems.sh output: baseline_commit
(repo HEAD short SHA), scanned_at (ISO 8601 UTC), root, and one candidates[] entry per subsystem
(path, files, lines). Unlike elicitation-state.sh's transient session scratch, this record is
never git-ignored and is meant to survive indefinitely between onboard/refresh runs.

Arguments:
  <report.json>    discover-subsystems.sh output. Omit, or pass "-", to read stdin.

Options:
  --out-dir DIR    Directory for the scan-record (default: <repo-root>/project/rapports/analysis)
  --json-out FILE  Also write the same JSON to this exact path
  --label TEXT     Human label used only in the output filename's slug (default: the report's root)
  -h, --help       Show this help and exit

Exit codes: 0 success, 1 usage error, 2 input error, 4 write failure.
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
    --out-dir)     require_value "--out-dir" "$#";    OUT_DIR="$2"; shift 2 ;;
    --out-dir=*)   OUT_DIR="${1#*=}"; shift ;;
    --json-out)    require_value "--json-out" "$#";   JSON_OUT="$2"; shift 2 ;;
    --json-out=*)  JSON_OUT="${1#*=}"; shift ;;
    --label)       require_value "--label" "$#";      LABEL="$2"; shift 2 ;;
    --label=*)     LABEL="${1#*=}"; shift ;;
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
    echo "       Expected discover-subsystems.sh JSON output." >&2
    exit 2
  fi
  if [ ! -f "$INPUT" ] || [ ! -r "$INPUT" ]; then
    echo "Error: input report is not a readable file: $INPUT" >&2
    exit 2
  fi
  INPUT=$(cd -- "$(dirname -- "$INPUT")" && pwd -P)/$(basename -- "$INPUT")
fi

# ---------------------------------------------------------------------------
# Output destinations — pre-flighted BEFORE any work, same fail-fast contract as
# run-engine.sh / apply-subsystem-cap.sh: an unwritable destination must surface with nothing
# done, rather than after the record has already been computed.
#
# Anchored on THIS SCRIPT, not on the analysed root: the record belongs to the project that owns
# the engine, even when the analysed root lives elsewhere (import staging areas, out-of-repo
# targets).
# ---------------------------------------------------------------------------

REPO_ROOT=$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel 2>/dev/null || true)
[ -n "$REPO_ROOT" ] || REPO_ROOT="$(pwd -P)"

[ -n "$OUT_DIR" ] || OUT_DIR="$REPO_ROOT/project/rapports/analysis"
mkdir -p "$OUT_DIR" 2>/dev/null || {
  echo "Error: could not create output directory: $OUT_DIR" >&2
  exit 4
}
[ -w "$OUT_DIR" ] || { echo "Error: output directory is not writable: $OUT_DIR" >&2; exit 4; }
OUT_DIR=$(cd -- "$OUT_DIR" && pwd -P)

if [ -n "$JSON_OUT" ]; then
  JSON_OUT_DIR=$(dirname -- "$JSON_OUT")
  [ -d "$JSON_OUT_DIR" ] || { echo "Error: --json-out directory does not exist: $JSON_OUT_DIR" >&2; exit 4; }
  [ -w "$JSON_OUT_DIR" ] || { echo "Error: --json-out directory is not writable: $JSON_OUT_DIR" >&2; exit 4; }
  JSON_OUT=$(cd -- "$JSON_OUT_DIR" && pwd -P)/$(basename -- "$JSON_OUT")
fi

# baseline_commit is the ENGINE REPO's HEAD, not the analysed root's — see header. null (not a
# usage error) when this repo has no commits yet; a notice records why.
BASELINE_COMMIT=$(git -C "$REPO_ROOT" rev-parse --short HEAD 2>/dev/null || true)
SCANNED_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)
STAMP=$(date -u +%Y%m%dT%H%M%SZ)

# ---------------------------------------------------------------------------
# Read the discoverer's report, build the record, write it
# ---------------------------------------------------------------------------
# Captured into a variable and run with `python3 -c`, exactly as run-engine.sh and
# apply-subsystem-cap.sh do: a `python3 - <<PY` heredoc would occupy python's stdin, and this
# script must itself be able to read stdin (discover-subsystems.sh . | write-scan-record.sh).

PY_SRC=$(cat <<'PY'
import json
import os
import re
import sys

(INPUT, OUT_DIR, JSON_OUT, LABEL, BASELINE_COMMIT, SCANNED_AT, STAMP) = sys.argv[1:8]

notices = []

# --- read the discoverer's report ---------------------------------------------------------------

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
    sys.stderr.write("       Expected discover-subsystems.sh JSON output.\n")
    sys.exit(2)

try:
    report = json.loads(raw)
except ValueError as exc:
    sys.stderr.write("Error: input report is not valid JSON (%s): %s\n" % (origin, exc))
    sys.stderr.write("       Expected discover-subsystems.sh JSON output.\n")
    sys.exit(2)

if not isinstance(report, dict) or not isinstance(report.get("candidates"), list):
    sys.stderr.write("Error: input report has no \"candidates\" array (%s).\n" % origin)
    sys.stderr.write("       This does not look like discover-subsystems.sh output.\n")
    sys.exit(2)

produced_by = report.get("script")
if produced_by and produced_by != "discover-subsystems.sh":
    notices.append(
        "Input reports itself as \"%s\" rather than discover-subsystems.sh; proceeding on the "
        "strength of its candidates array." % produced_by)

root = report.get("root") or report.get("root_absolute") or "(unknown root)"
root_absolute = report.get("root_absolute") or ""
# "." is what the discoverer reports when the analysed root IS the repo root -- a useless label
# for a filename slug. Fall back to the directory's real name, same convention
# apply-subsystem-cap.sh uses for its rapport label.
if LABEL:
    label = LABEL
elif root not in (".", "", "./"):
    label = root
else:
    label = os.path.basename(root_absolute.rstrip("/")) or root

if not BASELINE_COMMIT:
    notices.append(
        "Could not resolve a HEAD commit for this repository (no commits yet, or not a git work "
        "tree); \"baseline_commit\" was recorded as null."
    )

# --- candidates[] — only real fields discover-subsystems.sh actually emits ----------------------

candidates = []
for c in report.get("candidates", []):
    if not isinstance(c, dict):
        continue
    candidates.append({
        "path": c.get("path"),
        "files": c.get("files", 0),
        "lines": c.get("lines", 0),
    })

record = {
    "script": "write-scan-record.sh",
    "version": 1,
    "baseline_commit": BASELINE_COMMIT or None,
    "scanned_at": SCANNED_AT,
    "root": root,
    "candidates": candidates,
    "candidate_count": len(candidates),
    "notices": notices,
}

# --- filename: slugged label + timestamp, collision-safe --------------------------------------

slug = re.sub(r"[^a-z0-9]+", "-", label.lower()).strip("-")[:40]
if not slug:
    slug = "target"

out_file = os.path.join(OUT_DIR, "uncharted-scan-record-%s-%s.scan-record.json" % (slug, STAMP))
n = 2
while os.path.exists(out_file):
    out_file = os.path.join(
        OUT_DIR, "uncharted-scan-record-%s-%s-%d.scan-record.json" % (slug, STAMP, n))
    n += 1

body = json.dumps(record, indent=2, ensure_ascii=False) + "\n"

try:
    with open(out_file, "w", encoding="utf-8") as fh:
        fh.write(body)
except OSError as exc:
    sys.stderr.write("Error: could not write scan-record: %s\n" % exc)
    sys.exit(4)

if JSON_OUT:
    try:
        with open(JSON_OUT, "w", encoding="utf-8") as fh:
            fh.write(body)
    except OSError as exc:
        sys.stderr.write("Error: could not write --json-out file: %s\n" % exc)
        sys.exit(4)

for n_ in notices:
    sys.stderr.write("Notice: %s\n" % n_)

print(out_file)
PY
)

python3 -c "$PY_SRC" \
  "$INPUT" "$OUT_DIR" "$JSON_OUT" "$LABEL" "$BASELINE_COMMIT" "$SCANNED_AT" "$STAMP"
