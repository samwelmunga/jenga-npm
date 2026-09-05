#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# skills/j-self-sync/scripts/mark-merged.sh
#
# Given the COPY_SET-scoped sync diff computed by E51_S02_T01's
# compute-sync-diff.sh, marks closed board tickets (tasks/stories with
# status Done/Passed/Passed with remarks) as `Merged` once every file their
# own EST-tagged commit history touched has been mirrored into
# .claude/.agents (i.e. appears in the diff).
#
# There is no stored per-ticket touched-file list to read: close-story
# (skills/close-story/scripts/extract-task-diff-stats.sh) only ever persists
# aggregate COUNTS (actual_files_changed / actual_lines_delta), never a list
# of paths. This script derives the list itself, on demand, from git history
# — reusing close-story's commit-matching convention
# (`git log --all --no-merges --grep=...`) but reading `git diff --name-only`
# instead of `--stat`, to get actual paths rather than a count.
#
# Deliberate deviation from close-story's grep pattern: close-story only
# ever matches a TASK id (E##_S##_T##), which is a leaf with nothing nested
# under it, so a plain substring --grep is safe there. This script also
# enumerates STORY tickets (E##_S##), and a story id is a literal string
# prefix of every one of its own tasks' ids (e.g. "E51_S02" is a substring
# of "E51_S02_T01"). A plain substring grep would over-attribute every
# child task's commits to the story itself. This script anchors the grep
# pattern instead: "<id>([^0-9_]|$)" — matches "E51_S02):" (as in
# `story(E51_S02): ...`) but not "E51_S02_T01):" (as in
# `task(E51_S02_T01): ...`), since the character immediately following the
# story id in the task-commit case is "_". This only tightens matching
# (removes false positives) and cannot change task-id matching at all,
# since nothing is ever nested under a task id.
#
# Bundle-attribution semantics: identical to close-story's "full credit"
# model. If a single commit's message matches more than one ticket id
# (e.g. a bundled commit mentioning both a story and one of its tasks, or
# multiple sibling tasks), each matching ticket independently discovers
# that same commit via its own grep and is credited with that commit's
# full file set — no separate bundle-detection logic is needed.
#
# Matching logic (per ticket, once enumerated as closed):
#   1. Find EST-tagged commits: git log --all --no-merges --grep=<anchored id>
#   2. Zero matched commits -> touched-file list is empty -> ticket is left
#      unchanged (nothing to compare against the sync diff).
#   3. For each matched commit, get its actual changed paths via
#      `git diff --name-only <sha>~1..<sha>`, falling back to
#      `git diff-tree --no-commit-id --name-only -r <sha>` for a commit with
#      no parent (root commit) -- a small robustness improvement over
#      extract-task-diff-stats.sh, which silently skips such commits since
#      it only ever needed a count, not a complete file list.
#   4. Union (dedup) the file paths across all matched commits.
#   5. If EVERY file in the union appears in the sync diff -> write
#      `status: Merged` via scripts/with-lock.sh + close-story's existing
#      update-task-frontmatter.sh (reused, not reimplemented).
#   6. Partial coverage (some but not all files in the diff) -> leave
#      unchanged, no partial marking.
#   7. A ticket already at status: Merged is skipped without error
#      (explicit defensive check, on top of the closed-status filter which
#      already structurally excludes it once its status stops reading
#      Done/Passed/Passed with remarks).
#
# Diff source (documented interface -- caller's choice of any one of):
#   --diff-file <path>   Read newline-separated diff paths from a file.
#                         Primarily for testability (feed a synthetic diff
#                         without a real /self-sync run).
#   --stdin               Explicitly read diff paths from stdin -- e.g.
#                         `compute-sync-diff.sh | mark-merged.sh --stdin`.
#   (neither)              Default: invoke the sibling compute-sync-diff.sh
#                         as a subprocess and use its stdout. This is the
#                         path E51_S02_T03 wires into /self-sync itself.
#
# Deliberately NOT using a `[ ! -t 0 ]` (stdin-is-not-a-TTY) heuristic to
# auto-detect piped input: this script's real production caller is a
# subprocess spawn from run.js (Node), and a spawned child's stdin is a
# non-TTY pipe by default whether or not the parent actually writes
# anything to it -- the same is true of this very script under any
# non-interactive harness (verified while authoring this script: this
# session's own shell reports `[ -t 0 ]` false with nothing piped in). A
# TTY check cannot distinguish "caller piped a real diff" from "caller
# spawned me with no meaningful stdin" in exactly the environment this
# script will actually run in, so the diff source must be an explicit,
# unambiguous flag instead.
#
# Marker advancement: this script -- NOT compute-sync-diff.sh -- is
# responsible for advancing the local `last-self-sync` git tag to current
# HEAD, and ONLY after the full enumeration loop has completed with zero
# errors. A failure partway through (e.g. a with-lock.sh timeout on one
# ticket's board file) leaves the marker untouched, so a retry recomputes
# and reprocesses the same diff rather than silently losing part of it.
#
# Exit codes:
#   0  success (including the "nothing to do" cases: empty diff, or no
#      ticket fully covered -- zero board writes, marker still advances)
#   1  error (see stderr message) -- no marker advancement
# ---------------------------------------------------------------------------

set -euo pipefail
IFS=$'\n\t'

TAG_NAME="last-self-sync"

# -----------------------------------------------------------------------------
# Helpers
# -----------------------------------------------------------------------------

die() {
  printf 'mark-merged.sh: error: %s\n' "$*" >&2
  exit 1
}

log() {
  printf 'mark-merged.sh: %s\n' "$*" >&2
}

usage() {
  cat <<'EOF'
Usage: mark-merged.sh [--diff-file <path> | --stdin] [-h|--help]

Marks closed board tickets (tasks/stories with status Done, Passed, or
Passed with remarks) as `Merged` when every file their EST-tagged commit
history touched appears in the current sync diff.

Diff source (pick one; documented in the script header):
  --diff-file <path>   Read newline-separated diff paths from a file.
  --stdin               Explicitly read newline-separated diff paths from
                        stdin (e.g. `compute-sync-diff.sh | mark-merged.sh
                        --stdin`). Not auto-detected -- see script header
                        for why a TTY check is unsafe here.
  (neither)              Default: invoke the sibling compute-sync-diff.sh.

Advances the local `last-self-sync` git tag to current HEAD only after all
processing completes without error.
EOF
}

DIFF_FILE_ARG=""
READ_STDIN=0

while [ $# -gt 0 ]; do
  case "$1" in
    --diff-file)
      [ $# -ge 2 ] || die "--diff-file requires a path argument"
      DIFF_FILE_ARG="$2"
      shift 2
      ;;
    --stdin)
      READ_STDIN=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      usage >&2
      die "unknown argument: $1"
      ;;
  esac
done

if [ -n "$DIFF_FILE_ARG" ] && [ "$READ_STDIN" -eq 1 ]; then
  usage >&2
  die "--diff-file and --stdin are mutually exclusive"
fi

# -----------------------------------------------------------------------------
# Locate script + repo root
#
# Same symlink-resolution + repo-root derivation pattern as
# compute-sync-diff.sh, so this script behaves identically whether invoked
# directly or via a symlink.
# -----------------------------------------------------------------------------

SCRIPT_PATH="${BASH_SOURCE[0]}"
while [ -h "$SCRIPT_PATH" ]; do
  LINK_TARGET="$(readlink "$SCRIPT_PATH")"
  case "$LINK_TARGET" in
    /*) SCRIPT_PATH="$LINK_TARGET" ;;
    *)  SCRIPT_PATH="$(cd "$(dirname "$SCRIPT_PATH")" && pwd)/$LINK_TARGET" ;;
  esac
done
SCRIPT_DIR="$(cd "$(dirname "$SCRIPT_PATH")" && pwd)"

REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel 2>/dev/null || true)"
[ -n "$REPO_ROOT" ] || die "could not locate repo root (git rev-parse failed from $SCRIPT_DIR)"

COMPUTE_DIFF_SCRIPT="$SCRIPT_DIR/compute-sync-diff.sh"
RUN_JS="$SCRIPT_DIR/run.js"
WITH_LOCK_SCRIPT="$REPO_ROOT/scripts/with-lock.sh"
UPDATE_FRONTMATTER_SCRIPT="$REPO_ROOT/skills/close-story/scripts/update-task-frontmatter.sh"

[ -f "$WITH_LOCK_SCRIPT" ] || die "expected script not found: $WITH_LOCK_SCRIPT"
[ -f "$UPDATE_FRONTMATTER_SCRIPT" ] || die "expected script not found: $UPDATE_FRONTMATTER_SCRIPT"
[ -f "$RUN_JS" ] || die "expected sibling file not found: $RUN_JS (skills/j-self-sync/scripts/run.js)"
command -v node >/dev/null 2>&1 || die "node not installed (required to read COPY_SET out of $RUN_JS)"

TASKS_DIR="$REPO_ROOT/project/board/tasks"
STORIES_DIR="$REPO_ROOT/project/board/stories"

# -----------------------------------------------------------------------------
# COPY_SET -- read the same way compute-sync-diff.sh reads it, directly out
# of run.js's literal `const COPY_SET = [ ... ];`, so the two can never
# drift apart (this duplicates compute-sync-diff.sh's own extraction
# function rather than factoring it into shared tooling -- a small, known
# duplication left as-is rather than introducing a third script for one
# ~15-line helper; flagged here for visibility, not fixed, matching this
# repo's existing precedent of tolerating a couple of small duplicated
# helpers rather than over-factoring for a single reuse site).
#
# WHY THIS MATTERS (found during implementation, not in the original task
# spec): compute-sync-diff.sh's diff is scoped to COPY_SET -- it can never
# contain a project/board/... path, since board files are not part of what
# /self-sync mirrors. But a ticket's own commit history routinely includes
# a commit that touches ONLY its own board file (the tester's
# `board(<id>): mark task Passed` commit, observed as standard practice in
# this repo's own git log). If the touched-file union used for the coverage
# check were left unfiltered, it would always include that never-mirrored
# board path, and no real ticket could ever be marked Merged -- the AC2
# "every derived file appears in the sync diff" bar would be permanently
# unclearable. Filtering the touched-file list down to COPY_SET-relevant
# paths before the coverage check is what makes AC2 a satisfiable
# condition at all for real tickets, not just synthetic ones.
# -----------------------------------------------------------------------------

extract_copy_set() {
  node -e '
    const fs = require("fs");
    const src = fs.readFileSync(process.argv[1], "utf8");
    const m = src.match(/const COPY_SET = \[([\s\S]*?)\];/);
    if (!m) {
      process.stderr.write("could not find a COPY_SET array in " + process.argv[1] + "\n");
      process.exit(1);
    }
    const items = m[1]
      .split(",")
      .map((s) => s.trim())
      .filter((s) => s.length > 0)
      .map((s) => s.replace(/^[\x27"]|[\x27"]$/g, ""));
    if (items.length === 0) {
      process.stderr.write("COPY_SET array in " + process.argv[1] + " parsed as empty\n");
      process.exit(1);
    }
    items.forEach((i) => console.log(i));
  ' "$RUN_JS" || die "failed to extract COPY_SET from $RUN_JS"
}

COPY_SET=()
while IFS= read -r entry; do
  [ -n "$entry" ] || continue
  COPY_SET+=("$entry")
done < <(extract_copy_set)

[ "${#COPY_SET[@]}" -gt 0 ] || die "extracted an empty COPY_SET from $RUN_JS"

# True (0) iff $1 is exactly a COPY_SET entry, or nested under one
# (directory-prefix match), matching how git pathspecs treat a bare
# directory entry in compute-sync-diff.sh's own `git diff -- "${COPY_SET[@]}"`.
is_in_copy_set() {
  local path="$1" entry
  for entry in "${COPY_SET[@]}"; do
    case "$path" in
      "$entry"|"$entry"/*) return 0 ;;
    esac
  done
  return 1
}

# Filters $1 (newline-separated paths) down to only those under COPY_SET.
filter_to_copy_set() {
  local input="$1" line
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    is_in_copy_set "$line" && printf '%s\n' "$line"
  done <<< "$input"
  return 0
}

# -----------------------------------------------------------------------------
# Resolve the diff source and materialise it into a sorted-unique temp file
# -----------------------------------------------------------------------------

DIFF_FILE="$(mktemp)"
CLEANUP_FILES=("$DIFF_FILE")
cleanup() {
  rm -f "${CLEANUP_FILES[@]}" 2>/dev/null || true
}
trap cleanup EXIT

if [ -n "$DIFF_FILE_ARG" ]; then
  [ -f "$DIFF_FILE_ARG" ] || die "--diff-file path not found: $DIFF_FILE_ARG"
  log "reading sync diff from --diff-file: $DIFF_FILE_ARG"
  sort -u "$DIFF_FILE_ARG" > "$DIFF_FILE"
elif [ "$READ_STDIN" -eq 1 ]; then
  log "reading sync diff from stdin (--stdin)"
  sort -u > "$DIFF_FILE"
else
  [ -f "$COMPUTE_DIFF_SCRIPT" ] || die "expected sibling script not found: $COMPUTE_DIFF_SCRIPT"
  log "no --diff-file and no --stdin -- invoking compute-sync-diff.sh"
  RAW_DIFF="$(mktemp)"
  CLEANUP_FILES+=("$RAW_DIFF")
  if ! "$COMPUTE_DIFF_SCRIPT" > "$RAW_DIFF"; then
    die "compute-sync-diff.sh failed -- aborting (marker not advanced)"
  fi
  sort -u "$RAW_DIFF" > "$DIFF_FILE"
fi

# Strip any accidental blank lines so an empty diff is truly a zero-byte
# comparison set, not one containing a single blank line. Uses a temp file
# + mv rather than `sed -i` -- same GNU/BSD portability rationale
# update-task-frontmatter.sh already documents for this repo (macOS ships
# BSD sed, whose -i has different syntax than GNU's). `grep -v` exits 1
# when nothing matches (including on a wholly-empty input), so the `mv` is
# unconditional rather than chained with `&&`, or a genuinely-empty diff
# would silently fail to overwrite $DIFF_FILE.
BLANK_STRIPPED="$(mktemp)"
CLEANUP_FILES+=("$BLANK_STRIPPED")
grep -v '^[[:space:]]*$' "$DIFF_FILE" > "$BLANK_STRIPPED" 2>/dev/null || true
mv "$BLANK_STRIPPED" "$DIFF_FILE"

DIFF_LINE_COUNT="$(wc -l < "$DIFF_FILE" | tr -d '[:space:]')"
log "sync diff contains $DIFF_LINE_COUNT path(s)"

# -----------------------------------------------------------------------------
# Frontmatter field reader
#
# Same "line == ---" boundary-detection style already used by
# skills/close-story/scripts/update-task-frontmatter.sh, so board-file
# parsing stays consistent with the existing frontmatter tooling instead of
# introducing a third convention.
# -----------------------------------------------------------------------------

read_frontmatter_field() {
  local file="$1" key="$2"
  awk -v key="$key" '
    NR==1 && $0=="---" { infm=1; next }
    infm && $0=="---" { exit }
    infm && $0 ~ ("^" key ":") {
      sub("^" key ":[ \t]*", "", $0)
      print $0
      exit
    }
  ' "$file"
}

trim() {
  # Trim leading/trailing whitespace and surrounding quotes.
  local s="$1"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  s="${s%\"}"; s="${s#\"}"
  s="${s%\'}"; s="${s#\'}"
  printf '%s' "$s"
}

# -----------------------------------------------------------------------------
# Commit-matching + touched-file derivation
# -----------------------------------------------------------------------------

commits_for_ticket() {
  local id="$1"
  git -C "$REPO_ROOT" log --all --no-merges --extended-regexp \
    --grep="${id}([^0-9_]|\$)" --pretty=format:'%H' 2>/dev/null || true
}

commit_files() {
  local sha="$1"
  if git -C "$REPO_ROOT" rev-parse --verify -q "${sha}~1" >/dev/null 2>&1; then
    git -C "$REPO_ROOT" diff --name-only "${sha}~1..${sha}" 2>/dev/null || true
  else
    # Root commit -- no parent to diff against.
    git -C "$REPO_ROOT" diff-tree --no-commit-id --name-only -r "$sha" 2>/dev/null || true
  fi
}

# Prints the sorted-unique union of every file touched by every commit
# matching this ticket id. Empty output means zero matched commits.
collect_touched_files() {
  local id="$1"
  local shas sha
  shas="$(commits_for_ticket "$id")"
  [ -n "$shas" ] || return 0
  while IFS= read -r sha; do
    [ -n "$sha" ] || continue
    commit_files "$sha"
  done <<< "$shas" | sort -u
}

# True (0) iff every line of $1 (touched files, newline-separated) is an
# exact-line member of $DIFF_FILE.
is_fully_covered() {
  local touched="$1"
  local line
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    grep -qxF -- "$line" "$DIFF_FILE" || return 1
  done <<< "$touched"
  return 0
}

# -----------------------------------------------------------------------------
# Ticket enumeration + processing
# -----------------------------------------------------------------------------

MERGED_COUNT=0
CHECKED_COUNT=0
ERROR_OCCURRED=0

process_ticket_dir() {
  local dir="$1"
  [ -d "$dir" ] || return 0

  local file id status
  while IFS= read -r -d '' file; do
    id="$(trim "$(read_frontmatter_field "$file" "id")")"
    status="$(trim "$(read_frontmatter_field "$file" "status")")"

    if [ -z "$id" ]; then
      log "WARNING: no 'id' frontmatter field found in $file -- skipping"
      continue
    fi

    if [ "$status" = "Merged" ]; then
      log "$id: already Merged -- skip (idempotent no-op)"
      continue
    fi

    case "$status" in
      Done|Passed|"Passed with remarks") ;;
      *) continue ;;  # not a closed ticket -- not eligible for Merged
    esac

    CHECKED_COUNT=$((CHECKED_COUNT + 1))

    local touched touched_scoped
    touched="$(collect_touched_files "$id")"

    if [ -z "$touched" ]; then
      log "$id: zero matched EST-tagged commits -- left unchanged"
      continue
    fi

    # Scope to COPY_SET before the coverage check -- see the COPY_SET
    # section above for why (a ticket's own board-status commit touches a
    # project/board/... path that /self-sync never mirrors and that can
    # never appear in the diff; comparing the unfiltered union would make
    # every real ticket permanently uncoverable).
    touched_scoped="$(filter_to_copy_set "$touched")"

    if [ -z "$touched_scoped" ]; then
      log "$id: matched commits exist but none touch a COPY_SET path -- nothing for /self-sync to ever mirror for this ticket, left unchanged"
      continue
    fi

    if is_fully_covered "$touched_scoped"; then
      log "$id: fully covered by sync diff -- writing status: Merged ($file)"
      # Wrapped command is run via `bash <script>` rather than direct exec,
      # matching close-story/SKILL.md's own invocation convention -- this
      # avoids any dependency on update-task-frontmatter.sh's own execute
      # bit, which it does not carry in this repo today.
      if ! "$WITH_LOCK_SCRIPT" "$file" -- bash "$UPDATE_FRONTMATTER_SCRIPT" "$file" status Merged; then
        log "ERROR: failed to write status: Merged for $id ($file)"
        ERROR_OCCURRED=1
        continue
      fi
      MERGED_COUNT=$((MERGED_COUNT + 1))
    else
      log "$id: partially covered (or not covered) by sync diff -- left unchanged"
    fi
  done < <(find "$dir" -maxdepth 1 -type f -name '*.md' -print0 | sort -z)
}

if [ "$DIFF_LINE_COUNT" -eq 0 ]; then
  log "sync diff is empty -- nothing can be fully covered, skipping ticket enumeration (zero board writes)"
else
  process_ticket_dir "$TASKS_DIR"
  process_ticket_dir "$STORIES_DIR"
fi

if [ "$ERROR_OCCURRED" -ne 0 ]; then
  die "one or more status writes failed -- $TAG_NAME marker NOT advanced; rerun after resolving the write failure"
fi

log "checked $CHECKED_COUNT closed ticket(s), marked $MERGED_COUNT as Merged"

# -----------------------------------------------------------------------------
# Advance the last-self-sync marker
#
# Only reached once the entire enumeration loop above has completed with
# zero errors. `-f` (force-move) uniformly handles both "tag already
# existed at an older SHA" and "tag was just bootstrapped by
# compute-sync-diff.sh during this same run" without branching on which
# case occurred.
# -----------------------------------------------------------------------------

HEAD_SHA="$(git -C "$REPO_ROOT" rev-parse HEAD)"
git -C "$REPO_ROOT" tag -f "$TAG_NAME" "$HEAD_SHA" >/dev/null
log "advanced $TAG_NAME marker to $HEAD_SHA"

exit 0
