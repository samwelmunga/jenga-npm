#!/usr/bin/env bash
# apply-subsystem-cap.sh — bound the number of backfilled epics `onboard` produces, and make
#                          every subsystem it drops durable and auditable
#
# Usage: apply-subsystem-cap.sh [options] [<report.json>]
#        discover-subsystems.sh <root> | apply-subsystem-cap.sh [options]
#        apply-subsystem-cap.sh --help
#
# `onboard` mode backfills a board for a codebase that was never built through Jenga. Left
# unbounded it would emit one epic per discovered subsystem, and adopting Jenga into a large
# repository would flood the board with dozens of epics nobody asked for. The CAP is that bound.
#
# The cap is the easy half. The hard requirement — the reason this is its own script rather than
# three lines inside the epic generator — is that the cap is NEVER SILENT:
#
#     A user who onboards a 40-subsystem repo and gets 8 epics must be able to find out, LATER
#     AND ON DISK, which 32 subsystems were not turned into epics, and why.
#
# A chat message does not satisfy that. It scrolls away, it is not in the repository, and the
# person who inherits the board six months later never saw it. So every run writes a
# human-readable Subsystem Cap section into an analysis rapport under project/rapports/analysis/,
# naming every dropped subsystem individually. There is deliberately NO flag to suppress that
# write and no "… and 32 more" elision in it: either would reintroduce exactly the silent
# truncation this script exists to prevent.
#
# This script performs NO discovery of its own. It consumes discover-subsystems.sh's ranked
# output and contributes only the cap decision and its record. It is read-only against the
# analysed codebase — its only writes are the rapport and, on request, the JSON report.
#
# ---------------------------------------------------------------------------
# INPUT
# ---------------------------------------------------------------------------
# discover-subsystems.sh's JSON report, from a file argument or from stdin (`-`, or no argument).
# The fields consumed are `candidates[].rank`, `.path`, `.score`, `.files`, `.lines`, plus the
# report's `root` / `root_absolute` for labelling. Anything else is passed through untouched.
#
# The candidate array arrives already ranked (score descending, then path ascending). This script
# SLICES it; it does not re-rank. Re-sorting here would silently disagree with the discoverer the
# moment its tie-break changed. If the array order and the `rank` fields disagree — which only
# happens if something edited the report in between — a notice says so and array order wins,
# because array order is what the discoverer's own consumers see.
#
# ---------------------------------------------------------------------------
# OPTIONS
# ---------------------------------------------------------------------------
#   --cap N          Maximum number of subsystems that become backfilled epics. Default 8,
#                    which is the figure `onboard`'s own worked example assumes. Must be >= 1:
#                    a cap of 0 or below is a USAGE ERROR, not an empty run, because "produce no
#                    epics at all" is never what a caller meant and must fail loudly.
#   --rapport FILE   Append the Subsystem Cap section to this existing analysis document — the
#                    one run-engine.sh --mode onboard already wrote for this codebase. The normal
#                    onboard flow: the cap record belongs with the analysis that produced it.
#   --out-dir DIR    Where a STANDALONE cap record is written when --rapport is not given.
#                    Default <repo-root>/project/rapports/analysis.
#   --json-out FILE  Also write this script's JSON report to a file. stdout gets it regardless.
#   --label TEXT     Human label for the analysed codebase in the rapport. Default: the report's
#                    own `root`.
#   -h, --help       Show this help and exit 0.
#
# ---------------------------------------------------------------------------
# OUTPUT (stdout, JSON)
# ---------------------------------------------------------------------------
# {
#   "script": "apply-subsystem-cap.sh",
#   "version": 1,
#   "cap":              <int>,      // the cap in effect
#   "root":             "<from the input report>",
#   "root_absolute":    "<from the input report>",
#   "candidate_count":  <int>,      // how many candidates were offered
#   "kept_count":       <int>,
#   "dropped_count":    <int>,
#   "capped":           <bool>,     // true when the cap actually removed something
#   "rapport":          "<absolute path of the document carrying the drop record>",
#   "rapport_mode":     "appended" | "created",
#   "kept":    [ { "rank", "path", "absolute_path", "score", "files", "lines" }, ... ],
#   "dropped": [ { "rank", "path", "absolute_path", "score", "files", "lines", "reason" }, ... ],
#   "notices": [ "<non-fatal diagnostic>", ... ]
# }
#
# Every `dropped` entry carries an explicit `reason` string — "below cap of N" — so a consumer
# never has to infer why an entry is in that array.
#
# When the candidate count is at or below the cap, `dropped` is an EMPTY ARRAY and the exit code
# is 0. That is a normal, successful run, not a degenerate one. The rapport section is still
# written in that case: "the cap was applied and removed nothing" is itself a fact worth being
# able to look up, and always writing it means the record's absence is unambiguous evidence that
# this script never ran.
#
# ---------------------------------------------------------------------------
# EXIT CODES
# ---------------------------------------------------------------------------
#   0 — success (including the nothing-was-dropped case)
#   1 — usage error: unknown flag, missing value, non-integer cap, or a cap of 0 or below
#   2 — input error: report file missing/unreadable, unparseable JSON, or not a
#       discover-subsystems.sh report with a candidates array
#   4 — write failure: the rapport could not be written. Deliberately FATAL. Exiting 0 with a
#       clean kept/dropped JSON and no durable record would be a silent truncation wearing a
#       different hat, so the destination is pre-flighted before any work and a failure to
#       record the drop fails the whole run.
#
# Examples:
#   discover-subsystems.sh . | apply-subsystem-cap.sh
#   discover-subsystems.sh . > s.json && apply-subsystem-cap.sh --cap 12 s.json
#   apply-subsystem-cap.sh --rapport project/rapports/analysis/uncharted-onboard-app-….md s.json
#
# Requires: bash, python3. jq is NOT required — JSON is parsed and emitted by python3.

set -euo pipefail

DEFAULT_CAP=8

CAP="$DEFAULT_CAP"
RAPPORT=""
OUT_DIR=""
JSON_OUT=""
LABEL=""
INPUT=""

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)

usage() {
  cat <<EOF
Usage: $(basename "$0") [options] [<report.json>]

Apply the onboard epic cap to discover-subsystems.sh output. Emits JSON with explicit "kept" and
"dropped" arrays, and always records every dropped subsystem BY NAME in a human-readable
Subsystem Cap section of an analysis rapport. Dropped subsystems are never silently truncated.

Arguments:
  <report.json>    discover-subsystems.sh output. Omit, or pass "-", to read stdin.

Options:
  --cap N          Max subsystems that become epics (default: $DEFAULT_CAP, minimum: 1)
  --rapport FILE   Append the cap record to this existing analysis document
  --out-dir DIR    Directory for a standalone cap record (default: <repo-root>/project/rapports/analysis)
  --json-out FILE  Also write this script's JSON report to FILE
  --label TEXT     Human label for the codebase in the rapport (default: the report's root)
  -h, --help       Show this help and exit

Exit codes: 0 success, 1 usage error, 2 input error, 4 rapport write failure.
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

validate_cap() {
  # A cap of 0 or below is an ERROR, never an empty run. Validated here, before the report is even
  # read, so the message can name the value actually received rather than the run failing later
  # with an inexplicably empty result set.
  if ! [[ "$1" =~ ^-?[0-9]+$ ]]; then
    die_usage "--cap requires an integer, got \"$1\""
  fi
  if [ "$1" -lt 1 ]; then
    echo "Error: --cap must be a positive integer, got \"$1\"." >&2
    echo "       A cap of 0 or below would mean \"produce no backfilled epics at all\", which is" >&2
    echo "       never a meaningful onboard run - so it is rejected rather than silently dropping" >&2
    echo "       every discovered subsystem. Pass --cap 1 or higher." >&2
    echo >&2
    usage >&2
    exit 1
  fi
}

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------

while [ "$#" -gt 0 ]; do
  case "$1" in
    --cap)         require_value "--cap" "$#";       CAP="$2"; shift 2 ;;
    --cap=*)       CAP="${1#*=}"; shift ;;
    --rapport)     require_value "--rapport" "$#";   RAPPORT="$2"; shift 2 ;;
    --rapport=*)   RAPPORT="${1#*=}"; shift ;;
    --out-dir)     require_value "--out-dir" "$#";   OUT_DIR="$2"; shift 2 ;;
    --out-dir=*)   OUT_DIR="${1#*=}"; shift ;;
    --json-out)    require_value "--json-out" "$#";  JSON_OUT="$2"; shift 2 ;;
    --json-out=*)  JSON_OUT="${1#*=}"; shift ;;
    --label)       require_value "--label" "$#";     LABEL="$2"; shift 2 ;;
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

validate_cap "$CAP"

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
# Output destinations — pre-flighted BEFORE any work
# ---------------------------------------------------------------------------
# Same fail-fast contract as run-engine.sh: an unwritable destination must surface with nothing
# done, rather than after a report has been emitted. Here it matters more than usual, because the
# rapport IS the audit trail; a run that reports drops it never recorded is the failure mode this
# script exists to rule out.
#
# Anchored on THIS SCRIPT, not on the analysed root: the cap record belongs to the project that
# owns the engine, even when onboarding a codebase that lives elsewhere.

REPO_ROOT=$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel 2>/dev/null || true)
[ -n "$REPO_ROOT" ] || REPO_ROOT="$(pwd -P)"

if [ -n "$RAPPORT" ]; then
  if [ ! -f "$RAPPORT" ]; then
    echo "Error: --rapport document does not exist: $RAPPORT" >&2
    echo "       Pass the analysis document run-engine.sh --mode onboard wrote, or omit" >&2
    echo "       --rapport to have a standalone cap record created instead." >&2
    exit 4
  fi
  if [ ! -w "$RAPPORT" ]; then
    echo "Error: --rapport document is not writable: $RAPPORT" >&2
    exit 4
  fi
  RAPPORT=$(cd -- "$(dirname -- "$RAPPORT")" && pwd -P)/$(basename -- "$RAPPORT")
else
  [ -n "$OUT_DIR" ] || OUT_DIR="$REPO_ROOT/project/rapports/analysis"
  mkdir -p "$OUT_DIR" 2>/dev/null || {
    echo "Error: could not create output directory: $OUT_DIR" >&2
    exit 4
  }
  [ -w "$OUT_DIR" ] || { echo "Error: output directory is not writable: $OUT_DIR" >&2; exit 4; }
  OUT_DIR=$(cd -- "$OUT_DIR" && pwd -P)
fi

if [ -n "$JSON_OUT" ]; then
  JSON_OUT_DIR=$(dirname -- "$JSON_OUT")
  [ -d "$JSON_OUT_DIR" ] || { echo "Error: --json-out directory does not exist: $JSON_OUT_DIR" >&2; exit 4; }
  [ -w "$JSON_OUT_DIR" ] || { echo "Error: --json-out directory is not writable: $JSON_OUT_DIR" >&2; exit 4; }
  JSON_OUT=$(cd -- "$JSON_OUT_DIR" && pwd -P)/$(basename -- "$JSON_OUT")
fi

ISO_TS=$(date -u +%Y%m%dT%H%M%SZ)

# ---------------------------------------------------------------------------
# Apply the cap and record it
# ---------------------------------------------------------------------------

# The python source is captured into a variable and run with `python3 -c`, exactly as
# run-engine.sh does. A `python3 - <<PY` heredoc would occupy python's stdin, and this script has
# to be able to READ stdin (`discover-subsystems.sh . | apply-subsystem-cap.sh`), so the heredoc
# form is not available here.
PY_SRC=$(cat <<'PY'
import json
import os
import re
import sys

INPUT, CAP_S, RAPPORT, OUT_DIR, JSON_OUT, LABEL, TS, DEFAULT_CAP_S = sys.argv[1:9]
CAP = int(CAP_S)

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

candidates = report.get("candidates")
root = report.get("root") or report.get("root_absolute") or "(unknown root)"
root_absolute = report.get("root_absolute") or ""
# "." is what the discoverer reports when the analysed root IS the repo root, and it is a useless
# label in a document somebody reads months later. Fall back to the directory's real name.
if LABEL:
    label = LABEL
elif root not in (".", "", "./"):
    label = root
else:
    label = os.path.basename(root_absolute.rstrip("/")) or root

# The array arrives ranked. Slicing it -- rather than re-sorting -- keeps this script from quietly
# disagreeing with the discoverer's own tie-break. A disagreement is reported, never repaired.
ranks = [c.get("rank") for c in candidates if isinstance(c, dict)]
if ranks == sorted(r for r in ranks if isinstance(r, int)) and None not in ranks:
    pass
else:
    notices.append(
        "The candidates array is not in ascending rank order. Array order was used for the cap, "
        "because that is the order the discoverer's consumers see; the report was not reordered.")


def field(c, name, default=None):
    return c.get(name, default) if isinstance(c, dict) else default


def entry(c, reason=None):
    out = {
        "rank": field(c, "rank"),
        "path": field(c, "path"),
        "absolute_path": field(c, "absolute_path"),
        "score": field(c, "score"),
        "files": field(c, "files"),
        "lines": field(c, "lines"),
    }
    if reason is not None:
        out["reason"] = reason
    return out


# --- the cap ------------------------------------------------------------------------------------
# The whole arithmetic, in two lines. It is small on purpose: the volume of this script is the
# RECORD of the decision, not the decision.

reason = "below cap of %d" % CAP
kept = [entry(c) for c in candidates[:CAP]]
dropped = [entry(c, reason) for c in candidates[CAP:]]
capped = bool(dropped)

# --- the drop record ----------------------------------------------------------------------------

# The --rapport document is read HERE, before the section is assembled, not at write time. Any
# notice raised by inspecting it has to be able to reach the section text -- and section text that
# has already been joined cannot be amended. Getting this order wrong is what made the durable
# record LESS complete than the ephemeral stderr it exists to outlive, which inverts the whole
# design intent of this script.
existing = None
if RAPPORT:
    try:
        with open(RAPPORT, "r", encoding="utf-8") as fh:
            existing = fh.read()
    except OSError as exc:
        sys.stderr.write("Error: could not read --rapport document: %s\n" % exc)
        sys.exit(4)
    if "## Subsystem Cap" in existing:
        notices.append(
            "The rapport already carried a Subsystem Cap section; this run's record was appended "
            "after it rather than replacing it, so earlier cap decisions stay auditable.")


def fmt_score(v):
    return ("%.2f" % v) if isinstance(v, (int, float)) else "—"


def fmt_int(v):
    return ("%d" % v) if isinstance(v, int) else "—"


def cell(v):
    # Pipes inside a cell would break the table; nothing else needs escaping in a path.
    return str(v if v not in (None, "") else "—").replace("|", "\\|")


def table(rows, with_reason):
    head = "| Rank | Score | Subsystem | Files | Lines |"
    rule = "|---:|---:|---|---:|---:|"
    if with_reason:
        head += " Reason |"
        rule += "---|"
    out = [head, rule]
    for r in rows:
        line = "| %s | %s | `%s` | %s | %s |" % (
            fmt_int(r["rank"]), fmt_score(r["score"]), cell(r["path"]),
            fmt_int(r["files"]), fmt_int(r["lines"]))
        if with_reason:
            line += " %s |" % cell(r.get("reason"))
        out.append(line)
    return out


section = []
section.append("## Subsystem Cap")
section.append("")
section.append("| | |")
section.append("|---|---|")
section.append("| Codebase | `%s` |" % cell(label))
section.append("| Cap in effect | %d |" % CAP)
section.append("| Subsystems discovered | %d |" % len(candidates))
section.append("| Kept — became backfilled epics | %d |" % len(kept))
section.append("| Dropped — did **not** become epics | %d |" % len(dropped))
section.append("| Recorded | %s |" % TS)
section.append("")

if capped:
    section.append(
        "`onboard` caps how many backfilled epics it creates so that adopting Jenga into a large "
        "codebase does not flood the board. **%d of the %d subsystems discovered here were not "
        "turned into epics.** They are all named below — the cap is never applied silently, and "
        "this list is never elided."
        % (len(dropped), len(candidates)))
else:
    section.append(
        "All %d discovered subsystem(s) fit within the cap of %d, so nothing was dropped. This "
        "section is written on every capped run, including this one, so that its absence means "
        "the cap was never applied — not that it happened to drop nothing."
        % (len(candidates), CAP))
section.append("")

section.append("### Kept — backfilled as epics")
section.append("")
if kept:
    section.extend(table(kept, with_reason=False))
else:
    section.append("_No subsystems were discovered, so none were kept._")
section.append("")

section.append("### Dropped — not backfilled")
section.append("")
if dropped:
    # Every dropped subsystem is named. No truncation, no "… and N more": eliding this list is
    # precisely the silent truncation the cap record exists to prevent.
    section.extend(table(dropped, with_reason=True))
    section.append("")
    section.append(
        "These subsystems still exist in the codebase — they simply have no backfilled epic. To "
        "adopt one, either re-run `onboard` with a higher `--cap`, or bring it onto the board "
        "individually with `/uncharted segment <path>`.")
else:
    section.append("_None. Every discovered subsystem is on the board._")
section.append("")

if notices:
    section.append("### Notices")
    section.append("")
    for n in notices:
        section.append("- %s" % n)
    section.append("")

section_text = "\n".join(section).rstrip("\n") + "\n"

# --- write it -----------------------------------------------------------------------------------


def slugify(text):
    s = re.sub(r"[^A-Za-z0-9]+", "-", str(text)).strip("-").lower()
    return (s or "codebase")[:48]


if RAPPORT:
    # `existing` was read above, before the section was assembled.
    body = existing.rstrip("\n") + "\n\n---\n\n" + section_text
    try:
        with open(RAPPORT, "w", encoding="utf-8") as fh:
            fh.write(body)
    except OSError as exc:
        sys.stderr.write("Error: could not write --rapport document: %s\n" % exc)
        sys.exit(4)
    rapport_path = RAPPORT
    rapport_mode = "appended"
else:
    base = slugify(os.path.basename(root_absolute.rstrip("/")) or root)
    stem = "uncharted-onboard-cap-%s-%s" % (base, TS)
    # Collision suffix rather than overwrite, matching run-engine.sh: an existing cap record is
    # evidence of an earlier decision and must not be destroyed by a later one.
    path = os.path.join(OUT_DIR, stem + ".md")
    n = 2
    while os.path.exists(path):
        path = os.path.join(OUT_DIR, "%s-%d.md" % (stem, n))
        n += 1
    header = "# Onboard Subsystem Cap — %s\n\n" % label
    header += ("_Generated by `apply-subsystem-cap.sh` for `/uncharted onboard`. This document is "
               "the durable record of which discovered subsystems became backfilled epics and "
               "which did not._\n\n")
    try:
        with open(path, "w", encoding="utf-8") as fh:
            fh.write(header + section_text)
    except OSError as exc:
        sys.stderr.write("Error: could not write cap record: %s\n" % exc)
        sys.exit(4)
    rapport_path = path
    rapport_mode = "created"

# --- report -------------------------------------------------------------------------------------

result = {
    "script": "apply-subsystem-cap.sh",
    "version": 1,
    "cap": CAP,
    "default_cap": int(DEFAULT_CAP_S),
    "root": root,
    "root_absolute": root_absolute or None,
    "candidate_count": len(candidates),
    "kept_count": len(kept),
    "dropped_count": len(dropped),
    "capped": capped,
    "rapport": rapport_path,
    "rapport_mode": rapport_mode,
    "kept": kept,
    "dropped": dropped,
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

if capped:
    sys.stderr.write(
        "Notice: %d of %d discovered subsystem(s) were dropped by the cap of %d. Every one is "
        "named in %s\n" % (len(dropped), len(candidates), CAP, rapport_path))
for n in notices:
    sys.stderr.write("Notice: %s\n" % n)
PY
)

python3 -c "$PY_SRC" \
  "$INPUT" "$CAP" "$RAPPORT" "$OUT_DIR" "$JSON_OUT" "$LABEL" "$ISO_TS" "$DEFAULT_CAP"
