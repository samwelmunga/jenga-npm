#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# skills/uncharted/scripts/resolve-segment-target.sh
#
# Deterministic front half of `/uncharted segment`. Given the raw argument the
# user typed, it answers two mechanical questions so the agent never has to
# guess at them:
#
#   1. Is this argument an existing path, or free text?
#   2. If it is a path — does it already have BOARD PROVENANCE? That is, does
#      any file under `project/board/` reference it?
#
# It resolves, it classifies, it reports. It NEVER writes anything, never runs
# the engine, and never touches application code. Deciding what to do with the
# answer — which candidate to pick, whether the segment is worth investigating
# — is agent judgement and lives in `skills/uncharted/SKILL.md`.
#
# ---------------------------------------------------------------------------
# BOARD-LINKAGE CHECK — the reusable interface
# ---------------------------------------------------------------------------
# The linkage half is a documented, stable interface, because `/reconcile`
# (E40_S05_T02) reuses it instead of growing a second, divergent answer to
# "is this path on the board". Two entry points:
#
#   Single:  resolve-segment-target.sh --json-only <path>
#   Batch:   git ls-files | resolve-segment-target.sh --paths-from -
#
# Both emit the same `results[]` records, so a caller can read
# `.results[].board_linkage.status` either way. Batch mode exists so a caller
# with hundreds of paths reads the board ONCE rather than forking this script
# per file.
#
#   board_linkage.status  "linked"      >=1 board file references the path
#                         "unlinked"    no board file references it  <-- the
#                                       condition that makes a segment worth
#                                       investigating at all
#                         "not_checked" the question is not meaningful here:
#                                       target is the repo root (every board
#                                       file would "match"), the target is
#                                       outside this repo, or there is no
#                                       `project/board/` directory. Read
#                                       `board_linkage.reason` for which.
#
#   board_linkage.items   Board IDs (E##, E##_S##, E##_S##_T##) that reference
#                         the path, sorted, capped by --limit.
#   board_linkage.files   Repo-relative board files that reference it, sorted,
#                         capped by --limit.
#   board_linkage.match_count  Total referencing files BEFORE the cap.
#
# MATCH SEMANTICS. Board text is tokenised into maximal path-like runs
# (`[A-Za-z0-9_./-]+`, trailing `.`/`-` stripped so a filename ending a sentence
# still counts). A board file references the path when one of its tokens either
# equals the path or is a DESCENDANT of it — so `skills/uncharted` is referenced
# by a board item that only names `skills/uncharted/scripts/run-engine.sh`.
#
# This is a path-boundary test, not a substring test: `docs/hooks` does not make
# `hooks` linked, and `src/app.js` does not make `src/app` linked.
#
# This is deliberately the same question `run-engine.sh` answers for the
# understanding document's `Board Linkage` row, so the document and this script
# never contradict each other. The boundary requirement is the one refinement:
# `run-engine.sh` uses a bare substring test, which would report a short path
# like `hooks` as linked because some board item happens to contain the word
# "hooks" in prose. Collapsing the two implementations into one is a deliberate
# follow-up, not something to do by accident — see the note in SKILL.md.
#
# ---------------------------------------------------------------------------
# CANDIDATES — hints, not a decision
# ---------------------------------------------------------------------------
# When the argument is NOT an existing path, it is treated as a free-text
# feature description and the script returns `candidates[]`: tracked paths
# whose repo-relative path or basename matches the description's significant
# tokens, ranked by how many distinct tokens they matched and capped by
# --limit.
#
# These are raw material for the numbered choice list the agent presents, per
# the Interaction Pattern in `CLAUDE.md`. They are NOT a resolution. An empty
# `candidates[]` is a normal, valid result — it means "ask the user", not
# "fail". The script never picks one.
#
# ---------------------------------------------------------------------------
# Usage
# ---------------------------------------------------------------------------
#   resolve-segment-target.sh [options] <path-or-description>
#   resolve-segment-target.sh [options] --paths-from <file|->
#
# Options:
#   --paths-from <file|->  Batch mode. Read newline-separated paths from a file
#                          (or stdin with `-`) and emit one record per path.
#                          Blank lines and lines starting with `#` are skipped.
#                          Implies --json-only.
#   --board-dir <dir>      Board directory to scan.
#                          Default: <repo-root>/project/board
#   --repo-root <dir>      Treat this directory as the repo root instead of
#                          asking git. Mainly for testing.
#   --limit N              Cap on candidates, and on the board IDs/files listed
#                          per record. Default 10. 0 = unlimited.
#   --json-only            Suppress the leading resolved-path line; print only
#                          the JSON object.
#   -h, --help             Show this help and exit 0.
#
# ---------------------------------------------------------------------------
# Output
# ---------------------------------------------------------------------------
# stdout, single-argument mode:
#   line 1  the resolved absolute path, or `-` when the argument is not a path
#           (suppressed by --json-only, so `TARGET=$(… | head -1)` works)
#   then    one JSON object
# stdout, batch mode: the JSON object only.
# stderr:  notices and diagnostics. Never mixed into stdout.
#
# JSON shape:
#   {
#     "schema": "resolve-segment-target/1",
#     "repo_root": "/abs/path",
#     "board_dir": "/abs/path/project/board",
#     "batch": false,
#     "results": [
#       {
#         "argument": "<as typed>",
#         "kind": "path" | "description",
#         "target": "/abs/path",            // null when kind=description
#         "target_relative": "skills/x",    // null when outside the repo
#         "target_type": "file" | "directory" | "repo_root" | null,
#         "in_repo": true,
#         "readable": true,
#         "board_linkage": { "status": …, "reason": …, "items": [],
#                            "files": [], "match_count": 0 },
#         "candidates": [ { "path": …, "type": …, "score": N } ],
#         "notices": []
#       }
#     ]
#   }
#
# Exit codes:
#   0  the argument resolved to an existing, readable path (or, in batch mode,
#      every input path did)
#   1  usage error
#   2  the argument is not an existing path — it is a description. The JSON is
#      STILL written, with `candidates[]`. This is the one non-zero exit that
#      produces normal stdout output: it means "ask the user", not "broke".
#      In batch mode: at least one input path did not exist.
#   3  the path exists but is not readable
#   4  environment error (python3 unavailable, repo root undeterminable)
#
# Requires: bash, python3, git. jq is NOT required.
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

ARGUMENT=""
HAVE_ARGUMENT=0
PATHS_FROM=""
BOARD_DIR=""
REPO_ROOT=""
LIMIT=10
JSON_ONLY=0

require_value() {
  # require_value <flag> <remaining-arg-count>
  [ "$2" -ge 2 ] || die_usage "$1 requires a value"
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --paths-from)   require_value "--paths-from" "$#"; PATHS_FROM="$2"; shift 2 ;;
    --paths-from=*) PATHS_FROM="${1#*=}"; shift ;;
    --board-dir)    require_value "--board-dir" "$#";  BOARD_DIR="$2"; shift 2 ;;
    --board-dir=*)  BOARD_DIR="${1#*=}"; shift ;;
    --repo-root)    require_value "--repo-root" "$#";  REPO_ROOT="$2"; shift 2 ;;
    --repo-root=*)  REPO_ROOT="${1#*=}"; shift ;;
    --limit)        require_value "--limit" "$#";      LIMIT="$2"; shift 2 ;;
    --limit=*)      LIMIT="${1#*=}"; shift ;;
    --json-only)    JSON_ONLY=1; shift ;;
    -h|--help)      usage; exit 0 ;;
    --)
      shift
      [ "$#" -eq 1 ] || die_usage "exactly one argument is required after --"
      ARGUMENT="$1"; HAVE_ARGUMENT=1; shift ;;
    -*)
      die_usage "unknown option \"$1\"" ;;
    *)
      # An argument that happens to start with `-` must be passed after `--`.
      [ "$HAVE_ARGUMENT" -eq 0 ] || die_usage "exactly one argument is required (got \"$ARGUMENT\" and \"$1\")"
      ARGUMENT="$1"; HAVE_ARGUMENT=1; shift ;;
  esac
done

case "$LIMIT" in
  ''|*[!0-9]*) die_usage "--limit requires a non-negative integer, got \"$LIMIT\"" ;;
esac

if [ -n "$PATHS_FROM" ]; then
  [ "$HAVE_ARGUMENT" -eq 0 ] || die_usage "--paths-from and a positional argument are mutually exclusive"
  JSON_ONLY=1
elif [ "$HAVE_ARGUMENT" -eq 0 ]; then
  die_usage "a path or description argument is required"
fi

command -v python3 >/dev/null 2>&1 || die 4 "python3 is required but was not found on PATH"

# --- repo root ------------------------------------------------------------------------------
# Anchored on THIS SCRIPT, matching run-engine.sh: the board being consulted is the board of the
# project that owns the engine, even when the target lives outside it.
if [ -z "$REPO_ROOT" ]; then
  REPO_ROOT=$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel 2>/dev/null || true)
  [ -n "$REPO_ROOT" ] || REPO_ROOT="$(pwd -P)"
fi
[ -d "$REPO_ROOT" ] || die 4 "repo root is not a directory: $REPO_ROOT"
REPO_ROOT=$(cd -- "$REPO_ROOT" && pwd -P)

[ -n "$BOARD_DIR" ] || BOARD_DIR="$REPO_ROOT/project/board"

# --- assemble the argument list -------------------------------------------------------------
ARGS_FILE=$(mktemp "${TMPDIR:-/tmp}/resolve-segment-target.XXXXXX")
cleanup() { rm -f "$ARGS_FILE"; }
trap cleanup EXIT

BATCH=0
if [ -n "$PATHS_FROM" ]; then
  BATCH=1
  if [ "$PATHS_FROM" = "-" ]; then
    cat > "$ARGS_FILE"
  else
    [ -r "$PATHS_FROM" ] || die 1 "--paths-from file is not readable: $PATHS_FROM"
    cat -- "$PATHS_FROM" > "$ARGS_FILE"
  fi
else
  printf '%s\n' "$ARGUMENT" > "$ARGS_FILE"
fi

# --- tracked-file listing, for candidate matching -------------------------------------------
# Only consulted in the description case, but gathered unconditionally and cheaply: `git
# ls-files` is one call, and keeping the python side pure (no shelling out) keeps it testable.
TRACKED_FILE=$(mktemp "${TMPDIR:-/tmp}/resolve-segment-tracked.XXXXXX")
cleanup() { rm -f "$ARGS_FILE" "$TRACKED_FILE"; }
trap cleanup EXIT
git -C "$REPO_ROOT" ls-files -z > "$TRACKED_FILE" 2>/dev/null || : > "$TRACKED_FILE"

PY_SRC=$(cat <<'PY'
import json
import os
import re
import sys

repo_root, board_dir, args_path, tracked_path, limit_s, batch_s, json_only_s = sys.argv[1:8]
limit = int(limit_s)
batch = batch_s == "1"

root = repo_root.rstrip("/")

# Cap raw scan volume so a pathological board (or a huge tracked tree) cannot hang the caller.
BOARD_FILE_CAP = 5000
TRACKED_CAP = 20000
TOKEN_MIN_LEN = 3

# Excluded from CANDIDATE HINTS ONLY. An explicit path argument is never filtered -- if the user
# names `project/board`, that is what gets resolved. These prefixes are excluded from the
# free-text search because they are Jenga's own scaffolding and generated build outputs, and a
# description like "the permission level skill" otherwise ranks `project/board/tasks` (which
# mentions every skill in the repo) above the skill itself. Kept deliberately in step with the
# exclusion list `/reconcile` uses in E40_S05_T02.
CANDIDATE_EXCLUDED_PREFIXES = (
    "project/", ".claude/", ".agents/", "node_modules/", "dist/", "build/",
    "vendor/", "target/", ".git/",
)
STOPWORDS = {
    "the", "and", "for", "with", "that", "this", "from", "into", "our", "its",
    "all", "any", "are", "was", "were", "has", "have", "had", "not", "but",
    "code", "file", "files", "dir", "directory", "feature", "module", "thing",
    "stuff", "part", "some", "new", "old", "add", "adds", "added",
}


def cap(seq):
    return list(seq) if limit == 0 else list(seq)[:limit]


def read_lines(path):
    out = []
    with open(path, encoding="utf-8", errors="replace") as fh:
        for line in fh:
            line = line.rstrip("\n").rstrip("\r")
            if batch:
                stripped = line.strip()
                if not stripped or stripped.startswith("#"):
                    continue
                out.append(stripped)
            else:
                out.append(line)
    return out


arguments = read_lines(args_path)
if not arguments:
    sys.stderr.write("Notice: no arguments to resolve\n")

try:
    with open(tracked_path, "rb") as fh:
        tracked = [p.decode("utf-8", "replace") for p in fh.read().split(b"\0") if p]
except OSError:
    tracked = []
if len(tracked) > TRACKED_CAP:
    sys.stderr.write("Notice: tracked file listing capped at %d entries for candidate matching\n"
                     % TRACKED_CAP)
    tracked = tracked[:TRACKED_CAP]


# --- board index --------------------------------------------------------------------------
# The board is read ONCE and inverted into a prefix index. A batch caller (e.g. /reconcile in
# E40_S05_T02) then classifies thousands of paths with a dict lookup each, instead of running a
# fresh regex over every board file per path -- which is the difference between a fraction of a
# second and half a minute on this repo.
PATH_TOKEN_RE = re.compile(r"[A-Za-z0-9_./-]+")
BOARD_ID_RE = re.compile(r"^(E\d+(?:_S\d+)?(?:_T\d+)?)")


def load_board():
    """-> (docs, prefix_index, state).

    docs          [(repo-relative board file, board id)]
    prefix_index  {path prefix -> {doc index, ...}}

    Every path-like run in a board file is registered under itself AND under each of its
    ancestor directories, so `skills/uncharted` is found via a board item that only ever names
    `skills/uncharted/scripts/run-engine.sh`.
    """
    docs = []
    index = {}
    if not os.path.isdir(board_dir):
        return docs, index, "no-board-dir"
    count = 0
    for dirpath, dirnames, filenames in os.walk(board_dir):
        dirnames.sort()
        for fn in sorted(filenames):
            if not fn.endswith(".md"):
                continue
            if count >= BOARD_FILE_CAP:
                sys.stderr.write("Notice: board scan capped at %d files\n" % BOARD_FILE_CAP)
                return docs, index, "ok"
            full = os.path.join(dirpath, fn)
            try:
                with open(full, encoding="utf-8", errors="replace") as fh:
                    text = fh.read()
            except OSError as exc:
                sys.stderr.write("Notice: could not read board file %s: %s\n" % (full, exc))
                continue
            rel_board = full[len(root) + 1:] if full.startswith(root + "/") else full
            m = BOARD_ID_RE.match(fn)
            docs.append((rel_board, m.group(1) if m else fn[:-3]))
            doc_i = len(docs) - 1
            seen_tokens = set()
            seen_prefixes = set()
            for raw_tok in PATH_TOKEN_RE.findall(text):
                # Trailing punctuation only: a leading dot is meaningful (`.claude/settings.json`),
                # a trailing one is almost always the end of a sentence.
                tok = raw_tok.rstrip(".-")
                if not tok or tok in seen_tokens:
                    continue
                seen_tokens.add(tok)
                parts = tok.split("/")
                for k in range(1, len(parts) + 1):
                    prefix = "/".join(parts[:k])
                    # The token itself is registered too, not just its ancestors -- an exact
                    # mention of `skills/uncharted/SKILL.md` must make that file linked.
                    if not prefix or prefix in seen_prefixes:
                        continue
                    seen_prefixes.add(prefix)
                    index.setdefault(prefix, set()).add(doc_i)
            count += 1
    return docs, index, "ok"


BOARD_DOCS, BOARD_INDEX, BOARD_STATE = load_board()


def linkage_for(target_rel):
    """Which board files reference this repo-relative path? -> (items, files).

    A board file references the path when it contains a path-like run (trailing punctuation
    stripped) that either equals the path or is a descendant of it. See the header for why
    this is a path-boundary test rather than a substring test.
    """
    hits = BOARD_INDEX.get(target_rel)
    if not hits:
        return [], []
    items, files = set(), set()
    for doc_i in hits:
        rel_board, item_id = BOARD_DOCS[doc_i]
        items.add(item_id)
        files.add(rel_board)
    return sorted(items), sorted(files)


def tokens_of(text):
    raw = re.split(r"[^A-Za-z0-9]+", text.lower())
    return [t for t in raw if len(t) >= TOKEN_MIN_LEN and t not in STOPWORDS]


def word_match(token, word):
    """Does a description token match a path word?

    Deliberately not a raw substring test. `"end" in "dependencies"` is true, which is how a
    search for "session end hook" ends up recommending `detect-dependencies.sh`. Matching is
    on whole path words with a bounded prefix allowance, so plural/derived forms still hit
    (`level`/`levels`, `dependency`/`dependencies`, `detect`/`detection`) without accidental
    infixes.
    """
    if token == word:
        return True
    if word.startswith(token) or (len(word) >= 3 and token.startswith(word)):
        return True
    n = 0
    for a, b in zip(token, word):
        if a != b:
            break
        n += 1
    return n >= 5


WORD_SPLIT_RE = re.compile(r"[^a-z0-9]+")


def words_of(text):
    return [w for w in WORD_SPLIT_RE.split(text.lower()) if w]


def score_path(path, toks):
    """Distinct-token score for one path.

    Counts DISTINCT tokens, never occurrences. Summing occurrences would rank a directory
    holding a thousand files above the one directory actually named after the description.
    A token matched in the last path segment is worth double -- `skills/jenga-permission-level`
    should beat `scripts/check-permission-level.sh` for "the permission level skill".
    """
    low = path.lower()
    last_words = words_of(low.rsplit("/", 1)[-1])
    all_words = words_of(low)
    in_last = {t for t in toks if any(word_match(t, w) for w in last_words)}
    in_rest = {t for t in toks if any(word_match(t, w) for w in all_words)} - in_last
    return 2 * len(in_last) + len(in_rest)


def candidates_for(description):
    """Bounded, deterministic hints for the agent's numbered list. Never a decision."""
    toks = set(tokens_of(description))
    if not toks:
        return []

    scored = {}
    dir_children = {}
    for path in tracked:
        if path.startswith(CANDIDATE_EXCLUDED_PREFIXES):
            continue
        hits = score_path(path, toks)
        if hits:
            scored[path] = hits
        # Every ancestor directory is a candidate in its own right: the useful unit for
        # `segment` is usually a directory, not a single file.
        parent = os.path.dirname(path)
        while parent:
            if hits:
                dir_children[parent] = dir_children.get(parent, 0) + 1
            if parent not in scored:
                d_hits = score_path(parent, toks)
                if d_hits:
                    scored[parent] = d_hits
            parent = os.path.dirname(parent)

    # A small, capped bonus for directories that actually contain matching files -- enough to
    # break ties, never enough to let breadth outrank a name match.
    for d, n in dir_children.items():
        if d in scored and n >= 2:
            scored[d] += 1

    if not scored:
        return []
    ordered = sorted(scored.items(), key=lambda kv: (-kv[1], len(kv[0]), kv[0]))
    out = []
    for path, score in ordered:
        abs_path = os.path.join(root, path)
        if os.path.isdir(abs_path):
            kind = "directory"
        elif os.path.isfile(abs_path):
            kind = "file"
        else:
            continue
        out.append({"path": path, "type": kind, "score": score})
        if limit and len(out) >= limit:
            break
    return out


def resolve(argument):
    notices = []
    rec = {
        "argument": argument,
        "kind": "description",
        "target": None,
        "target_relative": None,
        "target_type": None,
        "in_repo": False,
        "readable": False,
        "board_linkage": {
            "status": "not_checked",
            "reason": "argument is not an existing path",
            "items": [],
            "files": [],
            "match_count": 0,
        },
        "candidates": [],
        "notices": notices,
    }

    raw = argument.strip()
    if not raw:
        notices.append("empty argument")
        rec["board_linkage"]["reason"] = "empty argument"
        return rec, 2

    # Resolve relative to the repo root when the caller's cwd is elsewhere -- batch callers feed
    # us repo-relative paths from `git ls-files`. An absolute path is used as given.
    probe = raw
    if not os.path.isabs(raw) and not os.path.exists(probe):
        alt = os.path.join(root, raw)
        if os.path.exists(alt):
            probe = alt

    if not os.path.exists(probe):
        # Batch callers feed us paths, not descriptions -- a miss there means "this path is
        # gone", and running the token search per miss would be pure cost.
        if batch:
            notices.append("path does not exist")
            rec["board_linkage"]["reason"] = "path does not exist"
            return rec, 2
        rec["candidates"] = candidates_for(raw)
        if not rec["candidates"]:
            notices.append("no tracked path matched this description; ask the user directly")
        return rec, 2

    rec["kind"] = "path"
    abs_path = os.path.realpath(probe)
    rec["target"] = abs_path

    if not os.access(abs_path, os.R_OK):
        notices.append("path exists but is not readable")
        rec["board_linkage"]["reason"] = "target is not readable"
        return rec, 3
    rec["readable"] = True

    in_repo = abs_path == root or abs_path.startswith(root + "/")
    rec["in_repo"] = in_repo
    target_rel = abs_path[len(root) + 1:] if abs_path.startswith(root + "/") else None
    if abs_path == root:
        target_rel = "."
    rec["target_relative"] = target_rel

    if os.path.isdir(abs_path):
        is_root = os.path.isdir(os.path.join(abs_path, ".git")) or abs_path == root
        rec["target_type"] = "repo_root" if is_root else "directory"
    else:
        rec["target_type"] = "file"

    link = rec["board_linkage"]
    if not in_repo:
        link["status"] = "not_checked"
        link["reason"] = "target is outside this repository"
    elif rec["target_type"] == "repo_root" or target_rel in (None, "."):
        # A boundary scan for "." would match every board file. Say nothing rather than lie.
        link["status"] = "not_checked"
        link["reason"] = "target is the repository root"
    elif BOARD_STATE == "no-board-dir":
        link["status"] = "not_checked"
        link["reason"] = "no board directory at %s" % (
            board_dir[len(root) + 1:] if board_dir.startswith(root + "/") else board_dir)
    else:
        items, files = linkage_for(target_rel)
        link["match_count"] = len(files)
        link["items"] = cap(items)
        link["files"] = cap(files)
        link["status"] = "linked" if files else "unlinked"
        link["reason"] = (
            "referenced by %d board file(s)" % len(files) if files
            else "no board file references this path"
        )
    return rec, 0


results = []
worst = 0
first_path = None
for argument in arguments:
    rec, code = resolve(argument)
    results.append(rec)
    if code > worst:
        worst = code
    if first_path is None and rec["target"]:
        first_path = rec["target"]

payload = {
    "schema": "resolve-segment-target/1",
    "repo_root": root,
    "board_dir": board_dir,
    "batch": batch,
    "results": results,
}

if json_only_s != "1" and not batch:
    print(first_path if first_path else "-")
print(json.dumps(payload, indent=2, ensure_ascii=False))
sys.exit(worst)
PY
)

set +e
python3 -c "$PY_SRC" \
  "$REPO_ROOT" "$BOARD_DIR" "$ARGS_FILE" "$TRACKED_FILE" "$LIMIT" "$BATCH" "$JSON_ONLY"
RC=$?
set -e
exit "$RC"
