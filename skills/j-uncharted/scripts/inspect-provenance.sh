#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# skills/j-uncharted/scripts/inspect-provenance.sh
#
# Provenance surface for `/uncharted import`'s placement-confirmation gate
# (E40_S03_T02). Given a staged source -- the `content_path` that
# `import-source.sh` (E40_S03_T01) produced -- reports what is KNOWABLE about
# its licensing and origin, so a human can make an informed placement
# decision:
#
#   - presence and detected type of any LICENSE / LICENCE / COPYING /
#     UNLICENSE / NOTICE file
#   - SPDX-License-Identifier headers found in file contents
#   - copyright lines found near the top of files
#   - git remote URL and HEAD SHA, when the source is git-derived
#
# This is an INFORMATIONAL SURFACE, not an automated legal check. It reports
# findings; the calling skill presents them and the user decides. It NEVER
# implies a source is unencumbered just because nothing was found: every
# section below states explicitly, in its own "message" field, when it found
# nothing, and the top-level "overall" object restates that plainly when
# every section comes back empty.
#
# Why --origin-* flags exist: import-source.sh deliberately strips the
# top-level .git directory after cloning or copying, as part of its
# "acquired source is hostile" security contract -- so by the time this
# script runs, the ORIGINAL remote URL and HEAD SHA it read during
# acquisition are no longer recoverable from the staged tree itself. Pass
# them through from import-source.sh's own JSON summary (fields "source",
# "source_type", "git_ref") rather than trying to re-derive something that is
# no longer on disk. Independently of that, this script ALSO detects and
# reports any NESTED .git directories still present in the staged tree (for
# example a vendored submodule checkout import-source.sh did not strip,
# since it only strips the top-level one) -- those are read directly, live,
# off disk, with no flag needed.
#
# READ-ONLY CONTRACT: this script never writes to, executes, sources, or
# otherwise modifies anything inside the target. The only git operations it
# performs against a nested .git are read-only plumbing (`config --get`,
# `rev-parse`) -- no hooks, no checkout, no fetch, matching
# import-source.sh's stance that acquired content is never executed.
#
# Usage:
#   inspect-provenance.sh [options] <staging-path>
#
# Options:
#   --origin-source <text>   The original source identifier (URL or path)
#                             that import-source.sh acquired from. Carried
#                             through verbatim -- not validated, not
#                             re-fetched.
#   --origin-type <type>     git|path|snippet -- import-source.sh's detected
#                             source_type for this acquisition.
#   --origin-ref <sha>       The HEAD short SHA import-source.sh captured
#                             before stripping .git (its "git_ref" field).
#   --max-files N            Bound on how many files are content-scanned for
#                             SPDX identifiers and copyright lines (default
#                             4000, matching detect-dependencies.sh's cap).
#   --json-out <file>        Also write the JSON report to this file.
#   -h, --help                Show this help.
#
# Output (stdout): exactly one JSON object. Diagnostics and notices
# (truncation, excluded directories, git command failures) go to stderr --
# read it, the same as every other engine script.
#
# JSON shape (top level):
#   {
#     "script": "inspect-provenance.sh", "version": 1,
#     "target": "<canonicalised staging path>",
#     "files_scanned": <int>, "files_truncated": <bool>,
#     "symlinked_files_excluded": <int>,  // never opened; see stderr notice
#     "license": {
#       "found": bool,
#       "files": [ { "path": "<relative>", "type": "MIT"|...|"unknown" } ],
#       "message": "<set iff found is false>"
#     },
#     "spdx_identifiers": {
#       "found": bool,
#       "identifiers": [ { "id": "MIT", "occurrences": N, "sources": [...] } ],
#       "message": "<set iff found is false>"
#     },
#     "copyright": {
#       "found": bool,
#       "lines": [ { "text": "...", "source": "<relative>" } ],
#       "message": "<set iff found is false>"
#     },
#     "git_origin": {
#       "applicable": bool,
#       "origin": { "source": ..., "source_type": ..., "head_sha": ... } | null,
#       "nested_repos": [ { "path": "<relative>", "remote_url": ...|null, "head_sha": ...|null } ],
#       "message": "<set iff there is nothing git-related to report>"
#     },
#     "overall": { "any_signal_found": bool, "message": "<set iff false>" },
#     "secret_files_skipped": { "count": N, "paths": [ "<relative name>", ... ] }  // OPTIONAL, see below
#   }
#
# Secret-looking files (E85_S04_T07): a file whose base name matches the shared list in
# secret-files.sh (environment files, auth files, private keys) is never opened, never counted in
# files_scanned, never classified as a license and never listed as a copyright or SPDX source. The
# list is read ONCE at start-up from `secret-files.sh patterns` and `secret-files.sh templates`;
# there is no second copy of the patterns here. Skips are reported by the OPTIONAL top-level
# "secret_files_skipped" key (count plus up to 25 sorted relative names; present ONLY when something
# was skipped, so the report for a tree without such files is byte-identical to before; it is also
# written to --json-out) and by one line on stderr from secret-files.sh ("N secret-looking file(s)
# skipped (names listed, contents never read): ..."), printed once per run and only when N > 0.
# A target that is itself a single secret-looking file is still rejected with exit 2 (this script only
# takes a directory), with that same one-line notice printed first; the file is not read.
#
# Exit codes:
#   0  report generated (regardless of whether any provenance signal was
#      found -- "nothing found" is a valid, reportable result, not a failure)
#   1  usage error (bad flag, missing argument, missing target)
#   2  target does not exist or is not a directory
#   3  python3 unavailable, or the python3 content scan itself failed
#   4  --json-out could not be written
#   5  the shared secret-file list (secret-files.sh) could not be loaded (fails closed)
#
# Requires: bash, git (only used for read-only plumbing against any nested
# .git found), python3. jq is NOT required -- JSON is emitted by python3,
# matching detect-dependencies.sh / detect-tests.sh / discover-subsystems.sh
# rather than import-source.sh's flatter jq-with-fallback approach; this
# script's nested arrays make the python convention the better fit.
# ---------------------------------------------------------------------------

set -euo pipefail

SELF="$(basename "$0")"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# The one shared list of secret-looking file names; sourcing it has no side effects.
# shellcheck source=secret-files.sh
. "$SCRIPT_DIR/secret-files.sh"

die() {
  local code="$1"; shift
  printf '%s: error: %s\n' "$SELF" "$*" >&2
  exit "$code"
}

usage() {
  sed -n '/^# Usage:/,/^# Exit codes:/p' "$0" | sed 's/^# \{0,1\}//' >&2
  exit 1
}

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------

TARGET=""
TARGET_SET=0
ORIGIN_SOURCE=""
ORIGIN_TYPE=""
ORIGIN_REF=""
MAX_FILES=4000
JSON_OUT=""

while [ "$#" -gt 0 ]; do
  case "$1" in
    --origin-source)
      [ "$#" -ge 2 ] || die 1 "--origin-source requires a value"
      ORIGIN_SOURCE="$2"; shift 2 ;;
    --origin-source=*)
      ORIGIN_SOURCE="${1#--origin-source=}"; shift ;;
    --origin-type)
      [ "$#" -ge 2 ] || die 1 "--origin-type requires a value"
      ORIGIN_TYPE="$2"; shift 2 ;;
    --origin-type=*)
      ORIGIN_TYPE="${1#--origin-type=}"; shift ;;
    --origin-ref)
      [ "$#" -ge 2 ] || die 1 "--origin-ref requires a value"
      ORIGIN_REF="$2"; shift 2 ;;
    --origin-ref=*)
      ORIGIN_REF="${1#--origin-ref=}"; shift ;;
    --max-files)
      [ "$#" -ge 2 ] || die 1 "--max-files requires a value"
      MAX_FILES="$2"; shift 2 ;;
    --max-files=*)
      MAX_FILES="${1#--max-files=}"; shift ;;
    --json-out)
      [ "$#" -ge 2 ] || die 1 "--json-out requires a value"
      JSON_OUT="$2"; shift 2 ;;
    --json-out=*)
      JSON_OUT="${1#--json-out=}"; shift ;;
    -h|--help)
      usage ;;
    --)
      shift
      if [ "$#" -gt 0 ]; then TARGET="$1"; TARGET_SET=1; shift; fi
      [ "$#" -eq 0 ] || die 1 "unexpected extra argument: $1" ;;
    -*)
      die 1 "unknown option: $1 (use -- before a target that starts with '-')" ;;
    *)
      [ "$TARGET_SET" -eq 0 ] || die 1 "unexpected extra argument: $1"
      TARGET="$1"; TARGET_SET=1; shift ;;
  esac
done

[ "$TARGET_SET" -eq 1 ] || usage

case "$MAX_FILES" in
  ''|*[!0-9]*) die 1 "--max-files must be a positive integer, got: $MAX_FILES" ;;
esac
[ "$MAX_FILES" -gt 0 ] || die 1 "--max-files must be a positive integer, got: $MAX_FILES"

if [ -n "$ORIGIN_TYPE" ]; then
  case "$ORIGIN_TYPE" in
    git|path|snippet) ;;
    *) die 1 "invalid --origin-type '$ORIGIN_TYPE' (expected git, path, or snippet)" ;;
  esac
fi

command -v python3 >/dev/null 2>&1 || die 3 "python3 is required but was not found on PATH"

[ -e "$TARGET" ] || die 2 "target does not exist: $TARGET"
if [ -f "$TARGET" ] && secret_files_is_secret "$TARGET"; then
  # A single secret-looking file is never read; say so before the unchanged "not a directory" rejection.
  secret_files_notice 1 "$(basename -- "$TARGET")"
fi
[ -d "$TARGET" ] || die 2 "target is not a directory: $TARGET (inspect the acquired content_path, not a single file)"

TARGET_ABS="$(cd -- "$TARGET" && pwd -P)"

if [ -n "$JSON_OUT" ]; then
  JSON_OUT_DIR="$(dirname -- "$JSON_OUT")"
  [ -d "$JSON_OUT_DIR" ] || die 1 "--json-out directory does not exist: $JSON_OUT_DIR"
  [ -w "$JSON_OUT_DIR" ] || die 1 "--json-out directory is not writable: $JSON_OUT_DIR"
  JSON_OUT="$(cd -- "$JSON_OUT_DIR" && pwd -P)/$(basename -- "$JSON_OUT")"
fi

# ---------------------------------------------------------------------------
# Nested .git detection (bash + git; read-only plumbing only)
#
# import-source.sh only strips the TOP-LEVEL .git of what it acquires, so a
# staged tree can still legitimately contain nested .git directories (a
# vendored checkout, an uncleaned submodule). Detected here in bash -- via
# git itself -- rather than in python, because shelling out to git for
# read-only plumbing is what git is for.
#
# Bounded to avoid a pathological walk through a huge staged tree: common
# build/dependency directory NAMES are pruned, matching the SKIP_DIRS set the
# python content scan below also uses, kept in sync deliberately.
# ---------------------------------------------------------------------------

NESTED_REPORT_FILE="$(mktemp "${TMPDIR:-/tmp}/inspect-provenance-nested.XXXXXXXX")"
trap 'rm -f "$NESTED_REPORT_FILE"' EXIT

PRUNE_NAMES=(node_modules .venv venv __pycache__ dist build .next coverage
             vendor target .mypy_cache .pytest_cache .tox .gradle .idea
             .svn .hg bower_components .terraform)

PRUNE_EXPR=()
for name in "${PRUNE_NAMES[@]}"; do
  [ "${#PRUNE_EXPR[@]}" -eq 0 ] || PRUNE_EXPR+=(-o)
  PRUNE_EXPR+=(-name "$name")
done

: > "$NESTED_REPORT_FILE"
while IFS= read -r -d '' git_dir; do
  repo_dir="$(dirname -- "$git_dir")"
  rel_path="${repo_dir#"$TARGET_ABS"/}"
  [ "$rel_path" != "$repo_dir" ] || rel_path="."
  remote_url="$(git -C "$repo_dir" config --get remote.origin.url 2>/dev/null || true)"
  head_sha="$(git -C "$repo_dir" rev-parse HEAD 2>/dev/null || true)"
  printf '%s\t%s\t%s\n' "$rel_path" "$remote_url" "$head_sha" >> "$NESTED_REPORT_FILE"
done < <(find "$TARGET_ABS" \( "${PRUNE_EXPR[@]}" \) -prune -o -type d -name .git -print0 2>/dev/null)

# ---------------------------------------------------------------------------
# License / SPDX / copyright content scan (python3 -- JSON emission, no jq)
#
# Deliberately NOT wrapped in a `$(...)` capture: the macOS-shipped bash
# (3.2, GPLv2-final -- still `/bin/bash` on every unmodified macOS install)
# has a long-standing heredoc parser bug where a `<<'quoted'` heredoc nested
# inside a `$( ... )` command substitution stops treating its body as fully
# literal once the body contains certain apostrophe/comment combinations,
# and misparses an ordinary contraction in a python comment as an unterminated
# shell string. Every sibling script in this directory
# (detect-dependencies.sh, detect-tests.sh, discover-subsystems.sh,
# apply-subsystem-cap.sh, write-backfilled-epics.sh) avoids this entirely by
# never wrapping its `python3 -c "$PY_SRC"` / `python3 - args <<'PY'` call in
# a capture -- python writes stdout (and, when requested, --json-out)
# directly. This script follows the same convention for the same reason.
# ---------------------------------------------------------------------------

python3 - "$TARGET_ABS" "$ORIGIN_SOURCE" "$ORIGIN_TYPE" "$ORIGIN_REF" "$MAX_FILES" "$NESTED_REPORT_FILE" "$JSON_OUT" "$SCRIPT_DIR/secret-files.sh" <<'PY'
import fnmatch
import json
import os
import re
import subprocess
import sys

TARGET, ORIGIN_SOURCE, ORIGIN_TYPE, ORIGIN_REF, MAX_FILES_S, NESTED_REPORT_FILE, JSON_OUT, SECRET_FILES_SH = sys.argv[1:9]
MAX_FILES = int(MAX_FILES_S)
MAX_BYTES = 262144  # 256KB -- generous for a license file, a hard stop for anything else
COPYRIGHT_HEAD_LINES = 25

notices = []

SKIP_DIRS = {
    ".git", "node_modules", ".venv", "venv", "__pycache__", "dist", "build",
    ".next", "coverage", "vendor", "target", ".mypy_cache", ".pytest_cache",
    ".tox", ".gradle", ".idea", ".svn", ".hg", "bower_components", ".terraform",
}

LICENSE_NAME_RE = re.compile(
    r"^(LICENSE|LICENCE|COPYING|COPYING\.LESSER|UNLICENSE|NOTICE)(\.[A-Za-z0-9]+)?$",
    re.IGNORECASE,
)

# Ordered (most specific first) content signatures for well-known licenses.
# This is a heuristic classifier, not a legal determination -- a match means
# "the text strongly resembles this license", nothing stronger.
LICENSE_SIGNATURES = [
    ("Apache-2.0", [r"apache license", r"version\s*2\.0"]),
    ("GPL-3.0", [r"gnu general public license", r"version\s*3"]),
    ("GPL-2.0", [r"gnu general public license", r"version\s*2"]),
    ("LGPL-3.0", [r"gnu lesser general public license", r"version\s*3"]),
    ("LGPL-2.1", [r"gnu lesser general public license", r"version\s*2\.1"]),
    ("MPL-2.0", [r"mozilla public license", r"version\s*2\.0"]),
    ("BSD-3-Clause", [r"redistributions of source code must retain",
                       r"redistributions in binary form",
                       r"may be used to endorse or promote products"]),
    ("BSD-2-Clause", [r"redistributions of source code must retain",
                       r"redistributions in binary form"]),
    ("Unlicense", [r"this is free and unencumbered software released into the public domain"]),
    ("ISC", [r"permission to use, copy, modify, and/or distribute this software"]),
    ("MIT", [r"permission is hereby granted, free of charge",
              r"the software is provided \"as is\""]),
]

SPDX_RE = re.compile(r"SPDX-License-Identifier:\s*([A-Za-z0-9.\-+() ]+?)\s*(?:\*/|-->|#>)?\s*$")
COPYRIGHT_RE = re.compile(r"copyright\b.{0,120}", re.IGNORECASE)
COPYRIGHT_HAS_SIGNAL_RE = re.compile(r"(\(c\)|©|\d{4})", re.IGNORECASE)


def rel(path):
    r = os.path.relpath(path, TARGET)
    return r.replace(os.sep, "/") if r != "." else os.path.basename(path) or "."


# ---------------------------------------------------------------------------
# Secret-looking files (E85_S04_T07). The one list lives in secret-files.sh; it is read here once and
# applied to base names only, so a matching file is never opened, counted or listed.
# ---------------------------------------------------------------------------


def _secret_files_list(what):
    try:
        res = subprocess.run(["bash", SECRET_FILES_SH, what], stdout=subprocess.PIPE,
                             stderr=subprocess.PIPE, universal_newlines=True, check=True)
    except (OSError, subprocess.CalledProcessError) as exc:
        sys.stderr.write("inspect-provenance.sh: error: cannot load the secret-file list from %s: %s\n"
                          % (SECRET_FILES_SH, exc))
        sys.exit(5)
    return [line for line in res.stdout.split("\n") if line]


SECRET_PATTERNS = _secret_files_list("patterns")
SECRET_TEMPLATES = _secret_files_list("templates")
secret_skipped = set()


def is_secret_name(name):
    """Same rule as secret-files.sh: lower-cased base name, not a template, matches some pattern."""
    name = os.path.basename(name.rstrip("/")).lower()
    if not name or name in SECRET_TEMPLATES:
        return False
    return any(fnmatch.fnmatchcase(name, g) for g in SECRET_PATTERNS)


def is_probably_binary(path):
    if is_secret_name(path):  # defence in depth: the walk already filters these out
        return True
    try:
        with open(path, "rb") as fh:
            chunk = fh.read(1024)
    except OSError:
        return True
    return b"\x00" in chunk


def read_text(path, max_bytes=MAX_BYTES):
    if is_secret_name(path):  # defence in depth: the walk already filters these out
        return None
    try:
        if os.path.getsize(path) > max_bytes * 8:
            # Absurdly large for a source file we'd scan headers of -- skip outright.
            return None
        with open(path, "r", encoding="utf-8", errors="replace") as fh:
            return fh.read(max_bytes)
    except OSError:
        return None


def walk_files(root):
    # Symlinked FILES are enumerated but never opened for content scanning
    # below (see the security note at the call site) -- a staged tree is
    # untrusted input, and a symlink pointing outside the staging root must
    # not let this scan read (and then surface, in its report) an arbitrary
    # host file. `os.walk`'s default `followlinks=False` already keeps this
    # from recursing INTO a symlinked directory as though it were part of
    # the tree, which covers the directory half of the same concern.
    out = []
    symlinks = []
    truncated = False
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames[:] = sorted(d for d in dirnames if d not in SKIP_DIRS)
        for fn in sorted(filenames):
            fpath = os.path.join(dirpath, fn)
            if is_secret_name(fn):
                # By name only: never opened, never stat'ed for type, not counted against the cap.
                secret_skipped.add(rel(fpath))
                continue
            if os.path.islink(fpath):
                symlinks.append(fpath)
                continue
            out.append(fpath)
            if len(out) >= MAX_FILES:
                truncated = True
                return out, symlinks, truncated
    return out, symlinks, truncated


all_files, symlinked_files, files_truncated = walk_files(TARGET)
if files_truncated:
    notices.append(
        "file walk hit the --max-files cap of %d; some files were not scanned. "
        "Re-run with a higher --max-files for a fuller scan of a large staged tree."
        % MAX_FILES
    )
if symlinked_files:
    notices.append(
        "%d symlinked file(s) were found in the staged tree and were NOT opened for "
        "content scanning -- a symlink can point outside the staged tree, and this scan "
        "never follows one to read its target. Inspect them manually if their target "
        "matters: %s"
        % (len(symlinked_files),
           ", ".join(rel(p) for p in symlinked_files[:10]) +
           (", ..." if len(symlinked_files) > 10 else ""))
    )
notices.append(
    "content scan excludes common build/dependency directories (%s); "
    "third-party licensing nested inside them is not surfaced by this scan."
    % ", ".join(sorted(SKIP_DIRS - {".git"}))
)

# ---------------------------------------------------------------------------
# License files
# ---------------------------------------------------------------------------

license_files = []
for path in all_files:
    name = os.path.basename(path)
    if not LICENSE_NAME_RE.match(name):
        continue
    if is_probably_binary(path):
        license_files.append({"path": rel(path), "type": "unknown"})
        continue
    text = read_text(path) or ""
    normalised = re.sub(r"\s+", " ", text).lower()
    detected = "unknown"
    for lic_id, patterns in LICENSE_SIGNATURES:
        if all(re.search(p, normalised) for p in patterns):
            detected = lic_id
            break
    license_files.append({"path": rel(path), "type": detected})

license_files.sort(key=lambda e: e["path"])
license_section = {
    "found": len(license_files) > 0,
    "files": license_files,
    "message": None if license_files else
    "no LICENSE, LICENCE, COPYING, UNLICENSE, or NOTICE file was found in the staged source",
}

# ---------------------------------------------------------------------------
# SPDX identifiers + copyright lines -- single content pass over non-license,
# non-binary files (license files are already fully classified above, but a
# copyright/SPDX line inside one is still worth surfacing, so they are not
# excluded from this pass).
# ---------------------------------------------------------------------------

spdx_index = {}   # id -> {"id":..., "occurrences":..., "sources":[...]}
copyright_lines = []
copyright_seen = set()
files_scanned = 0

for path in all_files:
    if is_probably_binary(path):
        continue
    text = read_text(path)
    if text is None:
        continue
    files_scanned += 1
    source = rel(path)

    for line in text.splitlines():
        m = SPDX_RE.search(line)
        if m:
            spdx_id = m.group(1).strip()
            if not spdx_id:
                continue
            entry = spdx_index.setdefault(
                spdx_id, {"id": spdx_id, "occurrences": 0, "sources": []}
            )
            entry["occurrences"] += 1
            if source not in entry["sources"] and len(entry["sources"]) < 5:
                entry["sources"].append(source)

    for line in text.splitlines()[:COPYRIGHT_HEAD_LINES]:
        m = COPYRIGHT_RE.search(line)
        if not m or not COPYRIGHT_HAS_SIGNAL_RE.search(m.group(0)):
            continue
        cleaned = re.sub(r"^[\s#/*\-]+", "", line).strip()
        cleaned = re.sub(r"[\s*/\-]+$", "", cleaned)
        if not cleaned:
            continue
        key = (cleaned, source)
        if key in copyright_seen:
            continue
        copyright_seen.add(key)
        if len(copyright_lines) < 200:
            copyright_lines.append({"text": cleaned, "source": source})

spdx_identifiers = sorted(spdx_index.values(), key=lambda e: e["id"])
spdx_section = {
    "found": len(spdx_identifiers) > 0,
    "identifiers": spdx_identifiers,
    "message": None if spdx_identifiers else
    "no SPDX-License-Identifier headers were found in any scanned file",
}

copyright_section = {
    "found": len(copyright_lines) > 0,
    "lines": copyright_lines,
    "message": None if copyright_lines else
    "no copyright lines were found near the top of any scanned file",
}

# ---------------------------------------------------------------------------
# git origin -- forwarded acquisition metadata + nested repos found on disk
# ---------------------------------------------------------------------------

origin = None
if ORIGIN_TYPE == "git" or ORIGIN_SOURCE or ORIGIN_REF:
    origin = {
        "source": ORIGIN_SOURCE or None,
        "source_type": ORIGIN_TYPE or None,
        "head_sha": ORIGIN_REF or None,
    }

nested_repos = []
try:
    with open(NESTED_REPORT_FILE, "r", encoding="utf-8", errors="replace") as fh:
        for line in fh:
            line = line.rstrip("\n")
            if not line:
                continue
            parts = line.split("\t")
            path = parts[0] if len(parts) > 0 else "."
            remote = parts[1] if len(parts) > 1 and parts[1] else None
            head = parts[2] if len(parts) > 2 and parts[2] else None
            nested_repos.append({"path": path, "remote_url": remote, "head_sha": head})
except OSError:
    pass

git_applicable = origin is not None or len(nested_repos) > 0
git_message = None
if not git_applicable:
    git_message = (
        "no git origin information is available -- either the source was not "
        "git-acquired, or no --origin-* flags were passed and no nested .git "
        "directory was found in the staged tree"
    )
elif origin is None:
    notices.append(
        "nested git repositories were found but no --origin-* flags were passed; "
        "the acquiring import-source.sh run's own summary (source/source_type/git_ref) "
        "was not forwarded to this scan"
    )

git_origin_section = {
    "applicable": git_applicable,
    "origin": origin,
    "nested_repos": nested_repos,
    "message": git_message,
}

# ---------------------------------------------------------------------------
# Overall
# ---------------------------------------------------------------------------

any_signal_found = (
    license_section["found"]
    or spdx_section["found"]
    or copyright_section["found"]
    or (git_origin_section["applicable"] and (origin is not None or nested_repos))
)

overall = {
    "any_signal_found": any_signal_found,
    "message": None if any_signal_found else
    "no license information was found in this staged source -- this means the scan found "
    "nothing, NOT that the source is unencumbered. Verify with the original source before "
    "importing it into the repository.",
}

result = {
    "script": "inspect-provenance.sh",
    "version": 1,
    "target": TARGET,
    "files_scanned": files_scanned,
    "files_truncated": files_truncated,
    "symlinked_files_excluded": len(symlinked_files),
    "license": license_section,
    "spdx_identifiers": spdx_section,
    "copyright": copyright_section,
    "git_origin": git_origin_section,
    "overall": overall,
}

if secret_skipped:
    result["secret_files_skipped"] = {
        "count": len(secret_skipped),
        "paths": sorted(secret_skipped)[:25],
    }

rendered = json.dumps(result, indent=2, ensure_ascii=False) + "\n"

if JSON_OUT:
    try:
        with open(JSON_OUT, "w", encoding="utf-8") as fh:
            fh.write(rendered)
    except OSError as exc:
        sys.stderr.write("%s: error: failed to write --json-out to %s: %s\n"
                          % ("inspect-provenance.sh", JSON_OUT, exc))
        sys.exit(4)

sys.stdout.write(rendered)

for n in notices:
    sys.stderr.write("Notice: %s\n" % n)

# One shared notice line on stderr, once per run, only when something was skipped (names only).
if secret_skipped:
    sys.stderr.flush()
    subprocess.call(["bash", SECRET_FILES_SH, "notice", str(len(secret_skipped))]
                    + sorted(secret_skipped)[:1000])
PY
