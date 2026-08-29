#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# skills/reconcile/scripts/detect-unlinked-code.sh
#
# The inverse half of `/reconcile`. The normal pass asks "does this board item
# exist in the code?"; this asks "does this code exist on the board?" and finds
# paths with NO Jenga provenance of any kind.
#
# A tracked path is UNLINKED when BOTH provenance signals are absent:
#
#   Signal A  board linkage  -- no file under `project/board/` references it,
#                              and no board file references the directory it
#                              lives in
#   Signal B  commit tag     -- no commit naming a board item added it
#
# Either signal alone is provenance. `lib/inject-settings.js` has no board file
# naming it but WAS added by a `task(...)` commit, so it is linked, not unlinked.
#
# Signal B accepts three subject forms. The first is the current EST convention;
# the other two exist because this repo's own history predates it, and a commit
# that plainly names the board item it implements is provenance regardless of
# the punctuation around it:
#
#   est_tag       epic(...) / story(...) / task(E##_S##_T##)
#   id_prefix     E04_S01: Implement core /convert skill
#   conventional  feat(train): implement E01_S05 - results parsers
#
# Crediting too narrowly is the expensive mistake: it makes /reconcile offer to
# re-onboard code the board demonstrably already owns.
#
# It scans, it classifies, it reports. It NEVER writes anything, never touches
# the board, and never invokes `/uncharted`. Deciding which groups are worth
# investigating and presenting the offer is agent judgement and lives in
# `skills/reconcile/SKILL.md`.
#
# ---------------------------------------------------------------------------
# SIGNAL A IS BORROWED, NOT REBUILT
# ---------------------------------------------------------------------------
# The board-linkage question is answered by
# `skills/uncharted/scripts/resolve-segment-target.sh` (E40_S02_T01) through its
# documented batch interface:
#
#     git ls-files | resolve-segment-target.sh --paths-from -
#
# That interface exists FOR this caller. The board is read and inverted into a
# prefix index once, then each path costs a dict lookup, so the whole repo is
# classified in well under a second. We read `.results[].board_linkage.status`
# and never re-derive it.
#
# If the resolver is missing, this script FAILS (exit 4). It does not fall back
# to a local copy of the check. A second, quietly divergent answer to "is this
# path on the board" is the exact outcome this design is meant to prevent.
#
# ---------------------------------------------------------------------------
# `not_checked` IS A THIRD STATE, NOT A SYNONYM FOR `unlinked`
# ---------------------------------------------------------------------------
# The resolver reports three linkage states, and the third one is load-bearing:
#
#   linked       >=1 board file references the path
#   unlinked     the board was read and nothing references it
#   not_checked  the question could not be answered here -- the target is
#                outside this repository, is the repo root, no `project/board/`
#                exists, or the path is a stale index entry that no longer
#                exists on disk
#
# `not_checked` means "we could not check", NOT "nothing references it". A path
# in that state is reported in its own `not_checked[]` array with the resolver's
# reason verbatim. It is never placed in a directory group, never counted as
# unlinked, and never included in the `/uncharted segment` offer.
#
# This is deliberate. `run-engine.sh` currently renders the out-of-repo
# `not_checked` case as `unlinked` in its understanding document, which asserts
# a verified absence that was never verified. `skills/uncharted/SKILL.md` names
# Step 1 (`resolve-segment-target.sh`) authoritative on linkage where the two
# disagree, so this script passes the resolver's status through unchanged and
# does not repeat that conflation.
#
# ---------------------------------------------------------------------------
# GROUPING -- FILES ARE CLASSIFIED, DIRECTORIES ARE ONLY REPORTED
# ---------------------------------------------------------------------------
# A flat list of a hundred files is not actionable; the useful unit for
# `/uncharted segment` is a directory or feature. But grouping must not be done
# by testing directory paths. Board matching is prefix-based, so nearly every
# top-level directory reports `linked` on the strength of one board mention
# while specific files inside it are `unlinked` -- `mcp/` is linked while
# `mcp/training_runner/` is not. Testing directories and reporting the survivors
# would report zero unlinked code in a repo that demonstrably has some.
#
# So: only FILES are classified. Groups are then derived from the results.
#
# Rollup. Every directory gets subtree totals. A directory is `fully_unlinked`
# when every candidate beneath it is unlinked; each unlinked file is keyed to
# its SHALLOWEST fully-unlinked ancestor, falling back to its immediate parent.
# That collapses a wholly-uncharted subtree into the one directory worth naming
# instead of one group per leaf folder.
#
# A `not_checked` file inside a subtree blocks that subtree from being
# `fully_unlinked` -- we will not claim a whole directory is uncharted while
# part of it was never checked.
#
# ---------------------------------------------------------------------------
# THE GROUP DIRECTORY IS CHECKED TOO -- `covered_groups`
# ---------------------------------------------------------------------------
# Classifying files and then reporting directories would assert about a
# directory something that was only ever verified about its contents. Because
# the resolver's match is a path-boundary test, a board item naming
# `skills/convert/` links THAT DIRECTORY without linking
# `skills/convert/convert_cli.py`. Both facts are true, and the directory-level
# one is what decides whether a segment is worth investigating -- offering
# `/uncharted segment` there would duplicate a board item that already exists.
#
# So every group directory goes back through the same borrowed checker in a
# second batch call, and groups are split:
#
#   groups[]          directory is `unlinked` (or `not_checked`) -- neither the
#                     files nor the directory have provenance. These are the
#                     offer candidates.
#   covered_groups[]  directory is `linked` -- the files have no provenance of
#                     their own but sit under a directory the board references.
#                     Reported with the owning board items, never offered.
#
# `not_checked` on a DIRECTORY keeps the group rather than dropping it: under-
# reporting a finding is worse than reporting one the user can dismiss.
#
# MIRROR SPELLINGS. Per CLAUDE.md the canonical file lives in the root tree and
# `.agents/`, `.claude/` are generated build outputs -- but older board items
# were often written against the mirror path. E17_S05 owns `/reconcile-origin`
# and names it `.agents/skills/reconcile-origin/SKILL.md`, so a match on the
# root path alone misses a board item that plainly owns the directory. Each
# group directory is therefore asked about under its own name and under both
# mirror prefixes, and `directory_linkage.matched_as` records which spelling
# answered. This adds spellings to the QUESTION; it does not add a second
# answer to it.
#
# ---------------------------------------------------------------------------
# Usage
# ---------------------------------------------------------------------------
#   detect-unlinked-code.sh [options]
#
# Options:
#   --repo-root <dir>    Treat this directory as the repo root instead of asking
#                        git. Mainly for testing.
#   --board-dir <dir>    Board directory to consult.
#                        Default: <repo-root>/project/board
#   --resolver <path>    Path to resolve-segment-target.sh.
#                        Default: ../../uncharted/scripts/resolve-segment-target.sh
#   --exclude <glob>     Additional exclusion, matched against the repo-relative
#                        path with shell-glob semantics. Repeatable.
#   --limit N            Cap on files listed per group. Default 10. 0 = unlimited.
#                        Group counts are always the true totals, pre-cap.
#   -h, --help           Show this help and exit 0.
#
# ---------------------------------------------------------------------------
# Exclusions
# ---------------------------------------------------------------------------
# Removed from the candidate set before anything is classified:
#   - Jenga's own scaffolding and generated build outputs: `project/`,
#     `.claude/`, `.agents/`
#   - build outputs and vendored dependencies: `node_modules/`, `dist/`,
#     `build/`, `out/`, `target/`, `vendor/`, `.venv/`, `venv/`, `__pycache__/`,
#     `.git/`
#   - anything `.gitignore` matches. Checked explicitly with
#     `git check-ignore --no-index`, because a path that is both tracked and
#     ignored stays tracked -- listing it in `git ls-files` is not evidence that
#     the ignore rules do not cover it.
#   - anything given via `--exclude`
#
# The default prefix list is kept deliberately in step with
# CANDIDATE_EXCLUDED_PREFIXES in `resolve-segment-target.sh`.
#
# ---------------------------------------------------------------------------
# Output
# ---------------------------------------------------------------------------
# stdout: one JSON object. stderr: notices. Never mixed.
#
#   {
#     "schema": "detect-unlinked-code/2",
#     "repo_root": "/abs/path",
#     "board_dir": "/abs/path/project/board",
#     "resolver": "/abs/path/resolve-segment-target.sh",
#     "summary": { "tracked_paths": N, "excluded_paths": N,
#                  "candidate_paths": N, "linked_paths": N,
#                  "linked_by_board": N, "linked_by_commit": N,
#                  "unlinked_paths": N,      // files with neither file-level signal
#                  "uncharted_paths": N,     // of those, the ones in groups[]
#                  "covered_paths": N,       // of those, the ones in covered_groups[]
#                  "not_checked_paths": N,
#                  "groups": N, "covered_groups": N },
#     "groups": [
#       { "directory": "skills/skillify",
#         "unlinked_count": N,        // files keyed to THIS group
#         "subtree_candidates": N,    // all candidates under the directory
#         "subtree_unlinked": N,      // all unlinked under the directory
#         "fully_unlinked": true,
#         "directory_linkage": { "status": "unlinked", "reason": "...",
#                                "items": [], "match_count": 0,
#                                "matched_as": "skills/skillify" },
#         "files": ["..."],           // capped by --limit
#         "files_truncated": N }
#     ],
#     "covered_groups": [ /* same shape; directory_linkage.status == "linked" */ ],
#     "not_checked": [ { "path": "...", "reason": "..." } ],
#
# Paths are reported exactly as `git ls-files` gives them. A tracked symlink is classified by
# what it points at -- the resolver resolves the target -- but is still reported under its own
# name, so it never displaces the record of the file it points to.
#     "exclusions": { "prefixes": [...], "globs": [...], "gitignored": N },
#     "notices": [...]
#   }
#
# Both group arrays are sorted by unlinked_count descending, then by path.
# `unlinked_paths` == `uncharted_paths` + `covered_paths`.
#
# Exit codes:
#   0  the scan completed -- findings or not. Callers read
#      `summary.unlinked_paths`; finding unlinked code is a normal result, not
#      an error, and must stay safe under `set -e` inside the reconcile pass.
#   1  usage error
#   4  environment error (python3/git unavailable, repo root undeterminable,
#      resolver missing or not executable, resolver failed)
#
# Requires: bash, python3, git, and resolve-segment-target.sh. jq is NOT required.
# ---------------------------------------------------------------------------

set -euo pipefail

SELF="$(basename "$0")"
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)

die() {
  local code="$1"; shift
  printf '%s: error: %s\n' "$SELF" "$*" >&2
  exit "$code"
}

usage() {
  sed -n '/^# Usage$/,/^# Requires:/p' "$0" | sed -e 's/^# \{0,1\}//' -e '/^-\{10,\}$/d'
}

die_usage() {
  printf '%s: error: %s\n' "$SELF" "$*" >&2
  echo >&2
  usage >&2
  exit 1
}

REPO_ROOT=""
BOARD_DIR=""
RESOLVER=""
LIMIT=10
EXCLUDES=""

require_value() {
  # require_value <flag> <remaining-arg-count>
  [ "$2" -ge 2 ] || die_usage "$1 requires a value"
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --repo-root)   require_value "--repo-root" "$#"; REPO_ROOT="$2"; shift 2 ;;
    --repo-root=*) REPO_ROOT="${1#*=}"; shift ;;
    --board-dir)   require_value "--board-dir" "$#"; BOARD_DIR="$2"; shift 2 ;;
    --board-dir=*) BOARD_DIR="${1#*=}"; shift ;;
    --resolver)    require_value "--resolver" "$#";  RESOLVER="$2"; shift 2 ;;
    --resolver=*)  RESOLVER="${1#*=}"; shift ;;
    --exclude)     require_value "--exclude" "$#";   EXCLUDES="${EXCLUDES}$2"$'\n'; shift 2 ;;
    --exclude=*)   EXCLUDES="${EXCLUDES}${1#*=}"$'\n'; shift ;;
    --limit)       require_value "--limit" "$#";     LIMIT="$2"; shift 2 ;;
    --limit=*)     LIMIT="${1#*=}"; shift ;;
    -h|--help)     usage; exit 0 ;;
    *)             die_usage "unknown argument \"$1\"" ;;
  esac
done

case "$LIMIT" in
  ''|*[!0-9]*) die_usage "--limit requires a non-negative integer, got \"$LIMIT\"" ;;
esac

command -v python3 >/dev/null 2>&1 || die 4 "python3 is required but was not found on PATH"
command -v git     >/dev/null 2>&1 || die 4 "git is required but was not found on PATH"

# --- repo root ------------------------------------------------------------------------------
# Anchored on THIS SCRIPT, matching resolve-segment-target.sh and run-engine.sh: the board being
# consulted is the board of the project that owns the skill.
if [ -z "$REPO_ROOT" ]; then
  REPO_ROOT=$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel 2>/dev/null || true)
  [ -n "$REPO_ROOT" ] || REPO_ROOT="$(pwd -P)"
fi
[ -d "$REPO_ROOT" ] || die 4 "repo root is not a directory: $REPO_ROOT"
REPO_ROOT=$(cd -- "$REPO_ROOT" && pwd -P)

[ -n "$BOARD_DIR" ] || BOARD_DIR="$REPO_ROOT/project/board"

# --- the borrowed linkage check -------------------------------------------------------------
[ -n "$RESOLVER" ] || RESOLVER="$SCRIPT_DIR/../../uncharted/scripts/resolve-segment-target.sh"
[ -f "$RESOLVER" ] || die 4 "board-linkage checker not found: $RESOLVER
  This script deliberately has no fallback implementation -- see the header. Restore
  skills/uncharted/scripts/resolve-segment-target.sh or pass --resolver <path>."
[ -x "$RESOLVER" ] || die 4 "board-linkage checker is not executable: $RESOLVER"
RESOLVER=$(cd -- "$(dirname -- "$RESOLVER")" && pwd -P)/$(basename -- "$RESOLVER")

TMPDIR_RUN=$(mktemp -d "${TMPDIR:-/tmp}/detect-unlinked-code.XXXXXX")
cleanup() { rm -rf "$TMPDIR_RUN"; }
trap cleanup EXIT

TRACKED="$TMPDIR_RUN/tracked"
IGNORED="$TMPDIR_RUN/ignored"
CANDIDATES="$TMPDIR_RUN/candidates"
LINKAGE="$TMPDIR_RUN/linkage.json"
COMMITS="$TMPDIR_RUN/commits"
EXCLUDE_GLOBS="$TMPDIR_RUN/excludes"

# --- tracked paths --------------------------------------------------------------------------
git -C "$REPO_ROOT" ls-files -z > "$TRACKED" 2>/dev/null || : > "$TRACKED"

# --- gitignored paths -----------------------------------------------------------------------
# --no-index is the point: without it, git refuses to call a TRACKED path ignored, so a path
# that is both tracked and covered by .gitignore would silently survive the filter.
: > "$IGNORED"
if [ -s "$TRACKED" ]; then
  set +e
  git -C "$REPO_ROOT" check-ignore --no-index --stdin -z < "$TRACKED" > "$IGNORED" 2>/dev/null
  CI_RC=$?
  set -e
  # 0 = some paths ignored, 1 = none ignored. Anything else means check-ignore itself failed,
  # in which case an empty ignore list is the safe reading (over-report, never under-report).
  if [ "$CI_RC" -gt 1 ]; then
    printf '%s: notice: git check-ignore exited %d; proceeding with no gitignore filter\n' \
      "$SELF" "$CI_RC" >&2
    : > "$IGNORED"
  fi
fi

# --- EST-tagged commit provenance -----------------------------------------------------------
# One pass over HEAD. --no-renames is deliberate: it decomposes a rename into delete-old +
# add-new, so the ADDED entry is unambiguously the path as it exists today. With rename
# detection on, a rename is one record and crediting the right side of it becomes guesswork.
# Merge commits contribute no file list by default, which is correct: a merge does not originate
# content, and the branch commits that do are already walked.
# \x01 prefixes the subject line so the parser can tell subjects from paths unambiguously.
git -C "$REPO_ROOT" log --diff-filter=A --no-renames --name-only \
  --format='%x01%s' HEAD -- . > "$COMMITS" 2>/dev/null || : > "$COMMITS"

# --- candidate set --------------------------------------------------------------------------
printf '%s' "$EXCLUDES" > "$EXCLUDE_GLOBS"

PY_FILTER=$(cat <<'PY'
import fnmatch, os, sys

tracked_path, ignored_path, excludes_path, out_path = sys.argv[1:5]

# Kept deliberately in step with CANDIDATE_EXCLUDED_PREFIXES in resolve-segment-target.sh.
EXCLUDED_PREFIXES = (
    "project/", ".claude/", ".agents/", "node_modules/", "dist/", "build/",
    "out/", "vendor/", "target/", ".venv/", "venv/", "__pycache__/", ".git/",
)


def read_nul(path):
    try:
        with open(path, "rb") as fh:
            return [p.decode("utf-8", "replace") for p in fh.read().split(b"\0") if p]
    except OSError:
        return []


tracked = read_nul(tracked_path)
ignored = set(read_nul(ignored_path))
try:
    with open(excludes_path, encoding="utf-8") as fh:
        globs = [ln.strip() for ln in fh if ln.strip()]
except OSError:
    globs = []


def excluded(path):
    if path.startswith(EXCLUDED_PREFIXES):
        return True
    # A nested build/vendor directory counts too: `mcp/help/node_modules/x` is not source.
    for part in path.split("/")[:-1]:
        if part + "/" in EXCLUDED_PREFIXES:
            return True
    if path in ignored:
        return True
    return any(fnmatch.fnmatch(path, g) for g in globs)


candidates = [p for p in tracked if not excluded(p)]
with open(out_path, "w", encoding="utf-8") as fh:
    for p in candidates:
        fh.write(p + "\n")
sys.stdout.write("%d %d %d\n" % (len(tracked), len(candidates), len(ignored)))
PY
)

COUNTS=$(python3 -c "$PY_FILTER" "$TRACKED" "$IGNORED" "$EXCLUDE_GLOBS" "$CANDIDATES") \
  || die 4 "failed to build the candidate path set"

# --- signal A: board linkage, via the borrowed checker --------------------------------------
# Exit 2 means "at least one input path does not exist" -- a stale index entry. That is a normal
# finding here, the JSON is still complete, and the resolver reports it as not_checked. Any other
# non-zero status is a real failure.
set +e
"$RESOLVER" --paths-from "$CANDIDATES" --board-dir "$BOARD_DIR" --repo-root "$REPO_ROOT" \
  --limit 0 > "$LINKAGE"
RESOLVER_RC=$?
set -e
if [ "$RESOLVER_RC" -ne 0 ] && [ "$RESOLVER_RC" -ne 2 ]; then
  die 4 "board-linkage checker failed (exit $RESOLVER_RC): $RESOLVER"
fi
[ -s "$LINKAGE" ] || die 4 "board-linkage checker produced no output: $RESOLVER"

PY_MAIN=$(cat <<'PY'
import json
import os
import re
import subprocess
import sys

(repo_root, board_dir, resolver, linkage_path, commits_path,
 excludes_path, limit_s, counts_s) = sys.argv[1:9]
limit = int(limit_s)
tracked_n, candidate_n, ignored_n = (int(x) for x in counts_s.split())

notices = []

EXCLUDED_PREFIXES = [
    "project/", ".claude/", ".agents/", "node_modules/", "dist/", "build/",
    "out/", "vendor/", "target/", ".venv/", "venv/", "__pycache__/", ".git/",
]
try:
    with open(excludes_path, encoding="utf-8") as fh:
        globs = [ln.strip() for ln in fh if ln.strip()]
except OSError:
    globs = []

# --- signal B: EST commit tags ---------------------------------------------------------------
# Three accepted subject forms. The current EST convention is the first; the other two exist
# because this repo's own history predates it, and a commit that plainly names the board item it
# implements is provenance regardless of the punctuation around it. Crediting too narrowly is the
# expensive mistake here -- it makes /reconcile offer to re-onboard code the board already owns.
#
#   est_tag       epic(...) / story(...) / task(E##_S##_T##)
#   id_prefix     E04_S01: Implement core /convert skill
#   conventional  feat(train): implement E01_S05 - results parsers
#
# A bare `E##` is only honoured inside an EST tag or as a subject prefix; loose in a sentence it
# is as likely to be a version or a variable as a board ID.
BOARD_ID = r"E\d+(?:_S\d+(?:_T\d+)?)?"
EST_TAG_RE = re.compile(r"^(epic|story|task)\(([^)]*)\)")
ID_PREFIX_RE = re.compile(r"^(%s)\b\s*[:\-–—]" % BOARD_ID)
CONVENTIONAL_RE = re.compile(r"^\w+(?:\([^)]*\))?!?:")
QUALIFIED_ID_RE = re.compile(r"\bE\d+_S\d+(?:_T\d+)?\b")
ANY_ID_RE = re.compile(r"\b%s\b" % BOARD_ID)


def est_provenance(subject):
    """-> (board id or tag word, matched form) or None."""
    m = EST_TAG_RE.match(subject)
    if m:
        ids = ANY_ID_RE.findall(m.group(2))
        return (ids[0] if ids else m.group(1)), "est_tag"
    m = ID_PREFIX_RE.match(subject)
    if m:
        return m.group(1), "id_prefix"
    if CONVENTIONAL_RE.match(subject):
        ids = QUALIFIED_ID_RE.findall(subject)
        if ids:
            return ids[0], "conventional"
    return None


commit_provenance = {}
try:
    with open(commits_path, encoding="utf-8", errors="replace") as fh:
        raw = fh.read()
except OSError:
    raw = ""

current = None
for line in raw.split("\n"):
    if line.startswith("\x01"):
        current = est_provenance(line[1:])
        continue
    path = line.strip()
    if path and current is not None:
        # First writer wins: git log walks newest-first, so this records the most recent EST
        # commit that put the path in place, which is the one worth citing.
        commit_provenance.setdefault(path, current)

# --- signal A: read the borrowed linkage result ----------------------------------------------
try:
    with open(linkage_path, encoding="utf-8") as fh:
        linkage = json.load(fh)
except (OSError, ValueError) as exc:
    sys.stderr.write("error: could not read board-linkage output: %s\n" % exc)
    sys.exit(4)

if linkage.get("schema") != "resolve-segment-target/1":
    notices.append("board-linkage checker returned unexpected schema %r; "
                   "results may be incomplete" % linkage.get("schema"))

# --- classify --------------------------------------------------------------------------------
# Order matters. Commit provenance is checked FIRST so that a path the board check could not
# evaluate is still rescued by a real EST commit, instead of being reported as unknown.
status_of = {}
not_checked = []
linked_by_board = linked_by_commit = 0

for rec in linkage.get("results", []):
    # Key on the path we ASKED about, not the resolver's `target_relative`. The resolver
    # realpath()s its target, so a tracked symlink (e.g. this repo's now-retired
    # `AGENTS.md -> AGENT.md`, before E41_S04_T05 made AGENTS.md a real file) reports its
    # destination and would silently overwrite that destination's own record. The general
    # case (any tracked symlink) still applies even though that specific example is gone.
    path = rec.get("argument") or rec.get("target_relative")
    if not path:
        continue
    link = rec.get("board_linkage") or {}
    board_status = link.get("status", "not_checked")

    if path in commit_provenance:
        status_of[path] = "linked"
        linked_by_commit += 1
    elif board_status == "linked":
        status_of[path] = "linked"
        linked_by_board += 1
    elif board_status == "unlinked":
        status_of[path] = "unlinked"
    else:
        # THE THIRD STATE. "Could not check" is not "nothing references it". Reported on its
        # own, never grouped, never counted as unlinked, never offered to /uncharted segment.
        status_of[path] = "not_checked"
        not_checked.append({
            "path": path,
            "reason": link.get("reason") or "board linkage could not be determined",
        })

# --- subtree rollup ----------------------------------------------------------------------------
def ancestors(path):
    """Shallowest first: 'a/b/c.txt' -> ['.', 'a', 'a/b']."""
    parts = path.split("/")[:-1]
    out = ["."]
    for k in range(1, len(parts) + 1):
        out.append("/".join(parts[:k]))
    return out


sub_total = {}
sub_unlinked = {}
for path, status in status_of.items():
    for d in ancestors(path):
        sub_total[d] = sub_total.get(d, 0) + 1
        if status == "unlinked":
            sub_unlinked[d] = sub_unlinked.get(d, 0) + 1


def fully_unlinked(d):
    """Every candidate beneath d is unlinked. A single not_checked file blocks this."""
    t = sub_total.get(d, 0)
    return t > 0 and sub_unlinked.get(d, 0) == t


grouped = {}
for path, status in sorted(status_of.items()):
    if status != "unlinked":
        continue
    chain = ancestors(path)
    key = next((d for d in chain if fully_unlinked(d)), chain[-1])
    grouped.setdefault(key, []).append(path)

# --- second pass: is the GROUP DIRECTORY itself on the board? ---------------------------------
# Reporting a directory while only ever having checked the files inside it asserts an absence
# that was never verified -- the same error this script is careful to avoid for `not_checked`.
# The resolver's match is a path-boundary test, so a board item naming `skills/convert/` links
# that directory without linking `skills/convert/convert_cli.py`. Both facts are true and the
# directory-level one is the one that decides whether a segment is worth investigating.
#
# Same borrowed checker, same batch interface, one extra call. No new linkage logic -- the only
# thing added on this side is WHICH SPELLINGS of a path we ask about.
#
# MIRROR SPELLINGS. Per CLAUDE.md the canonical file lives in the root tree and `.agents/` and
# `.claude/` are generated build outputs, but plenty of older board items were written against
# the mirror path -- E17_S05 owns `/reconcile-origin` and names it as
# `.agents/skills/reconcile-origin/SKILL.md`. A boundary match on the root path alone therefore
# misses a board item that plainly owns the directory. So each directory is asked about under its
# own name and under both mirror prefixes, and a hit on any spelling is board provenance. This
# adds path spellings to the QUESTION; it does not add a second answer to it.
MIRROR_PREFIXES = (".agents/", ".claude/")


def spellings(directory):
    if directory == "." or directory.startswith(MIRROR_PREFIXES):
        return [directory]
    return [directory] + [pre + directory for pre in MIRROR_PREFIXES]


def resolve_directories(dirs):
    if not dirs:
        return {}
    queries = []
    for d in dirs:
        queries.extend(spellings(d))
    cmd = [resolver, "--paths-from", "-", "--board-dir", board_dir,
           "--repo-root", repo_root, "--limit", "0"]
    try:
        proc = subprocess.run(cmd, input="\n".join(queries) + "\n", stdout=subprocess.PIPE,
                              stderr=subprocess.DEVNULL, universal_newlines=True)
    except OSError as exc:
        notices.append("directory linkage check could not run (%s); every group is reported "
                       "with an unverified directory" % exc)
        return {}
    # Exit 2 means some input path did not exist -- normal, and the JSON is still complete.
    if proc.returncode not in (0, 2):
        notices.append("directory linkage check failed (exit %d); every group is reported with "
                       "an unverified directory" % proc.returncode)
        return {}
    try:
        payload = json.loads(proc.stdout)
    except ValueError:
        notices.append("directory linkage check returned unreadable output; every group is "
                       "reported with an unverified directory")
        return {}
    by_query = {r.get("argument"): (r.get("board_linkage") or {}) for r in payload.get("results", [])}

    out = {}
    for d in dirs:
        chosen = None
        for spelling in spellings(d):
            link = by_query.get(spelling)
            if not link:
                continue
            if link.get("status") == "linked":
                chosen = dict(link, matched_as=spelling)
                break
            # Keep the root spelling's own verdict as the fallback, so a `not_checked` or
            # `unlinked` answer is still the one reported when no spelling is linked.
            if chosen is None:
                chosen = dict(link, matched_as=spelling)
        if chosen is not None:
            out[d] = chosen
    return out


dir_linkage = resolve_directories(sorted(grouped))

UNVERIFIED = {
    "status": "not_checked",
    "reason": "directory linkage was not verified",
    "items": [], "files": [], "match_count": 0,
}


def build_group(directory, files):
    link = dir_linkage.get(directory) or dict(UNVERIFIED)
    shown = files if limit == 0 else files[:limit]
    return {
        "directory": directory,
        "unlinked_count": len(files),
        "subtree_candidates": sub_total.get(directory, 0),
        "subtree_unlinked": sub_unlinked.get(directory, 0),
        "fully_unlinked": fully_unlinked(directory),
        "directory_linkage": {
            "status": link.get("status", "not_checked"),
            "reason": link.get("reason") or "directory linkage was not verified",
            "items": link.get("items") or [],
            "match_count": link.get("match_count", 0),
            "matched_as": link.get("matched_as", directory),
        },
        "files": shown,
        "files_truncated": len(files) - len(shown),
    }


groups, covered_groups = [], []
for directory, files in grouped.items():
    g = build_group(directory, files)
    # `linked` is the only status that disqualifies a group. `not_checked` -- the repo root, or a
    # failed second pass -- keeps the group and carries the caveat, because under-reporting a
    # finding is worse than reporting one the user can dismiss.
    (covered_groups if g["directory_linkage"]["status"] == "linked" else groups).append(g)


def order(g):
    return (-g["unlinked_count"], g["directory"])


groups.sort(key=order)
covered_groups.sort(key=order)
not_checked.sort(key=lambda r: r["path"])

unlinked_n = sum(1 for s in status_of.values() if s == "unlinked")
uncharted_n = sum(g["unlinked_count"] for g in groups)
covered_n = sum(g["unlinked_count"] for g in covered_groups)

if len(status_of) != candidate_n:
    notices.append("board-linkage checker returned %d records for %d candidate paths"
                   % (len(status_of), candidate_n))
if not_checked:
    notices.append("%d path(s) could not be checked for board linkage; they are reported "
                   "separately and are NOT counted as unlinked" % len(not_checked))
if covered_groups:
    notices.append("%d file(s) in %d director(y|ies) have no provenance of their own but sit "
                   "under a board-referenced directory; reported as covered, not offered"
                   % (covered_n, len(covered_groups)))

payload = {
    "schema": "detect-unlinked-code/2",
    "repo_root": repo_root,
    "board_dir": board_dir,
    "resolver": resolver,
    "summary": {
        "tracked_paths": tracked_n,
        "excluded_paths": tracked_n - candidate_n,
        "candidate_paths": candidate_n,
        "linked_paths": linked_by_board + linked_by_commit,
        "linked_by_board": linked_by_board,
        "linked_by_commit": linked_by_commit,
        "unlinked_paths": unlinked_n,
        "uncharted_paths": uncharted_n,
        "covered_paths": covered_n,
        "not_checked_paths": len(not_checked),
        "groups": len(groups),
        "covered_groups": len(covered_groups),
    },
    "groups": groups,
    "covered_groups": covered_groups,
    "not_checked": not_checked,
    "exclusions": {
        "prefixes": EXCLUDED_PREFIXES,
        "globs": globs,
        "gitignored": ignored_n,
    },
    "notices": notices,
}

print(json.dumps(payload, indent=2, ensure_ascii=False))
PY
)

python3 -c "$PY_MAIN" \
  "$REPO_ROOT" "$BOARD_DIR" "$RESOLVER" "$LINKAGE" "$COMMITS" "$EXCLUDE_GLOBS" \
  "$LIMIT" "$COUNTS"
