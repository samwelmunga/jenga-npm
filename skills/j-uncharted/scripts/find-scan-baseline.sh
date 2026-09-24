#!/usr/bin/env bash
# find-scan-baseline.sh — locate the baseline `refresh` mode should diff against
#
# Usage: find-scan-baseline.sh [options] <root>
#        find-scan-baseline.sh --help
#
# `refresh` mode (E40_S07_T04, not yet implemented) needs SOMETHING to diff the current codebase
# against. This script is the "find that something" step, and only that step — it does not diff
# (E40_S07_T03, a separate not-yet-started script) and does not decide what `refresh` does with
# the result (that belongs in skills/j-uncharted/SKILL.md's refresh mode section, E40_S07_T04).
# It is read-only: it never writes to the analysed codebase or the board.
#
# Baseline is located in this order, most precise first:
#
#   1. SCAN-RECORD.  The most recent scan-record written by write-scan-record.sh (E40_S07_T01)
#      under project/rapports/analysis/ whose own `root` field matches the requested root. If
#      found, its `baseline_commit`, `scanned_at`, and `candidates` are emitted directly, tagged
#      `source: "scan-record"` (precise — it recorded exactly what a real scan found).
#
#   2. BOARD-EVIDENCE INFERENCE.  Only tried when no scan-record exists (e.g. `onboard` ran
#      before `refresh` mode existed, so no scan-record was ever written). Board items are
#      searched for two independent signals: an epic-level `provenance: backfilled` frontmatter
#      field, or a `[ARCH]` title-prefix tag at any level (epic/story/task) — see
#      templates/SCRUM_BOARD_SCHEMA.md's "provenance" and "[ARCH]" sections. A qualifying item
#      whose `docs:` frontmatter list overlaps the requested root is evidence that the item
#      describes (part of) that root. For each such item, the commit that FIRST added that
#      board file to git history (`git log --follow --diff-filter=A --format=%h -- <file> |
#      tail -1`) is an approximate stand-in for "when this part of the codebase was first
#      understood" — the EARLIEST such commit across all matches is taken as the inferred
#      baseline, tagged `source: "inferred"` (approximate — it is a proxy, not a real scan).
#
#   3. NO BASELINE.  Neither a scan-record nor board evidence exists for the requested root.
#      Exits 3 (see EXIT CODES) so the caller knows to fall back to running a full `onboard`
#      instead of attempting a `refresh`.
#
# ---------------------------------------------------------------------------
# INPUT
# ---------------------------------------------------------------------------
# <root>   Required. The repo-relative root `refresh` is being asked to investigate (e.g.
#          "skills/j-uncharted", or "." for the whole repo). Matched against scan-records'
#          `root` field and against board items' `docs:` entries — both are treated as
#          repo-relative paths, normalized by stripping a trailing slash and collapsing
#          "", ".", "./" to a single canonical "." meaning "the whole repository".
#
# ---------------------------------------------------------------------------
# OPTIONS
# ---------------------------------------------------------------------------
#   --analysis-dir DIR   Where scan-records are looked for (Tier 1). Default:
#                        <repo-root>/project/rapports/analysis — the same directory
#                        write-scan-record.sh writes to.
#   --board-dir DIR      Where board items are looked for (Tier 2). Default:
#                        <repo-root>/project/board — expects epics/, stories/, tasks/
#                        subdirectories underneath, matching the real board layout.
#   --json-out FILE      Also write the same JSON this script prints on stdout to this exact
#                        path. Not written unless requested. Pre-flighted before any real work,
#                        same fail-fast contract as write-scan-record.sh / run-engine.sh.
#   -h, --help           Show this help and exit 0.
#
# ---------------------------------------------------------------------------
# OUTPUT
# ---------------------------------------------------------------------------
# stdout : on success (Tier 1 or Tier 2), a single JSON object, one line, nothing else — so
#          `RESULT=$(find-scan-baseline.sh ...)` is safe. Shape:
#
#          Tier 1 (source: "scan-record"):
#          {
#            "source": "scan-record",
#            "root": "<repo-relative root>",
#            "baseline_commit": "<short SHA>" | null,
#            "scanned_at": "<ISO 8601 UTC timestamp>",
#            "candidates": [ { "path": "...", "files": <int>, "lines": <int> }, ... ],
#            "candidate_count": <int>,
#            "record_path": "<absolute path of the scan-record used>",
#            "notices": [ ... ]
#          }
#
#          Tier 2 (source: "inferred"):
#          {
#            "source": "inferred",
#            "root": "<repo-relative root>",
#            "baseline_commit": "<short SHA>",
#            "inferred_from": [
#              { "id": "<board item id>", "level": "epic"|"story"|"task",
#                "file": "<repo-relative board file path>", "commit": "<short SHA>" }, ...
#            ],
#            "notices": [ ... ]
#          }
#
#          On Tier 3 (no baseline) or any error, stdout is EMPTY — nothing is printed there.
#
# stderr : notices and diagnostics only, never document/record content. On Tier 3 or an error,
#          a clear explanation of what was (and wasn't) found is written here.
#
# ---------------------------------------------------------------------------
# EXIT CODES
# ---------------------------------------------------------------------------
#   0 — success; a baseline was located (Tier 1 or Tier 2) and printed as JSON on stdout
#   1 — usage error: unknown flag, missing value, missing or duplicate <root> argument
#   2 — environment error: --board-dir does not exist or is not readable. (An unreadable or
#       missing --analysis-dir is NOT an error — it just means Tier 1 has nothing to find, which
#       is a normal, expected state handled by falling through to Tier 2.)
#   3 — NO BASELINE FOUND: neither a scan-record nor board evidence exists for <root>. The
#       caller should fall back to running a full `onboard` (and its own first scan-record
#       write) rather than attempting a `refresh`. This is a distinct code from every sibling
#       script's 0/1/2/4 range specifically so callers can branch on it without string-matching
#       stderr.
#   4 — write failure: --json-out's directory could not be found or is not writable.
#
# Examples:
#   find-scan-baseline.sh skills/j-uncharted
#   find-scan-baseline.sh --board-dir /tmp/scratch-board .
#   RESULT=$(find-scan-baseline.sh skills/j-uncharted) || {
#     rc=$?
#     [ "$rc" -eq 3 ] && echo "no baseline -- falling back to onboard"
#   }
#
# Requires: bash, git, python3. jq is NOT required — JSON is parsed and emitted by python3.

set -euo pipefail

ANALYSIS_DIR=""
BOARD_DIR=""
JSON_OUT=""
ROOT=""

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)

usage() {
  cat <<EOF
Usage: $(basename "$0") [options] <root>

Locate the baseline /uncharted refresh should diff against for <root> (a repo-relative path):
prefer the most recent matching scan-record under project/rapports/analysis/ (source:
"scan-record"); if none exists, infer an approximate baseline commit from provenance:backfilled
epics or [ARCH]-tagged board items whose docs: overlaps <root> (source: "inferred"); if neither
exists, exit 3 so the caller falls back to a full onboard.

Arguments:
  <root>    Repo-relative root to find a baseline for (e.g. "skills/j-uncharted", or "." for the
            whole repo). Required.

Options:
  --analysis-dir DIR   Directory to search for scan-records (default: <repo-root>/project/rapports/analysis)
  --board-dir DIR      Directory containing epics/, stories/, tasks/ (default: <repo-root>/project/board)
  --json-out FILE      Also write the result JSON to this exact path
  -h, --help           Show this help and exit

Exit codes: 0 success, 1 usage error, 2 environment error, 3 no baseline found, 4 write failure.
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
    --analysis-dir)    require_value "--analysis-dir" "$#";  ANALYSIS_DIR="$2"; shift 2 ;;
    --analysis-dir=*)  ANALYSIS_DIR="${1#*=}"; shift ;;
    --board-dir)       require_value "--board-dir" "$#";     BOARD_DIR="$2"; shift 2 ;;
    --board-dir=*)     BOARD_DIR="${1#*=}"; shift ;;
    --json-out)        require_value "--json-out" "$#";      JSON_OUT="$2"; shift 2 ;;
    --json-out=*)      JSON_OUT="${1#*=}"; shift ;;
    -h|--help)         usage; exit 0 ;;
    --)
      shift
      [ "$#" -le 1 ] || die_usage "at most one <root> argument is accepted"
      [ "$#" -eq 0 ] || ROOT="$1"
      break ;;
    -*)
      die_usage "unknown option \"$1\"" ;;
    *)
      [ -z "$ROOT" ] || die_usage "at most one <root> argument is accepted (got \"$ROOT\" and \"$1\")"
      ROOT="$1"; shift ;;
  esac
done

[ -n "$ROOT" ] || die_usage "missing required <root> argument"

# ---------------------------------------------------------------------------
# Directory resolution — anchored on THIS SCRIPT, not on the requested root, same convention
# write-scan-record.sh uses: the engine repo owns this lookup even when the analysed root lives
# elsewhere.
# ---------------------------------------------------------------------------

REPO_ROOT=$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel 2>/dev/null || true)
[ -n "$REPO_ROOT" ] || REPO_ROOT="$(pwd -P)"

[ -n "$ANALYSIS_DIR" ] || ANALYSIS_DIR="$REPO_ROOT/project/rapports/analysis"
[ -n "$BOARD_DIR" ] || BOARD_DIR="$REPO_ROOT/project/board"

# A missing/unreadable analysis dir is NOT an error -- Tier 1 simply finds nothing and Tier 2
# runs. Normalize it if it exists; leave it as-is (the python side treats a non-existent dir as
# "no scan-records") if it doesn't.
if [ -d "$ANALYSIS_DIR" ]; then
  ANALYSIS_DIR=$(cd -- "$ANALYSIS_DIR" && pwd -P)
fi

# A missing/unreadable board dir IS an environment error -- Tier 2 cannot run at all without it,
# and silently treating it as "no board evidence" would make a caller misdiagnose a broken
# --board-dir as a genuine Tier 3 "no baseline" result.
if [ ! -d "$BOARD_DIR" ] || [ ! -r "$BOARD_DIR" ]; then
  echo "Error: --board-dir does not exist or is not readable: $BOARD_DIR" >&2
  exit 2
fi
BOARD_DIR=$(cd -- "$BOARD_DIR" && pwd -P)

if [ -n "$JSON_OUT" ]; then
  JSON_OUT_DIR=$(dirname -- "$JSON_OUT")
  [ -d "$JSON_OUT_DIR" ] || { echo "Error: --json-out directory does not exist: $JSON_OUT_DIR" >&2; exit 4; }
  [ -w "$JSON_OUT_DIR" ] || { echo "Error: --json-out directory is not writable: $JSON_OUT_DIR" >&2; exit 4; }
  JSON_OUT=$(cd -- "$JSON_OUT_DIR" && pwd -P)/$(basename -- "$JSON_OUT")
fi

# ---------------------------------------------------------------------------
# Do the work in python3, exactly as write-scan-record.sh / resolve-reconcile-scope.sh /
# detect-unlinked-code.sh do: captured into a variable and run with `python3 -c` (never a
# `python3 - <<PY` heredoc, which would occupy this script's own stdin).
# ---------------------------------------------------------------------------

PY_SRC=$(cat <<'PY'
import glob
import json
import os
import re
import subprocess
import sys

(REPO_ROOT, ANALYSIS_DIR, BOARD_DIR, ROOT_ARG, JSON_OUT) = sys.argv[1:6]

notices = []


def norm(path):
    """Normalize a repo-relative path for comparison: strip trailing slash, collapse
    "", ".", "./" to the canonical "." meaning 'the whole repository'."""
    p = (path or "").strip()
    if p in ("", ".", "./"):
        return "."
    return p.rstrip("/")


ROOT = norm(ROOT_ARG)

# ===================================================================================
# TIER 1 -- scan-record lookup
# ===================================================================================

def tier1_scan_record():
    if not os.path.isdir(ANALYSIS_DIR):
        return None

    pattern = os.path.join(ANALYSIS_DIR, "uncharted-scan-record-*.scan-record.json")
    matches = []
    for path in sorted(glob.glob(pattern)):
        try:
            with open(path, "r", encoding="utf-8") as fh:
                record = json.load(fh)
        except (OSError, ValueError) as exc:
            notices.append("skipped unreadable/malformed scan-record %s: %s" % (path, exc))
            continue
        if not isinstance(record, dict):
            continue
        if norm(record.get("root", "")) != ROOT:
            continue
        matches.append((path, record))

    if not matches:
        return None

    # Most recent by scanned_at (ISO 8601 UTC strings sort correctly as plain strings); ties
    # broken by filename (which itself embeds a timestamp), descending.
    matches.sort(key=lambda pr: (pr[1].get("scanned_at") or "", pr[0]), reverse=True)
    path, record = matches[0]

    return {
        "source": "scan-record",
        "root": ROOT,
        "baseline_commit": record.get("baseline_commit"),
        "scanned_at": record.get("scanned_at"),
        "candidates": record.get("candidates", []),
        "candidate_count": record.get("candidate_count", len(record.get("candidates", []))),
        "record_path": path,
        "notices": notices,
    }


# ===================================================================================
# TIER 2 -- board-evidence inference
# ===================================================================================

FRONTMATTER_RE = re.compile(r"^---\n(.*?)\n---\n", re.DOTALL)
FIELD_RE = re.compile(r"^([A-Za-z_][A-Za-z0-9_]*):\s*(.*)$")
LIST_ITEM_RE = re.compile(r"^\s*-\s*(.+)$")


def strip_quotes(val):
    val = val.strip()
    if len(val) >= 2 and val[0] == val[-1] and val[0] in ("'", '"'):
        val = val[1:-1]
    return val.strip()


def split_inline_list(inner):
    items = []
    for raw in inner.split(","):
        val = strip_quotes(raw)
        if val:
            items.append(val)
    return items


def parse_frontmatter(text):
    """Hand-rolled frontmatter parser (matching this repo's existing convention in
    resolve-reconcile-scope.sh), extended to handle BOTH YAML list styles
    templates/SCRUM_BOARD_SCHEMA.md documents as valid for `docs:` -- inline
    (docs: ["a", "b"]) and expanded (docs:\\n  - a\\n  - b) -- since real board files use
    both (e.g. E20_S08_T01 uses the expanded style)."""
    m = FRONTMATTER_RE.match(text)
    if not m:
        return {}
    lines = m.group(1).splitlines()
    fields = {}
    i = 0
    while i < len(lines):
        fm = FIELD_RE.match(lines[i])
        if not fm:
            i += 1
            continue
        key, rest = fm.group(1), fm.group(2).strip()
        if key == "docs":
            if rest.startswith("["):
                inline = rest
                j = i
                while "]" not in inline and j + 1 < len(lines):
                    j += 1
                    inline += lines[j]
                if "]" in inline:
                    inner = inline[inline.index("[") + 1:inline.rindex("]")]
                    fields["docs"] = split_inline_list(inner)
                else:
                    fields["docs"] = []
                i = j + 1
                continue
            elif rest == "":
                items = []
                j = i + 1
                while j < len(lines):
                    lm = LIST_ITEM_RE.match(lines[j])
                    if not lm:
                        break
                    items.append(strip_quotes(lm.group(1)))
                    j += 1
                fields["docs"] = items
                i = j
                continue
            else:
                fields["docs"] = [strip_quotes(rest)] if rest else []
                i += 1
                continue
        else:
            fields[key] = strip_quotes(rest) if rest else rest
            i += 1
    fields.setdefault("docs", [])
    return fields


def overlaps(root, docs_list):
    if root == ".":
        return True
    for d in docs_list:
        dn = norm(d)
        if dn == ".":
            return True
        if dn == root or dn.startswith(root + "/") or root.startswith(dn + "/"):
            return True
    return False


def qualifies(level, fields):
    if level == "epic" and fields.get("provenance") == "backfilled":
        return True
    title = fields.get("title", "")
    if title.startswith("[ARCH]"):
        return True
    return False


def collect_matches():
    matches = []
    for level, subdir in (("epic", "epics"), ("story", "stories"), ("task", "tasks")):
        dir_path = os.path.join(BOARD_DIR, subdir)
        if not os.path.isdir(dir_path):
            continue
        for path in sorted(glob.glob(os.path.join(dir_path, "*.md"))):
            try:
                with open(path, "r", encoding="utf-8", errors="replace") as fh:
                    text = fh.read()
            except OSError as exc:
                notices.append("skipped unreadable board file %s: %s" % (path, exc))
                continue
            fields = parse_frontmatter(text)
            if not fields:
                continue
            if not qualifies(level, fields):
                continue
            if not overlaps(ROOT, fields.get("docs", [])):
                continue
            matches.append({
                "id": fields.get("id", os.path.basename(path)),
                "level": level,
                "file": path,
            })
    return matches


def first_added_commit(repo_root, board_file_abs):
    rel = os.path.relpath(board_file_abs, repo_root)
    try:
        proc = subprocess.run(
            ["git", "-C", repo_root, "log", "--follow", "--diff-filter=A",
             "--format=%h", "--", rel],
            stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, universal_newlines=True,
        )
    except OSError as exc:
        notices.append("git log failed for %s: %s" % (rel, exc))
        return None
    if proc.returncode != 0:
        notices.append("git log exited %d for %s" % (proc.returncode, rel))
        return None
    shas = [line.strip() for line in proc.stdout.splitlines() if line.strip()]
    if not shas:
        notices.append("no commit history found for %s (uncommitted?)" % rel)
        return None
    return shas[-1]


def commit_timestamp(repo_root, sha):
    try:
        proc = subprocess.run(
            ["git", "-C", repo_root, "show", "-s", "--format=%ct", sha],
            stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, universal_newlines=True,
        )
    except OSError as exc:
        notices.append("git show failed for %s: %s" % (sha, exc))
        return None
    if proc.returncode != 0 or not proc.stdout.strip():
        notices.append("could not resolve a timestamp for commit %s" % sha)
        return None
    try:
        return int(proc.stdout.strip())
    except ValueError:
        return None


def tier2_inferred():
    matches = collect_matches()
    if not matches:
        return None

    resolved = []
    for match in matches:
        sha = first_added_commit(REPO_ROOT, match["file"])
        if not sha:
            continue
        ts = commit_timestamp(REPO_ROOT, sha)
        if ts is None:
            continue
        resolved.append({
            "id": match["id"],
            "level": match["level"],
            "file": os.path.relpath(match["file"], REPO_ROOT),
            "commit": sha,
            "_ts": ts,
        })

    if not resolved:
        notices.append(
            "%d qualifying board item(s) overlapped root %r but none resolved a commit"
            % (len(matches), ROOT)
        )
        return None

    resolved.sort(key=lambda r: (r["_ts"], r["id"]))
    earliest = resolved[0]

    for r in resolved:
        del r["_ts"]

    return {
        "source": "inferred",
        "root": ROOT,
        "baseline_commit": earliest["commit"],
        "inferred_from": resolved,
        "notices": notices,
    }


# ===================================================================================
# Run tiers in order, emit result
# ===================================================================================

result = tier1_scan_record()
if result is None:
    result = tier2_inferred()

if result is None:
    notices.append(
        "no scan-record and no provenance:backfilled/[ARCH] board evidence found for root %r "
        "-- caller should fall back to a full onboard" % ROOT
    )
    for n in notices:
        sys.stderr.write("Notice: %s\n" % n)
    sys.exit(3)

body = json.dumps(result, ensure_ascii=False)

if JSON_OUT:
    try:
        with open(JSON_OUT, "w", encoding="utf-8") as fh:
            fh.write(json.dumps(result, indent=2, ensure_ascii=False) + "\n")
    except OSError as exc:
        sys.stderr.write("Error: could not write --json-out file: %s\n" % exc)
        sys.exit(4)

for n in result.get("notices", []):
    sys.stderr.write("Notice: %s\n" % n)

print(body)
PY
)

python3 -c "$PY_SRC" "$REPO_ROOT" "$ANALYSIS_DIR" "$BOARD_DIR" "$ROOT" "$JSON_OUT"
