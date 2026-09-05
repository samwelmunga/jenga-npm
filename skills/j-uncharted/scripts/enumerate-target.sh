#!/usr/bin/env bash
# skills/j-uncharted/scripts/enumerate-target.sh
#
# Read-only target resolution and structure enumeration for the /uncharted investigative engine.
#
# Resolves a single target argument to one of three target types and emits a machine-readable
# JSON structure summary on stdout. Deterministic: the output is a pure function of the target
# and the flags -- no timestamps, no hostnames, no unsorted collections -- so two runs against an
# unchanged target produce byte-identical output and can be diffed directly.
#
# The script has NO side effects. It writes nothing to disk, creates no temp files, and invokes
# only read-only git plumbing (rev-parse, ls-files).
#
# ---------------------------------------------------------------------------------------------
# USAGE
# ---------------------------------------------------------------------------------------------
#   enumerate-target.sh [options] <target>
#
#   <target>              A file path, a directory path, or a repository root.
#
# Options:
#   --max-depth N         Bound the emitted directory tree to N levels below the target.
#                         Default: 3. Use 0 for unlimited depth. Bounds the TREE only -- file
#                         counts and line counts always cover the whole target.
#   --top N               Report the N largest files by line count. Default: 10. Use 0 for all.
#   --no-gitignore        Force `find`-based discovery even inside a git work tree, so that
#                         .gitignore'd content is enumerated. Sets "gitignore_respected": false.
#   -h, --help            Print this usage block to stdout and exit 0.
#   --                    End of options; everything after is the target.
#
# Exit codes:
#   0   Success. JSON summary on stdout.
#   1   Usage or argument error (unknown flag, missing/extra target, bad numeric value).
#   2   Target error (does not exist, is not readable/traversable, or is neither a regular
#       file nor a directory).
#
# ---------------------------------------------------------------------------------------------
# TARGET TYPES
# ---------------------------------------------------------------------------------------------
#   "file"        The target is a regular file.
#   "repo_root"   The target is a directory that is the top level of a git work tree.
#   "directory"   Any other directory.
#
# ---------------------------------------------------------------------------------------------
# FILE DISCOVERY
# ---------------------------------------------------------------------------------------------
# When the target is inside a git work tree, discovery uses:
#     git ls-files --cached --others --exclude-standard -z
# so tracked files AND untracked-but-not-ignored files are both included, while .gitignore'd
# paths are excluded by construction. Including untracked files matters for /uncharted's `import`
# mode, where a freshly pulled-in source has not been committed yet.
#
# When the target is NOT inside a git work tree, discovery falls back to `find` with .git
# directories pruned. Ignore rules cannot be applied in that case, and the output says so
# explicitly via "listing_source": "find" and "gitignore_respected": false -- no silent pruning
# of paths the caller did not ask to prune.
#
# IGNORED TARGETS. Passing a target that is itself .gitignore'd -- or whose entire contents are
# ignored -- is a first-class case for /uncharted's `import` mode: a source dropped into vendor/,
# tmp/, or any other ignored path IS inside the work tree, so `git ls-files` runs and correctly
# returns nothing. Left alone that would render an empty result byte-identical to a genuinely empty
# directory, and a downstream understanding document would confidently describe a directory that
# actually has content. To prevent that silent-empty failure, an empty git listing for a directory
# target is cross-checked against a bounded `find` probe; if the probe finds files, discovery falls
# back to `find` and the output carries "ignored_target": true with "gitignore_respected": false.
# An explicitly-named ignored FILE is always enumerated (an explicit target wins) and is likewise
# flagged with "ignored_target": true. Use --no-gitignore to force the fallback unconditionally.
#
# Symlinks, unreadable files, and paths listed by git but absent from the working tree are all
# excluded from the counts and reported under the "skipped" key rather than aborting the run.
# Empty directories are not represented: both discovery mechanisms enumerate files, not dirs.
#
# ---------------------------------------------------------------------------------------------
# OUTPUT CONTRACT (stdout, JSON)
# ---------------------------------------------------------------------------------------------
# Additive by design -- consumers should ignore keys they do not need, and new keys may be added
# without notice. Depth is counted in path components relative to the target: for "a/b/c.sh" the
# file is depth 3 and the directory "a/b" is depth 2.
#
#   {
#     "target":              absolute, symlink-resolved path to the target
#     "target_type":         "file" | "directory" | "repo_root"
#     "base_dir":            absolute directory all "path" values are relative to
#     "listing_source":      "git-ls-files" | "find" | "explicit"
#                            "explicit" means the target was a single named file, taken as given
#                            with no discovery pass and therefore no ignore filtering
#     "gitignore_respected": true when listing_source is "git-ls-files"
#     "ignored_target":      true when the target is .gitignore'd (or all of its content is), in
#                            which case discovery fell back to `find` so the content is not lost
#     "max_depth":           the depth bound in effect (0 == unlimited)
#     "total_files":         count of enumerated regular files
#     "total_lines":         summed line count across non-binary files
#     "total_bytes":         summed size in bytes
#     "binary_files":        count of files detected as binary (lines reported as 0)
#     "extensions":          [ { "extension", "files", "lines" } ]  sorted by files desc, then name
#     "tree":                [ tree entries with depth <= max_depth ] sorted by path
#     "tree_truncated":      true when at least one tree entry was truncated by the depth bound
#     "largest_files":       [ { "path", "lines", "bytes", "binary" } ] sorted by lines desc, then path
#     "skipped":             { "<reason>": { "count", "paths" } }  paths capped at 25 per reason
#   }
#
# Tree entries are one of:
#   { "path", "type": "directory", "depth", "file_count", "truncated" }
#       file_count is RECURSIVE -- it includes files below the depth bound, so a truncated
#       directory still carries a coarse size signal for `onboard` mode.
#   { "path", "type": "file", "depth", "lines", "bytes", "binary" }
#
# Files with no extension (including dotfiles such as .gitignore) bucket under "(none)".
#
# ---------------------------------------------------------------------------------------------
# EXAMPLES
# ---------------------------------------------------------------------------------------------
#   enumerate-target.sh scripts/board_resolver.sh
#   enumerate-target.sh --max-depth 2 skills/
#   enumerate-target.sh --max-depth 1 --top 20 .
#   enumerate-target.sh skills/ | jq -r '.extensions[] | "\(.files)\t\(.extension)"'
#
# Requires: bash, git, python3. (python3 is already a hard dependency of scripts/validate-board.sh.)
# jq is NOT required -- JSON is emitted by python3.

set -euo pipefail

MAX_DEPTH=3
TOP=10
TARGET=""
NO_GITIGNORE=0

usage() {
  cat <<EOF
Usage: $(basename "$0") [options] <target>

Resolve <target> (a file, a directory, or a repository root) and print a JSON structure
summary to stdout. Read-only: nothing is written to disk.

Options:
  --max-depth N   Bound the emitted directory tree to N levels (default: 3, 0 = unlimited)
  --top N         Report the N largest files by line count (default: 10, 0 = all)
  --no-gitignore  Enumerate .gitignore'd content too (forces find-based discovery)
  -h, --help      Show this help and exit

Exit codes: 0 success, 1 usage error, 2 target missing/unreadable/unsupported.
EOF
}

die_usage() {
  echo "Error: $1" >&2
  echo >&2
  usage >&2
  exit 1
}

require_int() {
  # require_int <flag> <value>  -- non-negative integer
  case "$2" in
    ''|*[!0-9]*) die_usage "$1 requires a non-negative integer, got \"$2\"" ;;
  esac
}

# --- argument parsing --------------------------------------------------------------------------
while [ "$#" -gt 0 ]; do
  case "$1" in
    --max-depth)
      [ "$#" -ge 2 ] || die_usage "--max-depth requires a value"
      require_int "--max-depth" "$2"
      MAX_DEPTH="$2"; shift 2 ;;
    --max-depth=*)
      require_int "--max-depth" "${1#*=}"
      MAX_DEPTH="${1#*=}"; shift ;;
    --top)
      [ "$#" -ge 2 ] || die_usage "--top requires a value"
      require_int "--top" "$2"
      TOP="$2"; shift 2 ;;
    --top=*)
      require_int "--top" "${1#*=}"
      TOP="${1#*=}"; shift ;;
    --no-gitignore)
      NO_GITIGNORE=1; shift ;;
    -h|--help)
      usage; exit 0 ;;
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

[ -n "$TARGET" ] || die_usage "a target is required"

# --- target resolution -------------------------------------------------------------------------
# Portable absolute-path resolution. `readlink -f` is GNU-only and absent from older macOS/BSD
# userland, so resolve via cd + `pwd -P` instead.
resolve_path() {
  local p="$1" dir base rdir
  if [ -d "$p" ]; then
    (cd -- "$p" && pwd -P)
  else
    dir=$(dirname -- "$p")
    base=$(basename -- "$p")
    rdir=$(cd -- "$dir" && pwd -P)
    printf '%s\n' "${rdir%/}/$base"
  fi
}

if [ ! -e "$TARGET" ]; then
  echo "Error: target does not exist: $TARGET" >&2
  exit 2
fi
if [ ! -r "$TARGET" ]; then
  echo "Error: target is not readable: $TARGET" >&2
  exit 2
fi

RESOLVED=$(resolve_path "$TARGET") || {
  echo "Error: could not resolve target to an absolute path: $TARGET" >&2
  exit 2
}

if [ -f "$RESOLVED" ]; then
  TARGET_TYPE="file"
  BASE_DIR=$(dirname -- "$RESOLVED")
  SEARCH_DIR="$BASE_DIR"
elif [ -d "$RESOLVED" ]; then
  if [ ! -x "$RESOLVED" ]; then
    echo "Error: target directory is not traversable (no execute permission): $RESOLVED" >&2
    exit 2
  fi
  BASE_DIR="$RESOLVED"
  SEARCH_DIR="$RESOLVED"
  TOPLEVEL=$(git -C "$RESOLVED" rev-parse --show-toplevel 2>/dev/null || true)
  if [ -n "$TOPLEVEL" ] && [ "$(cd -- "$TOPLEVEL" && pwd -P)" = "$RESOLVED" ]; then
    TARGET_TYPE="repo_root"
  else
    TARGET_TYPE="directory"
  fi
else
  echo "Error: target is neither a regular file nor a directory: $RESOLVED" >&2
  exit 2
fi

# --- file discovery ----------------------------------------------------------------------------
IN_GIT=0
if git -C "$SEARCH_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  IN_GIT=1
fi

IGNORED_TARGET=0

# Discovery implementations. Both emit NUL-separated paths relative to the target directory.
git_list() { git -C "$RESOLVED" ls-files --cached --others --exclude-standard -z -- . ; }
find_list() {
  ( cd -- "$RESOLVED" && find . \( -name .git -type d \) -prune -o -type f -print0 )
}

# Cheap emptiness probes. `head -c 1` closes the pipe after the first byte, so the producer is
# SIGPIPE'd immediately instead of walking the whole tree -- these stay O(1) on large targets.
# `|| true` absorbs both that SIGPIPE and, for git, a non-zero exit under `set -o pipefail`.
produces_output() {
  # Do NOT collapse the declaration and the assignment into `local n=$(...)`: `local` would then
  # supply the statement's exit status and mask the pipeline's (shellcheck SC2155), defeating the
  # `|| true` below. The split, the `|| true`, and the fact that every call site is a condition
  # context (where `set -e` is suspended) are all three load-bearing.
  local n
  n=$( "$1" 2>/dev/null | head -c 1 | wc -c | tr -d '[:space:]' ) || true
  [ "${n:-0}" -gt 0 ]
}

if [ "$TARGET_TYPE" = "file" ]; then
  # A single file needs no discovery pass; git/find would only re-derive the one path.
  # An explicitly-named file is ALWAYS enumerated even when ignored -- an explicit target wins --
  # but the caller is told about it so `import` mode can reason about provenance.
  if [ "$IN_GIT" -eq 1 ] && [ "$NO_GITIGNORE" -eq 0 ] \
     && git -C "$BASE_DIR" check-ignore -q -- "$RESOLVED" 2>/dev/null; then
    IGNORED_TARGET=1
  fi
  LISTING_SOURCE="explicit"
  GITIGNORE_RESPECTED=0
  list_files() { printf '%s\0' "$(basename -- "$RESOLVED")"; }
elif [ "$IN_GIT" -eq 1 ] && [ "$NO_GITIGNORE" -eq 0 ]; then
  if produces_output git_list; then
    LISTING_SOURCE="git-ls-files"
    GITIGNORE_RESPECTED=1
    list_files() { git_list; }
  elif produces_output find_list; then
    # Git found nothing but files exist on disk: the target itself is ignored, or all of its
    # content is. Falling back keeps `import` mode from silently analysing an empty payload.
    IGNORED_TARGET=1
    LISTING_SOURCE="find"
    GITIGNORE_RESPECTED=0
    list_files() { find_list; }
  else
    # Genuinely empty. Report it as a normal gitignore-respecting run with zero files.
    LISTING_SOURCE="git-ls-files"
    GITIGNORE_RESPECTED=1
    list_files() { git_list; }
  fi
else
  if [ "$IN_GIT" -eq 1 ] && [ "$NO_GITIGNORE" -eq 1 ] \
     && ! produces_output git_list && produces_output find_list; then
    IGNORED_TARGET=1
  fi
  LISTING_SOURCE="find"
  GITIGNORE_RESPECTED=0
  list_files() { find_list; }
fi

# --- aggregation and JSON emission ---------------------------------------------------------------
# The aggregator is held in a variable and handed to `python3 -c` rather than piped in on stdin:
# `python3 -` would consume stdin as the program text, leaving nothing for the file list to arrive on.
PY_SRC=$(cat <<'PY'
import json
import os
import sys
from collections import defaultdict

(base_dir, target, target_type, listing_source,
 max_depth_s, top_s, gitignore_s, ignored_target_s) = sys.argv[1:9]
max_depth = int(max_depth_s)
top = int(top_s)
gitignore_respected = gitignore_s == "1"
ignored_target = ignored_target_s == "1"
unlimited = max_depth <= 0

CHUNK = 1 << 20      # 1 MiB read window -- keeps memory flat on very large files
SNIFF = 8192         # bytes inspected for a NUL byte when classifying binary
SKIP_CAP = 25        # per-reason cap on reported skipped paths


def normalise(raw):
    s = os.fsdecode(raw)
    while s.startswith("./"):
        s = s[2:]
    return s


data = sys.stdin.buffer.read()
rel_paths = sorted({normalise(p) for p in data.split(b"\0") if p})

files = []
skipped = defaultdict(list)

for rel in rel_paths:
    abs_path = os.path.join(base_dir, rel)
    if os.path.islink(abs_path):
        # Excluded deliberately: following them would double-count, or escape the target entirely.
        skipped["symlinks"].append(rel)
        continue
    if not os.path.isfile(abs_path):
        # git ls-files reports index entries that may be deleted on disk, and gitlink entries
        # for submodules, neither of which is a readable regular file here.
        skipped["missing"].append(rel)
        continue
    try:
        size = os.path.getsize(abs_path)
        binary = False
        lines = 0
        with open(abs_path, "rb") as fh:
            head = fh.read(SNIFF)
            if b"\0" in head:
                binary = True
            else:
                lines = head.count(b"\n")
                last = head[-1:]
                while True:
                    chunk = fh.read(CHUNK)
                    if not chunk:
                        break
                    lines += chunk.count(b"\n")
                    last = chunk[-1:]
                if size > 0 and last != b"\n":
                    lines += 1   # count a final line with no trailing newline
    except OSError:
        skipped["unreadable"].append(rel)
        continue
    files.append({"path": rel, "lines": 0 if binary else lines, "bytes": size, "binary": binary})

# --- per-extension aggregation -------------------------------------------------------------------
ext_files = defaultdict(int)
ext_lines = defaultdict(int)
for f in files:
    ext = os.path.splitext(f["path"])[1] or "(none)"
    ext_files[ext] += 1
    ext_lines[ext] += f["lines"]

extensions = [
    {"extension": e, "files": ext_files[e], "lines": ext_lines[e]}
    for e in sorted(ext_files, key=lambda e: (-ext_files[e], e))
]

# --- depth-bounded tree ----------------------------------------------------------------------------
dir_file_count = defaultdict(int)   # recursive: every ancestor of a file is credited with it
for f in files:
    parts = f["path"].split("/")
    for i in range(1, len(parts)):
        dir_file_count["/".join(parts[:i])] += 1

tree = []
tree_truncated = False

for d in dir_file_count:
    depth = d.count("/") + 1
    if not unlimited and depth > max_depth:
        continue
    # A directory sitting exactly at the bound has all of its children excluded, so it is
    # truncated by definition -- directories only exist here because they contain files.
    truncated = (not unlimited) and depth == max_depth
    tree_truncated = tree_truncated or truncated
    tree.append({
        "path": d,
        "type": "directory",
        "depth": depth,
        "file_count": dir_file_count[d],
        "truncated": truncated,
    })

for f in files:
    depth = f["path"].count("/") + 1
    if not unlimited and depth > max_depth:
        tree_truncated = True
        continue
    tree.append({
        "path": f["path"],
        "type": "file",
        "depth": depth,
        "lines": f["lines"],
        "bytes": f["bytes"],
        "binary": f["binary"],
    })

tree.sort(key=lambda e: (e["path"], e["type"]))

# --- largest files ------------------------------------------------------------------------------
largest = sorted(files, key=lambda f: (-f["lines"], f["path"]))
if top > 0:
    largest = largest[:top]

summary = {
    "target": target,
    "target_type": target_type,
    "base_dir": base_dir,
    "listing_source": listing_source,
    "gitignore_respected": gitignore_respected,
    "ignored_target": ignored_target,
    "max_depth": max_depth,
    "total_files": len(files),
    "total_lines": sum(f["lines"] for f in files),
    "total_bytes": sum(f["bytes"] for f in files),
    "binary_files": sum(1 for f in files if f["binary"]),
    "extensions": extensions,
    "tree": tree,
    "tree_truncated": tree_truncated,
    "largest_files": largest,
    "skipped": {
        reason: {"count": len(paths), "paths": sorted(paths)[:SKIP_CAP]}
        for reason, paths in sorted(skipped.items())
    },
}

json.dump(summary, sys.stdout, indent=2, ensure_ascii=False)
sys.stdout.write("\n")
PY
)

list_files | python3 -c "$PY_SRC" \
  "$BASE_DIR" "$RESOLVED" "$TARGET_TYPE" "$LISTING_SOURCE" \
  "$MAX_DEPTH" "$TOP" "$GITIGNORE_RESPECTED" "$IGNORED_TARGET"
