#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# scripts/mark-deployed.sh
#
# Given E51_S05_T01's compute-deploy-reconcile.sh TSV output (one line per
# resolved, not-yet-reconciled public tag:
#   <tag_type>\t<version>\t<public_tag_name>\t<resolved_private_sha>
# where tag_type is "stage" or "prod"), this script:
#   1. Enumerates board tickets (tasks + stories) currently at
#      status: Publicized or status: Deployed to Stage -- never Pending,
#      Done, Passed, etc. directly (per E51's own DoD: "only Publicized
#      tickets are eligible for Deployed to Stage -> Deployed to Prod").
#   2. Derives each eligible ticket's matched EST-tagged commit SHAs (and,
#      for parity/logging, their unioned touched-file list) using the
#      identical anchored-grep + union technique
#      skills/self-sync/scripts/mark-merged.sh already implements.
#   3. Checks ANCESTRY, not diff-membership: a ticket is "covered" by a tag
#      only when EVERY one of its matched commits is an ancestor of that
#      tag's resolved_private_sha (git merge-base --is-ancestor). A tag
#      represents a cumulative release, so "has this ticket's work already
#      landed by the time this commit was tagged" is the correct question --
#      unlike Merged/Publicized, which check "did this specific sync/mirror
#      run's diff include these files".
#   4. Writes status via scripts/with-lock.sh + close-story's existing
#      update-task-frontmatter.sh (reused, not reimplemented):
#        stage tag: Publicized -> Deployed to Stage. Already at
#                   Deployed to Stage or Deployed to Prod -> unchanged
#                   (idempotent, never demotes Prod back to Stage).
#        prod tag:  Publicized OR Deployed to Stage -> Deployed to Prod
#                   directly (never left at Stage alongside a separate Prod
#                   entry). Already at Deployed to Prod -> unchanged.
#      When (and only when) a ticket is set to Deployed to Prod, this script
#      ALSO writes date_deployed_prod: <today, ISO 8601> to the same
#      ticket's frontmatter, inside the SAME locked write window -- one
#      with-lock.sh call wrapping a `bash -c '... status "Deployed to
#      Prod" && ... date_deployed_prod <today>'`, never two separately
#      locked writes.
#   5. Processing order: all stage-type tag lines first, then all prod-type
#      tag lines -- so a same-run prod tag can promote a ticket the stage
#      pass in this same run just touched. Ticket status is re-read fresh
#      for every tag line processed (never cached across tag iterations),
#      since an earlier tag in the same run may have already changed it.
#   6. Partial or zero coverage -> ticket left unchanged, no error. A ticket
#      with zero matched commits is left unchanged (nothing to compare).
#   7. Only after this run's tag lines have each been attempted, advances
#      project/data/deploy-reconcile-marker.json's reconciled_tags array --
#      but PER-TAG, not all-or-nothing: a tag is appended only if every
#      board write attempted while processing it succeeded. A tag that hit
#      a write failure (e.g. a with-lock.sh timeout on one ticket's board
#      file) is NOT appended, so a future run retries exactly that tag,
#      while OTHER tags in the same run that fully succeeded are still
#      recorded. This is a deliberate, finer-grained deviation from
#      mark-merged.sh's all-or-nothing marker advancement, per this task's
#      own spec (a single run may resolve several tags at once, and one
#      tag's failure should not force every sibling tag to be redone).
#
# Marker file: project/data/deploy-reconcile-marker.json. Does not exist on
# disk yet as of this script's authoring -- created (seeded
# {"reconciled_tags": []}) on first successful append, never on a
# nothing-to-append run. Read-side of this file is compute-deploy-
# reconcile.sh's job (already implemented, read-only, lock-protected); this
# script owns the write side exclusively.
#
# Input source (documented interface -- caller's choice of any one of),
# mirroring mark-merged.sh's own --diff-file / --stdin / default convention:
#   --diff-file <path>   Read TSV lines from a file (primarily for
#                         testability -- feed a synthetic input without a
#                         real compute-deploy-reconcile.sh run).
#   --stdin               Explicitly read TSV lines from stdin, e.g.
#                         `compute-deploy-reconcile.sh | mark-deployed.sh
#                         --stdin`. Not auto-detected via a `[ ! -t 0 ]`
#                         check -- see mark-merged.sh's header for why a TTY
#                         check is unsafe for a subprocess-spawned caller.
#   (neither)              Default: invoke the sibling
#                         compute-deploy-reconcile.sh directly and use its
#                         stdout.
#
# Marker-file JSON read/write uses python3 directly (no jq path) --
# consistent with this repo's own scripts/validate-board.sh, which requires
# python3 unconditionally with no jq fallback at all. The frontmatter status
# writes below reuse update-task-frontmatter.sh (pure bash, no interpreter
# dependency), matching mark-merged.sh.
#
# Exit codes:
#   0  success -- every attempted board write succeeded (including the
#      "nothing to reconcile" / empty-input case)
#   1  one or more board writes failed during this run -- the tags NOT
#      affected by a failure were still recorded as reconciled; only the
#      failing tag(s) are left for a future retry. Not a hard abort: this
#      script always finishes processing every tag line in its input before
#      exiting.
# ---------------------------------------------------------------------------

set -uo pipefail
IFS=$'\n\t'

# -----------------------------------------------------------------------------
# Helpers
# -----------------------------------------------------------------------------

die() {
  printf 'mark-deployed.sh: error: %s\n' "$*" >&2
  exit 1
}

log() {
  printf 'mark-deployed.sh: %s\n' "$*" >&2
}

warn() {
  printf 'mark-deployed.sh: WARNING: %s\n' "$*" >&2
}

usage() {
  cat <<'EOF'
Usage: mark-deployed.sh [--diff-file <path> | --stdin] [-h|--help]

Reads TSV lines (tag_type<TAB>version<TAB>public_tag_name<TAB>resolved_private_sha)
as produced by scripts/compute-deploy-reconcile.sh, matches eligible board
tickets (status: Publicized or Deployed to Stage) by commit ancestry, writes
Deployed to Stage / Deployed to Prod status (plus date_deployed_prod on a
Prod write), and advances project/data/deploy-reconcile-marker.json's
reconciled_tags array for each tag line that completed with zero write
failures.

Input source (pick one; documented in the script header):
  --diff-file <path>   Read TSV lines from a file.
  --stdin               Explicitly read TSV lines from stdin (e.g.
                        `compute-deploy-reconcile.sh | mark-deployed.sh
                        --stdin`). Not auto-detected.
  (neither)              Default: invoke the sibling
                        compute-deploy-reconcile.sh.
EOF
}

INPUT_FILE_ARG=""
READ_STDIN=0

while [ $# -gt 0 ]; do
  case "$1" in
    --diff-file)
      [ $# -ge 2 ] || die "--diff-file requires a path argument"
      INPUT_FILE_ARG="$2"
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

if [ -n "$INPUT_FILE_ARG" ] && [ "$READ_STDIN" -eq 1 ]; then
  usage >&2
  die "--diff-file and --stdin are mutually exclusive"
fi

# -----------------------------------------------------------------------------
# Locate script + repo root (same symlink-resolution + repo-root derivation
# pattern as mark-merged.sh / compute-deploy-reconcile.sh).
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

COMPUTE_SCRIPT="$SCRIPT_DIR/compute-deploy-reconcile.sh"
WITH_LOCK_SCRIPT="$REPO_ROOT/scripts/with-lock.sh"
UPDATE_FRONTMATTER_SCRIPT="$REPO_ROOT/skills/close-story/scripts/update-task-frontmatter.sh"
MARKER_FILE="$REPO_ROOT/project/data/deploy-reconcile-marker.json"

[ -f "$WITH_LOCK_SCRIPT" ] || die "expected script not found: $WITH_LOCK_SCRIPT"
[ -f "$UPDATE_FRONTMATTER_SCRIPT" ] || die "expected script not found: $UPDATE_FRONTMATTER_SCRIPT"
command -v python3 >/dev/null 2>&1 || die "python3 not installed (required to read/write $MARKER_FILE)"

TASKS_DIR="$REPO_ROOT/project/board/tasks"
STORIES_DIR="$REPO_ROOT/project/board/stories"

# -----------------------------------------------------------------------------
# Resolve the input source into a materialised temp file.
# -----------------------------------------------------------------------------

INPUT_FILE="$(mktemp)"
CLEANUP_FILES=("$INPUT_FILE")
cleanup() {
  rm -f "${CLEANUP_FILES[@]}" 2>/dev/null || true
}
trap cleanup EXIT

if [ -n "$INPUT_FILE_ARG" ]; then
  [ -f "$INPUT_FILE_ARG" ] || die "--diff-file path not found: $INPUT_FILE_ARG"
  log "reading tag input from --diff-file: $INPUT_FILE_ARG"
  cp "$INPUT_FILE_ARG" "$INPUT_FILE"
elif [ "$READ_STDIN" -eq 1 ]; then
  log "reading tag input from stdin (--stdin)"
  cat > "$INPUT_FILE"
else
  [ -f "$COMPUTE_SCRIPT" ] || die "expected sibling script not found: $COMPUTE_SCRIPT"
  log "no --diff-file and no --stdin -- invoking compute-deploy-reconcile.sh"
  if ! "$COMPUTE_SCRIPT" > "$INPUT_FILE"; then
    die "compute-deploy-reconcile.sh failed"
  fi
fi

# Strip accidental blank lines (same rationale as mark-merged.sh: a
# genuinely-empty input must compare as zero-byte, not one blank line).
BLANK_STRIPPED="$(mktemp)"
CLEANUP_FILES+=("$BLANK_STRIPPED")
grep -v '^[[:space:]]*$' "$INPUT_FILE" > "$BLANK_STRIPPED" 2>/dev/null || true
mv "$BLANK_STRIPPED" "$INPUT_FILE"

LINE_COUNT="$(wc -l < "$INPUT_FILE" | tr -d '[:space:]')"
log "tag input contains $LINE_COUNT line(s)"

if [ "$LINE_COUNT" -eq 0 ]; then
  log "nothing to reconcile -- zero tag lines, zero board writes, marker not touched"
  exit 0
fi

# -----------------------------------------------------------------------------
# Parse TSV lines into stage/prod buckets, preserving input order within
# each bucket.
# -----------------------------------------------------------------------------

STAGE_LINES=()
PROD_LINES=()

while IFS=$'\t' read -r tag_type version tag_name sha; do
  [ -n "$tag_type" ] || continue
  case "$tag_type" in
    stage) STAGE_LINES+=("$tag_type"$'\t'"$version"$'\t'"$tag_name"$'\t'"$sha") ;;
    prod)  PROD_LINES+=("$tag_type"$'\t'"$version"$'\t'"$tag_name"$'\t'"$sha") ;;
    *) warn "unrecognized tag_type '$tag_type' on input line for tag '$tag_name' -- skipping this line entirely" ;;
  esac
done < "$INPUT_FILE"

log "parsed ${#STAGE_LINES[@]} stage line(s), ${#PROD_LINES[@]} prod line(s)"

# -----------------------------------------------------------------------------
# Frontmatter field reader + trim (identical to mark-merged.sh's own
# helpers -- small, tolerated duplication rather than a third shared-helper
# script for two ~10-line functions; this repo already tolerates the same
# duplication between mark-merged.sh and compute-deploy-reconcile.sh's own
# COPY_SET extraction).
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
  local s="$1"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  s="${s%\"}"; s="${s#\"}"
  s="${s%\'}"; s="${s#\'}"
  printf '%s' "$s"
}

# -----------------------------------------------------------------------------
# Commit-matching + ancestry check
# -----------------------------------------------------------------------------

# Prints newline-separated matched EST-tagged commit SHAs for a ticket id
# (anchored grep, identical to mark-merged.sh -- guards against a story id
# being a literal string prefix of its own tasks' ids). Empty output means
# zero matched commits.
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
    git -C "$REPO_ROOT" diff-tree --no-commit-id --name-only -r "$sha" 2>/dev/null || true
  fi
}

# Sorted-unique union of every file touched by every commit matching this
# ticket id. Kept for parity/logging with mark-merged.sh's derivation, even
# though the actual coverage decision below is ancestry-based, not
# diff-membership-based.
collect_touched_files() {
  local shas="$1" sha
  [ -n "$shas" ] || return 0
  while IFS= read -r sha; do
    [ -n "$sha" ] || continue
    commit_files "$sha"
  done <<< "$shas" | sort -u
}

# True (0) iff EVERY commit sha in $1 (newline-separated, non-empty) is an
# ancestor of $2 (the tag's resolved private SHA). A commit sha that cannot
# be resolved to an ancestry relationship (e.g. object graph oddity) counts
# as "not an ancestor" rather than a hard script error -- coverage simply
# fails closed for that ticket/tag pair, and the ticket is left unchanged.
all_ancestors_of() {
  local shas="$1" target_sha="$2" sha
  while IFS= read -r sha; do
    [ -n "$sha" ] || continue
    git -C "$REPO_ROOT" merge-base --is-ancestor "$sha" "$target_sha" 2>/dev/null || return 1
  done <<< "$shas"
  return 0
}

# -----------------------------------------------------------------------------
# Status write helpers
# -----------------------------------------------------------------------------

write_status() {
  local file="$1" new_status="$2"
  "$WITH_LOCK_SCRIPT" "$file" -- bash "$UPDATE_FRONTMATTER_SCRIPT" "$file" status "$new_status"
}

# Writes status: Deployed to Prod AND date_deployed_prod inside the SAME
# locked window -- one with-lock.sh call wrapping a bash -c that chains both
# update-task-frontmatter.sh invocations, never two separately-locked calls
# (so no observer can see the status flip without the date already present).
write_deployed_to_prod() {
  local file="$1" today="$2"
  # update-task-frontmatter.sh does not carry an execute bit in this repo
  # (same as mark-merged.sh's own documented reasoning) -- invoke it via
  # `bash "$1"` inside the bash -c, not a direct exec.
  "$WITH_LOCK_SCRIPT" "$file" -- bash -c \
    'bash "$1" "$2" status "Deployed to Prod" && bash "$1" "$2" date_deployed_prod "$3"' \
    _ "$UPDATE_FRONTMATTER_SCRIPT" "$file" "$today"
}

# -----------------------------------------------------------------------------
# Marker file read/write (python3-only, matching validate-board.sh's own
# unconditional python3 dependency -- no jq fallback needed here).
# -----------------------------------------------------------------------------

advance_marker() {
  # Filter out empty-string elements before counting: the call site passes
  # "${RECONCILED_OK[@]:-}", which (per bash's :- expansion on an empty
  # array) yields a single empty-string argument rather than zero
  # arguments when RECONCILED_OK has no elements. Without this filter, that
  # phantom empty string would be miscounted as one real tag and appended
  # to reconciled_tags as "" (an empty version-name entry).
  local -a tags=()
  local t
  for t in "$@"; do
    [ -n "$t" ] || continue
    tags+=("$t")
  done
  [ "${#tags[@]}" -gt 0 ] || { log "no tag(s) succeeded this run -- marker not advanced"; return 0; }

  mkdir -p "$(dirname "$MARKER_FILE")"

  if ! "$WITH_LOCK_SCRIPT" "$MARKER_FILE" -- python3 -c '
import json, sys

marker_file = sys.argv[1]
new_tags = sys.argv[2:]

try:
    with open(marker_file) as fh:
        data = json.load(fh)
except (FileNotFoundError, json.JSONDecodeError):
    data = {}

existing = data.get("reconciled_tags") or []
merged = list(existing)
for t in new_tags:
    if t not in merged:
        merged.append(t)
data["reconciled_tags"] = merged

with open(marker_file, "w") as fh:
    json.dump(data, fh, indent=2)
    fh.write("\n")
' "$MARKER_FILE" "${tags[@]}"; then
    warn "failed to advance $MARKER_FILE under lock -- reconciled tag(s) not recorded (will be reprocessed next run): ${tags[*]}"
    return 1
  fi

  log "advanced $MARKER_FILE: reconciled_tags += ${tags[*]}"
  return 0
}

# -----------------------------------------------------------------------------
# Ticket enumeration + per-tag processing
# -----------------------------------------------------------------------------

TAG_HAD_ERROR=0
STAGE_COUNT=0
PROD_COUNT=0
DATE_TODAY="$(date -u +%Y-%m-%d)"

# Processes every eligible ticket in $1 (TASKS_DIR or STORIES_DIR) against a
# single tag ($2=tag_type, $3=version, $4=tag_name, $5=sha). Sets
# TAG_HAD_ERROR=1 (never reset here -- caller resets per tag) if any write
# fails.
process_ticket_dir_for_tag() {
  local dir="$1" tag_type="$2" version="$3" tag_name="$4" sha="$5"
  [ -d "$dir" ] || return 0

  local file id status shas touched
  while IFS= read -r -d '' file; do
    id="$(trim "$(read_frontmatter_field "$file" "id")")"
    status="$(trim "$(read_frontmatter_field "$file" "status")")"

    [ -n "$id" ] || { log "WARNING: no 'id' frontmatter field found in $file -- skipping"; continue; }

    case "$status" in
      Publicized|"Deployed to Stage") ;;
      *) continue ;;  # not eligible for Deployed to Stage/Prod consideration
    esac

    shas="$(commits_for_ticket "$id")"
    if [ -z "$shas" ]; then
      log "$id: zero matched EST-tagged commits -- left unchanged (tag $tag_name)"
      continue
    fi

    touched="$(collect_touched_files "$shas")"
    log "$id: ${shas//$'\n'/,} matched commit(s), touching: ${touched:-<none>} (tag $tag_name)"

    if ! all_ancestors_of "$shas" "$sha"; then
      log "$id: not fully covered by tag $tag_name (some matched commit is not an ancestor of $sha) -- left unchanged"
      continue
    fi

    if [ "$tag_type" = "stage" ]; then
      if [ "$status" = "Publicized" ]; then
        log "$id: covered by stage tag $tag_name -- writing status: Deployed to Stage ($file)"
        if write_status "$file" "Deployed to Stage"; then
          STAGE_COUNT=$((STAGE_COUNT + 1))
        else
          log "ERROR: failed to write status: Deployed to Stage for $id ($file)"
          TAG_HAD_ERROR=1
        fi
      else
        log "$id: already at '$status' -- unchanged (stage tag $tag_name, idempotent no-op)"
      fi
    else
      # tag_type == prod
      if [ "$status" = "Publicized" ] || [ "$status" = "Deployed to Stage" ]; then
        log "$id: covered by prod tag $tag_name -- writing status: Deployed to Prod + date_deployed_prod ($file)"
        if write_deployed_to_prod "$file" "$DATE_TODAY"; then
          PROD_COUNT=$((PROD_COUNT + 1))
        else
          log "ERROR: failed to write status: Deployed to Prod / date_deployed_prod for $id ($file)"
          TAG_HAD_ERROR=1
        fi
      else
        log "$id: already at '$status' -- unchanged (prod tag $tag_name, idempotent no-op)"
      fi
    fi
  done < <(find "$dir" -maxdepth 1 -type f -name '*.md' -print0 | sort -z)
}

RECONCILED_OK=()
ANY_ERROR_OCCURRED=0

process_tag_line() {
  local line="$1"
  local tag_type version tag_name sha
  IFS=$'\t' read -r tag_type version tag_name sha <<< "$line"

  TAG_HAD_ERROR=0
  process_ticket_dir_for_tag "$TASKS_DIR" "$tag_type" "$version" "$tag_name" "$sha"
  process_ticket_dir_for_tag "$STORIES_DIR" "$tag_type" "$version" "$tag_name" "$sha"

  if [ "$TAG_HAD_ERROR" -eq 0 ]; then
    RECONCILED_OK+=("$tag_name")
  else
    ANY_ERROR_OCCURRED=1
    log "tag $tag_name ($tag_type $version) had one or more write failures -- will NOT be marked reconciled this run"
  fi
}

for line in "${STAGE_LINES[@]:-}"; do
  [ -n "$line" ] || continue
  process_tag_line "$line"
done

for line in "${PROD_LINES[@]:-}"; do
  [ -n "$line" ] || continue
  process_tag_line "$line"
done

log "processed ${#STAGE_LINES[@]} stage tag(s), ${#PROD_LINES[@]} prod tag(s); $STAGE_COUNT ticket(s) set to Deployed to Stage, $PROD_COUNT ticket(s) set to Deployed to Prod"

# -----------------------------------------------------------------------------
# Advance the marker -- only for tags that completed with zero write
# failures. A tag with a failure is simply omitted, so a future run
# re-discovers and retries it (compute-deploy-reconcile.sh reports any tag
# not yet in reconciled_tags).
# -----------------------------------------------------------------------------

if ! advance_marker "${RECONCILED_OK[@]:-}"; then
  ANY_ERROR_OCCURRED=1
fi

if [ "$ANY_ERROR_OCCURRED" -ne 0 ]; then
  log "completed with one or more failures -- see ERROR/WARNING lines above; affected tag(s) will be retried on a future run"
  exit 1
fi

exit 0
