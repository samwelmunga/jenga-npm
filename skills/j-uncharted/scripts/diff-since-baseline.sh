#!/usr/bin/env bash
# diff-since-baseline.sh — classify candidates as unchanged/changed/new/removed since a baseline
#
# Usage: diff-since-baseline.sh [options] [<baseline.json>]
#        find-scan-baseline.sh <root> | diff-since-baseline.sh [options]
#        diff-since-baseline.sh --help
#
# `refresh` mode (E40_S07_T04, not yet implemented) needs to know what actually changed since a
# baseline before it decides what to do about it. This script is the "what changed" step, and
# only that step — it does not locate the baseline (find-scan-baseline.sh, E40_S07_T02, already
# implemented) and does not decide what `refresh` does with the classified result (that belongs
# in skills/j-uncharted/SKILL.md's refresh mode section, E40_S07_T04). It is read-only: it never
# writes to the analysed codebase or the board.
#
# ---------------------------------------------------------------------------
# INPUT
# ---------------------------------------------------------------------------
# BASELINE (required): find-scan-baseline.sh's JSON output, from a file argument or from stdin
# (`-`, or no argument) — the same input contract write-scan-record.sh / apply-subsystem-cap.sh
# use. Two shapes are accepted, matching find-scan-baseline.sh's own two success tiers exactly
# (read that script's header comment for the authoritative description):
#
#   Tier 1 ("source": "scan-record")  — has a `candidates[]` array ({path, files, lines} each),
#     `baseline_commit`, and `root`. Both `new` and `removed` are computed by set-difference
#     against the fresh discovery run below.
#
#   Tier 2 ("source": "inferred")  — has NO `candidates[]` array at all (only `baseline_commit`,
#     `root`, and `inferred_from[]`). There is nothing to diff the fresh candidate set's
#     MEMBERSHIP against, so `new` and `removed` are NOT computed for a Tier 2 baseline — both
#     stay empty arrays by construction, always, never an error. Every fresh-discovery candidate
#     is instead classified as EITHER `unchanged` or `changed`, via the identical git-diff-since-
#     `baseline_commit` check Tier 1 uses. This is documented, intentional behaviour, not a
#     degraded fallback — see the task's own acceptance criteria (E40_S07_T03).
#
# A Tier 3 "no baseline" result (find-scan-baseline.sh exit 3) is the CALLER's problem, not this
# script's — this script always receives an already-found baseline. Passing it one anyway (e.g. a
# hand-built JSON object with neither shape) is an input error (exit 2).
#
# FRESH CANDIDATE SET: by default this script invokes discover-subsystems.sh itself (no extra
# flags — a plain default-options pass) against the baseline's own `root` field, resolved
# relative to the engine repo root (see REPO ANCHORING below). Pass `--fresh FILE` (or `--fresh -`
# for stdin) to supply an already-computed discover-subsystems.sh report instead — useful when a
# caller already ran discovery once in the same pass and wants to reuse it rather than pay for a
# second walk. Only ONE of `<baseline.json>` / `--fresh` may be stdin (`-`) at a time; asking for
# both is a usage error.
#
# Candidates are matched between baseline and fresh discovery BY `path` ONLY — never by `rank` or
# `score`. apply-subsystem-cap.sh's `kept`/`dropped` entries recompute rank/score fresh every run,
# and those can shift between runs with zero material change underneath, so they are never a
# valid diff key. A directory rename is deliberately NOT detected as a rename — it classifies as
# a `removed` (old path) plus a `new` (new path). Rename detection is out of scope.
#
# ---------------------------------------------------------------------------
# REPO ANCHORING
# ---------------------------------------------------------------------------
# `REPO_ROOT` is resolved from THIS SCRIPT's own location (`git -C <script-dir> rev-parse
# --show-toplevel`), exactly like every sibling script (find-scan-baseline.sh,
# write-scan-record.sh, apply-subsystem-cap.sh) — the engine repo owns this lookup even when the
# analysed root lives elsewhere. `baseline_commit` is understood to be a commit reachable from
# this same repo's history (write-scan-record.sh writes it as the ENGINE repo's HEAD, not the
# analysed root's — see that script's own header), so the git-diff check below always runs
# against REPO_ROOT. The baseline's `root` field is repo-relative to REPO_ROOT; a candidate's own
# `path` field is relative to `root`. The full repo-relative path used for both `discover-
# subsystems.sh`'s target directory and the `git diff` path is therefore built by joining the two
# (see FULL PATH RESOLUTION below).
#
# ---------------------------------------------------------------------------
# CLASSIFICATION
# ---------------------------------------------------------------------------
#   unchanged — same path present in both candidate sets, and
#               `git diff --name-only <baseline_commit>..HEAD -- <full-path>` is EMPTY.
#   changed   — same path present in both candidate sets, and that git diff is NON-EMPTY.
#   new       — a candidate path present in the fresh discovery run with no baseline counterpart.
#               Tier 2: always empty.
#   removed   — a candidate path present in the baseline with no fresh-run counterpart.
#               Tier 2: always empty.
#
# Two edge cases in the git-diff check itself, both handled explicitly rather than silently:
#   - `baseline_commit` is `null` (write-scan-record.sh's own documented case: the engine repo had
#     zero commits at scan time). There is nothing to diff against, so EVERY matched/fresh
#     candidate is conservatively classified `changed` (never guessed `unchanged`), with a notice
#     explaining why.
#   - `baseline_commit` does not resolve to a real commit in this repo's history (e.g. squashed or
#     rebased away since the baseline was captured). Checked ONCE up front via
#     `git cat-file -e <sha>^{commit}`; on failure this is an INPUT error (exit 2) — the baseline
#     itself is stale/invalid, not something this script can safely guess around per-candidate.
#
# ---------------------------------------------------------------------------
# FULL PATH RESOLUTION
# ---------------------------------------------------------------------------
# Both `root` (from the baseline) and each candidate's `path` are normalized the same way
# find-scan-baseline.sh's own `norm()` does: strip a trailing slash; collapse "", ".", "./" to the
# canonical "." meaning "the whole repository" / "the whole root". The full repo-relative path is:
#   root == "."          -> candidate path (or "." if the candidate path is also ".")
#   candidate path == "." -> root itself
#   otherwise             -> "<root>/<candidate path>"
#
# ---------------------------------------------------------------------------
# OPTIONS
# ---------------------------------------------------------------------------
#   --fresh FILE                    Use this discover-subsystems.sh JSON report as the fresh
#                                   candidate set instead of running discover-subsystems.sh.
#                                   File path, or "-" to read from stdin.
#   --root ROOT                     Override the root passed to discover-subsystems.sh when
#                                   --fresh is not given. Default: the baseline's own `root` field.
#   --discover-subsystems-bin PATH  Path to discover-subsystems.sh. Default: the sibling script
#                                   in this same directory. Override for testing.
#   --json-out FILE                 Also write the same JSON this script prints on stdout to this
#                                   exact path. Not written unless requested. Pre-flighted before
#                                   any real work, same fail-fast contract as every sibling script.
#   -h, --help                      Show this help and exit 0.
#
# ---------------------------------------------------------------------------
# OUTPUT
# ---------------------------------------------------------------------------
# stdout : on success, a single JSON object, one line, nothing else — so
#          `RESULT=$(diff-since-baseline.sh ...)` is safe. Shape:
#
#          {
#            "script": "diff-since-baseline.sh",
#            "version": 1,
#            "root": "<repo-relative root, from the baseline>",
#            "baseline_source": "scan-record" | "inferred",
#            "baseline_commit": "<short SHA>" | null,
#            "unchanged": [ { "path", "files", "lines" }, ... ],
#            "changed":   [ { "path", "files", "lines", "changed_files": [ "...", ... ] }, ... ],
#            "new":       [ { "path", "files", "lines" }, ... ],   // Tier 2: always []
#            "removed":   [ { "path", "files", "lines" }, ... ],   // Tier 2: always []
#            "unchanged_count": <int>, "changed_count": <int>, "new_count": <int>, "removed_count": <int>,
#            "notices": [ "<non-fatal diagnostic>", ... ]
#          }
#
#          `files`/`lines` come from whichever side actually has them for that entry (the fresh
#          discovery run for `unchanged`/`changed`/`new`, the baseline for `removed`). Every entry
#          carries at minimum `path`. `changed_files` is the (capped at 50) list of repo-relative
#          paths `git diff --name-only` reported under that candidate, for auditability — never
#          silently dropped, matching this script family's house style.
#
# stderr : notices and diagnostics only, never document/record content.
#
# ---------------------------------------------------------------------------
# EXIT CODES
# ---------------------------------------------------------------------------
#   0 — success; classification computed and printed as JSON on stdout
#   1 — usage error: unknown flag, missing value, more than one positional baseline argument,
#       both the baseline and --fresh set to stdin at once
#   2 — input error: baseline JSON missing/unreadable/unparseable or not a recognised
#       find-scan-baseline.sh shape; --fresh JSON missing/unreadable/unparseable or not a
#       discover-subsystems.sh report (no "candidates" array); discover-subsystems.sh itself
#       failed or produced unparseable output; baseline_commit does not resolve to a real commit
#       in this repo's history
#   4 — write failure: --json-out's directory could not be found or is not writable
#
#   NOTE: `3` is deliberately NOT reused here. It is reserved by find-scan-baseline.sh for its own
#   "no baseline found" case, and that is a distinct concern from anything this script does — this
#   script always receives an already-found baseline as input.
#
# Examples:
#   find-scan-baseline.sh skills/j-uncharted | diff-since-baseline.sh
#   diff-since-baseline.sh /tmp/baseline.json
#   discover-subsystems.sh skills/j-uncharted > /tmp/fresh.json
#   find-scan-baseline.sh skills/j-uncharted | diff-since-baseline.sh --fresh /tmp/fresh.json
#
# Requires: bash, git, python3. jq is NOT required — JSON is parsed and emitted by python3.

set -euo pipefail

FRESH=""
ROOT_OVERRIDE=""
DISCOVER_BIN=""
JSON_OUT=""
BASELINE_INPUT=""

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)

usage() {
  cat <<EOF
Usage: $(basename "$0") [options] [<baseline.json>]

Classify each candidate as unchanged/changed/new/removed since a baseline: consumes
find-scan-baseline.sh's JSON output (Tier 1 "scan-record" or Tier 2 "inferred") plus a fresh
discover-subsystems.sh run, matches candidates by path (never rank/score), and reports which
paths are unchanged, changed (via git diff since baseline_commit), newly appeared, or removed.
Tier 2 baselines have no candidates[] to diff membership against, so new/removed always stay
empty arrays for them -- documented, intentional behaviour, not an error.

Arguments:
  <baseline.json>   find-scan-baseline.sh output. Omit, or pass "-", to read stdin.

Options:
  --fresh FILE                    Use this discover-subsystems.sh report as the fresh candidate
                                  set instead of running discover-subsystems.sh. "-" for stdin.
  --root ROOT                     Root to pass to discover-subsystems.sh when --fresh is not
                                  given (default: the baseline's own "root" field)
  --discover-subsystems-bin PATH  Path to discover-subsystems.sh (default: sibling script)
  --json-out FILE                 Also write the result JSON to this exact path
  -h, --help                      Show this help and exit

Exit codes: 0 success, 1 usage error, 2 input error, 4 write failure. (3 is reserved by
find-scan-baseline.sh and is never reused here.)
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
    --fresh)                    require_value "--fresh" "$#";                   FRESH="$2"; shift 2 ;;
    --fresh=*)                  FRESH="${1#*=}"; shift ;;
    --root)                     require_value "--root" "$#";                    ROOT_OVERRIDE="$2"; shift 2 ;;
    --root=*)                   ROOT_OVERRIDE="${1#*=}"; shift ;;
    --discover-subsystems-bin)  require_value "--discover-subsystems-bin" "$#"; DISCOVER_BIN="$2"; shift 2 ;;
    --discover-subsystems-bin=*) DISCOVER_BIN="${1#*=}"; shift ;;
    --json-out)                 require_value "--json-out" "$#";                JSON_OUT="$2"; shift 2 ;;
    --json-out=*)                JSON_OUT="${1#*=}"; shift ;;
    -h|--help)                  usage; exit 0 ;;
    --)
      shift
      [ "$#" -le 1 ] || die_usage "at most one <baseline.json> argument is accepted"
      [ "$#" -eq 0 ] || BASELINE_INPUT="$1"
      break ;;
    -)
      BASELINE_INPUT="-"; shift ;;
    -*)
      die_usage "unknown option \"$1\"" ;;
    *)
      [ -z "$BASELINE_INPUT" ] || die_usage "at most one <baseline.json> argument is accepted (got \"$BASELINE_INPUT\" and \"$1\")"
      BASELINE_INPUT="$1"; shift ;;
  esac
done

# ---------------------------------------------------------------------------
# Input resolution
# ---------------------------------------------------------------------------

if [ -z "$BASELINE_INPUT" ] || [ "$BASELINE_INPUT" = "-" ]; then
  BASELINE_INPUT="-"
else
  if [ ! -e "$BASELINE_INPUT" ]; then
    echo "Error: baseline input does not exist: $BASELINE_INPUT" >&2
    echo "       Expected find-scan-baseline.sh JSON output." >&2
    exit 2
  fi
  if [ ! -f "$BASELINE_INPUT" ] || [ ! -r "$BASELINE_INPUT" ]; then
    echo "Error: baseline input is not a readable file: $BASELINE_INPUT" >&2
    exit 2
  fi
  BASELINE_INPUT=$(cd -- "$(dirname -- "$BASELINE_INPUT")" && pwd -P)/$(basename -- "$BASELINE_INPUT")
fi

if [ -n "$FRESH" ] && [ "$FRESH" != "-" ]; then
  if [ ! -e "$FRESH" ]; then
    echo "Error: --fresh input does not exist: $FRESH" >&2
    exit 2
  fi
  if [ ! -f "$FRESH" ] || [ ! -r "$FRESH" ]; then
    echo "Error: --fresh input is not a readable file: $FRESH" >&2
    exit 2
  fi
  FRESH=$(cd -- "$(dirname -- "$FRESH")" && pwd -P)/$(basename -- "$FRESH")
fi

if [ "$BASELINE_INPUT" = "-" ] && [ "$FRESH" = "-" ]; then
  die_usage "only one of <baseline.json> / --fresh may be stdin (\"-\") at a time"
fi

# ---------------------------------------------------------------------------
# Repo anchoring & output pre-flight — before any real work, same fail-fast contract as every
# sibling script.
# ---------------------------------------------------------------------------

REPO_ROOT=$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel 2>/dev/null || true)
[ -n "$REPO_ROOT" ] || REPO_ROOT="$(pwd -P)"

if [ -z "$DISCOVER_BIN" ]; then
  DISCOVER_BIN="$SCRIPT_DIR/discover-subsystems.sh"
fi
if [ -z "$FRESH" ]; then
  if [ ! -x "$DISCOVER_BIN" ]; then
    echo "Error: discover-subsystems.sh not found or not executable: $DISCOVER_BIN" >&2
    echo "       Pass --fresh to supply an already-computed report instead." >&2
    exit 2
  fi
fi

if [ -n "$JSON_OUT" ]; then
  JSON_OUT_DIR=$(dirname -- "$JSON_OUT")
  [ -d "$JSON_OUT_DIR" ] || { echo "Error: --json-out directory does not exist: $JSON_OUT_DIR" >&2; exit 4; }
  [ -w "$JSON_OUT_DIR" ] || { echo "Error: --json-out directory is not writable: $JSON_OUT_DIR" >&2; exit 4; }
  JSON_OUT=$(cd -- "$JSON_OUT_DIR" && pwd -P)/$(basename -- "$JSON_OUT")
fi

# ---------------------------------------------------------------------------
# Read the baseline, obtain the fresh candidate set (running discover-subsystems.sh ourselves
# unless --fresh was given), classify, emit.
#
# Captured into a variable and run with `python3 -c`, exactly as find-scan-baseline.sh /
# write-scan-record.sh / apply-subsystem-cap.sh do: a `python3 - <<PY` heredoc would occupy
# python's stdin, and this script must itself be able to read stdin for the baseline.
# ---------------------------------------------------------------------------

PY_SRC=$(cat <<'PY'
import json
import os
import subprocess
import sys

(REPO_ROOT, BASELINE_INPUT, FRESH, ROOT_OVERRIDE, DISCOVER_BIN, JSON_OUT) = sys.argv[1:7]

notices = []
CHANGED_FILES_CAP = 50


def norm(path):
    """Same normalization as find-scan-baseline.sh's own norm(): strip a trailing slash,
    collapse "", ".", "./" to the canonical "." meaning 'the whole repository'."""
    p = (path or "").strip()
    if p in ("", ".", "./"):
        return "."
    return p.rstrip("/")


def full_path(root, cand_path):
    root = norm(root)
    cand_path = norm(cand_path)
    if root == ".":
        return cand_path
    if cand_path == ".":
        return root
    return root + "/" + cand_path


# --- read a JSON document from a file path or "-" (stdin) -------------------------------------

def read_json(source, label):
    try:
        if source == "-":
            raw = sys.stdin.read()
            origin = "stdin"
        else:
            with open(source, "r", encoding="utf-8") as fh:
                raw = fh.read()
            origin = source
    except OSError as exc:
        sys.stderr.write("Error: could not read %s: %s\n" % (label, exc))
        sys.exit(2)

    if not raw.strip():
        sys.stderr.write("Error: %s is empty (%s).\n" % (label, origin))
        sys.exit(2)

    try:
        doc = json.loads(raw)
    except ValueError as exc:
        sys.stderr.write("Error: %s is not valid JSON (%s): %s\n" % (label, origin, exc))
        sys.exit(2)

    if not isinstance(doc, dict):
        sys.stderr.write("Error: %s did not contain a JSON object (%s).\n" % (label, origin))
        sys.exit(2)

    return doc


# --- baseline -----------------------------------------------------------------------------------

baseline = read_json(BASELINE_INPUT, "baseline input")

source = baseline.get("source")
if source not in ("scan-record", "inferred"):
    sys.stderr.write(
        "Error: baseline input is not a recognised find-scan-baseline.sh shape "
        "(expected \"source\": \"scan-record\" or \"inferred\", got %r).\n" % (source,)
    )
    sys.exit(2)

root = norm(baseline.get("root", "."))
baseline_commit = baseline.get("baseline_commit")

if source == "scan-record":
    baseline_candidates = baseline.get("candidates")
    if not isinstance(baseline_candidates, list):
        sys.stderr.write(
            "Error: Tier 1 (\"source\": \"scan-record\") baseline is missing its "
            "\"candidates\" array.\n"
        )
        sys.exit(2)
else:
    # Tier 2 ("inferred"): no candidates[] by design -- new/removed are never computed for it.
    baseline_candidates = None
    notices.append(
        "Tier 2 (\"inferred\") baseline has no candidates[] -- \"new\" and \"removed\" cannot "
        "be computed and are reported as empty arrays; every fresh candidate is classified "
        "unchanged/changed only."
    )

baseline_by_path = {}
if baseline_candidates is not None:
    for entry in baseline_candidates:
        if not isinstance(entry, dict) or "path" not in entry:
            notices.append("skipped a baseline candidate entry with no \"path\": %r" % (entry,))
            continue
        baseline_by_path[norm(entry["path"])] = entry

# --- fresh candidate set --------------------------------------------------------------------

if FRESH:
    fresh_report = read_json(FRESH, "--fresh input")
else:
    target_root = ROOT_OVERRIDE if ROOT_OVERRIDE else root
    if norm(target_root) == ".":
        discover_target = REPO_ROOT
    else:
        discover_target = os.path.join(REPO_ROOT, norm(target_root))
    try:
        proc = subprocess.run(
            [DISCOVER_BIN, discover_target],
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, universal_newlines=True,
        )
    except OSError as exc:
        sys.stderr.write("Error: could not run discover-subsystems.sh: %s\n" % exc)
        sys.exit(2)
    if proc.returncode != 0:
        sys.stderr.write(
            "Error: discover-subsystems.sh exited %d for %r:\n%s\n"
            % (proc.returncode, discover_target, proc.stderr)
        )
        sys.exit(2)
    if proc.stderr:
        for line in proc.stderr.splitlines():
            notices.append("discover-subsystems.sh: %s" % line)
    try:
        fresh_report = json.loads(proc.stdout)
    except ValueError as exc:
        sys.stderr.write(
            "Error: discover-subsystems.sh produced unparseable JSON for %r: %s\n"
            % (discover_target, exc)
        )
        sys.exit(2)
    if not isinstance(fresh_report, dict):
        sys.stderr.write(
            "Error: discover-subsystems.sh did not produce a JSON object for %r.\n"
            % (discover_target,)
        )
        sys.exit(2)

fresh_candidates = fresh_report.get("candidates")
if not isinstance(fresh_candidates, list):
    sys.stderr.write(
        "Error: fresh discovery report is missing its \"candidates\" array "
        "(not a discover-subsystems.sh report).\n"
    )
    sys.exit(2)

fresh_by_path = {}
for entry in fresh_candidates:
    if not isinstance(entry, dict) or "path" not in entry:
        notices.append("skipped a fresh candidate entry with no \"path\": %r" % (entry,))
        continue
    fresh_by_path[norm(entry["path"])] = entry

# --- resolve baseline_commit once, up front ------------------------------------------------

no_commit_available = False
if baseline_commit is None:
    no_commit_available = True
    notices.append(
        "baseline_commit is null (the engine repo had no commits at scan time, per "
        "write-scan-record.sh's own documented null case) -- git diff cannot be computed; "
        "every matched/fresh candidate is conservatively classified \"changed\"."
    )
else:
    check = subprocess.run(
        ["git", "-C", REPO_ROOT, "cat-file", "-e", "%s^{commit}" % baseline_commit],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
    )
    if check.returncode != 0:
        sys.stderr.write(
            "Error: baseline_commit %r does not resolve to a commit in this repository's "
            "history (rebased/squashed away since the baseline was captured?).\n" % (baseline_commit,)
        )
        sys.exit(2)


def git_diff_touched(path):
    """Returns the (possibly empty) list of repo-relative files git reports touched under
    `path` since baseline_commit..HEAD. Only called when a real baseline_commit is available."""
    proc = subprocess.run(
        ["git", "-C", REPO_ROOT, "diff", "--name-only", "%s..HEAD" % baseline_commit, "--", path],
        stdout=subprocess.PIPE, stderr=subprocess.PIPE, universal_newlines=True,
    )
    if proc.returncode != 0:
        notices.append(
            "git diff failed for path %r (%s); conservatively classified \"changed\"" % (path, proc.stderr.strip())
        )
        return None  # signals "treat as changed, could not verify"
    return [line.strip() for line in proc.stdout.splitlines() if line.strip()]


def classify(cand_path, source_entry):
    """Returns (bucket, changed_files_or_None) for a matched (present in both, or Tier-2-only)
    candidate path."""
    if no_commit_available:
        return "changed", None
    path = full_path(root, cand_path)
    touched = git_diff_touched(path)
    if touched is None:
        return "changed", None
    if touched:
        return "changed", touched[:CHANGED_FILES_CAP]
    return "unchanged", None


unchanged = []
changed = []
new = []
removed = []

if baseline_candidates is not None:
    # Tier 1: full unchanged/changed/new/removed classification.
    all_paths = sorted(set(baseline_by_path) | set(fresh_by_path))
    for p in all_paths:
        in_baseline = p in baseline_by_path
        in_fresh = p in fresh_by_path
        if in_baseline and in_fresh:
            entry = dict(fresh_by_path[p])
            bucket, touched = classify(p, entry)
            if bucket == "unchanged":
                unchanged.append({"path": p, "files": entry.get("files"), "lines": entry.get("lines")})
            else:
                out = {"path": p, "files": entry.get("files"), "lines": entry.get("lines")}
                out["changed_files"] = touched if touched is not None else []
                changed.append(out)
        elif in_fresh:
            entry = fresh_by_path[p]
            new.append({"path": p, "files": entry.get("files"), "lines": entry.get("lines")})
        else:
            entry = baseline_by_path[p]
            removed.append({"path": p, "files": entry.get("files"), "lines": entry.get("lines")})
else:
    # Tier 2: only unchanged/changed, over the fresh candidate set.
    for p in sorted(fresh_by_path):
        entry = fresh_by_path[p]
        bucket, touched = classify(p, entry)
        if bucket == "unchanged":
            unchanged.append({"path": p, "files": entry.get("files"), "lines": entry.get("lines")})
        else:
            out = {"path": p, "files": entry.get("files"), "lines": entry.get("lines")}
            out["changed_files"] = touched if touched is not None else []
            changed.append(out)

result = {
    "script": "diff-since-baseline.sh",
    "version": 1,
    "root": root,
    "baseline_source": source,
    "baseline_commit": baseline_commit,
    "unchanged": unchanged,
    "changed": changed,
    "new": new,
    "removed": removed,
    "unchanged_count": len(unchanged),
    "changed_count": len(changed),
    "new_count": len(new),
    "removed_count": len(removed),
    "notices": notices,
}

body = json.dumps(result, ensure_ascii=False)

if JSON_OUT:
    try:
        with open(JSON_OUT, "w", encoding="utf-8") as fh:
            fh.write(json.dumps(result, indent=2, ensure_ascii=False) + "\n")
    except OSError as exc:
        sys.stderr.write("Error: could not write --json-out file: %s\n" % exc)
        sys.exit(4)

for n in notices:
    sys.stderr.write("Notice: %s\n" % n)

print(body)
PY
)

python3 -c "$PY_SRC" "$REPO_ROOT" "$BASELINE_INPUT" "$FRESH" "$ROOT_OVERRIDE" "$DISCOVER_BIN" "$JSON_OUT"
