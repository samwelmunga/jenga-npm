#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# scripts/compute-deploy-reconcile.sh
#
# Computes "which public jenga-npm stage/prod tags has this private repo not
# yet reconciled, and what private-repo SHA does each one resolve to" — the
# read-only discovery half of E51_S05's "Deployed to Stage"/"Deployed to
# Prod" pipeline. E51_S05_T02 consumes this script's stdout to do the actual
# ticket-matching and board-status writes; this script never touches the
# board and never advances the marker file itself.
#
# Shared, non-skill-scoped location (like scripts/board_resolver.sh and
# scripts/validate-board.sh): both /self-sync and /status will invoke this
# script (E51_S05_T03, not yet dispatched), so it lives directly under
# scripts/ rather than duplicated into one skill's scripts/ folder.
#
# Reads:
#   skills/mirror-public/assets/config.json
#     - publicRepoUrl  : URL of the public downstream repo (unauthenticated,
#                        public repo — no credential required)
#     - worktreePath   : scratch worktree path (relative to repo root) that
#                        /mirror-public maintains, reused here read-only if
#                        present
#   project/data/deploy-reconcile-marker.json (read-only, via
#     scripts/with-lock.sh — same locking discipline already required for
#     project/queue/capacity-block-state-*.json)
#     - reconciled_tags : array of tag names already processed by a prior
#                         E51_S05_T02 run. Any tag NOT in this array is
#                         reported by this script. This script NEVER writes
#                         this file — advancing it is E51_S05_T02's job,
#                         only after its own board-write pass succeeds.
#
# Tag discovery:
#   - If the mirror-public scratch clone at <worktreePath> already exists on
#     disk (i.e. /mirror-public has run in this environment before), reuse
#     it: `git -C <worktree> fetch --tags origin` (read-only), then list
#     local tags.
#   - Otherwise, fall back to `git ls-remote --tags <publicRepoUrl>` for
#     discovery, then a per-tag `git fetch --depth 1 <publicRepoUrl>
#     refs/tags/<tag>:refs/tags/<tag>` into a throwaway scratch bare repo to
#     pull just that tag's commit object. Both paths are unauthenticated
#     (jenga-npm is public).
#
# Tags are filtered to exactly two shapes (anything else is silently
# ignored, not an error):
#   vX.Y.Z-stage   -> tag_type "stage"
#   vX.Y.Z         -> tag_type "prod"
#
# Source-Commit resolution: for each not-yet-reconciled, pattern-matching
# tag, `git log -1 --format=%B <tag>` is run against whichever clone/fetch
# supplied that tag's commit, and the `Source-Commit: <full-sha>` trailer
# line is extracted — the exact trailer key/format
# skills/mirror-public/scripts/mirror.sh already writes
# (`COMMIT_TRAILER="Source-Commit: $PRIVATE_FULL_SHA"`, a 40-char lowercase
# hex SHA). A tag whose commit has no such trailer is skipped with a stderr
# warning, not a script error (defensive — should not happen given
# E51_S04_T01's implementation, but a hand-pushed or malformed tag is
# possible).
#
# This script does NOT write to project/data/deploy-reconcile-marker.json.
# It only computes and prints — matching the established deferred-write
# convention already used by compute-sync-diff.sh (self-sync) and
# compute-publicize-diff.sh (mirror-public).
#
# Graceful degradation: if the public repo is unreachable (any non-zero exit
# from the discovery ls-remote/fetch calls), this is NEVER a fatal error —
# log a warning to stderr and exit 0 with empty stdout, so callers see "ran,
# nothing to reconcile" and "network unreachable" identically.
#
# Output contract:
#   stdout — machine-parseable: one line per resolved, not-yet-reconciled
#            tag, tab-separated:
#              <tag_type>\t<version>\t<public_tag_name>\t<resolved_private_sha>
#            tag_type is "stage" or "prod". Nothing else on stdout, ever.
#   stderr — all human-readable log/diagnostic/warning output.
#
# Exit codes:
#   0  success — includes "nothing to reconcile" AND "network unreachable"
#   1  usage error / missing required config or script dependency
# ---------------------------------------------------------------------------

set -uo pipefail
IFS=$'\n\t'

# -----------------------------------------------------------------------------
# Helpers
# -----------------------------------------------------------------------------

die() {
  printf 'compute-deploy-reconcile.sh: error: %s\n' "$*" >&2
  exit 1
}

log() {
  printf 'compute-deploy-reconcile.sh: %s\n' "$*" >&2
}

warn() {
  printf 'compute-deploy-reconcile.sh: WARNING: %s\n' "$*" >&2
}

usage() {
  cat <<'EOF'
Usage: compute-deploy-reconcile.sh [-h|--help]

Discovers vX.Y.Z-stage / vX.Y.Z tags on the public jenga-npm repo that are
not yet recorded in project/data/deploy-reconcile-marker.json's
reconciled_tags array, resolves each to a private-repo SHA via its commit's
Source-Commit: trailer, and prints one TSV line per resolved tag to stdout:

  <tag_type>\t<version>\t<public_tag_name>\t<resolved_private_sha>

All logging goes to stderr. If the public repo is unreachable, this script
logs a warning and exits 0 with empty stdout (never a hard error). This
script never writes project/data/deploy-reconcile-marker.json — advancing it
is the caller's (E51_S05_T02's) responsibility.
EOF
}

if [ $# -gt 0 ]; then
  case "$1" in
    -h|--help) usage; exit 0 ;;
    *) usage >&2; die "unknown argument: $1" ;;
  esac
fi

# -----------------------------------------------------------------------------
# Locate script + repo root (same symlink-resolution + repo-root derivation
# pattern as skills/mirror-public/scripts/mirror.sh and
# skills/self-sync/scripts/compute-sync-diff.sh).
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

CONFIG_FILE="$REPO_ROOT/skills/mirror-public/assets/config.json"
[ -f "$CONFIG_FILE" ] || die "config not found: $CONFIG_FILE"

WITH_LOCK_SCRIPT="$REPO_ROOT/scripts/with-lock.sh"
[ -f "$WITH_LOCK_SCRIPT" ] || die "expected script not found: $WITH_LOCK_SCRIPT"

MARKER_FILE="$REPO_ROOT/project/data/deploy-reconcile-marker.json"

# -----------------------------------------------------------------------------
# Config field reader (jq preferred, python3 fallback) — same helper pattern
# as mirror.sh / compute-publicize-diff.sh.
# -----------------------------------------------------------------------------

read_config_field() {
  local field="$1"
  if command -v jq >/dev/null 2>&1; then
    jq -er --arg f "$field" '.[$f]' "$CONFIG_FILE" 2>/dev/null || return 1
  elif command -v python3 >/dev/null 2>&1; then
    python3 - "$CONFIG_FILE" "$field" <<'PY' || return 1
import json, sys
path, field = sys.argv[1], sys.argv[2]
with open(path) as fh:
    data = json.load(fh)
if field not in data:
    sys.exit(1)
sys.stdout.write(str(data[field]))
PY
  else
    die "neither jq nor python3 available to parse $CONFIG_FILE"
  fi
}

PUBLIC_URL="$(read_config_field publicRepoUrl)" || die "config missing publicRepoUrl"
WORKTREE_REL="$(read_config_field worktreePath)" || die "config missing worktreePath"

# Env override for local-remote testing, mirroring mirror.sh's own
# MIRROR_PUBLIC_URL_OVERRIDE convention (reused verbatim here rather than
# inventing a second override variable name).
if [ -n "${MIRROR_PUBLIC_URL_OVERRIDE:-}" ]; then
  log "using MIRROR_PUBLIC_URL_OVERRIDE=$MIRROR_PUBLIC_URL_OVERRIDE (config value ignored)"
  PUBLIC_URL="$MIRROR_PUBLIC_URL_OVERRIDE"
fi

case "$WORKTREE_REL" in
  /*) WORKTREE_PATH="$WORKTREE_REL" ;;
  *)  WORKTREE_PATH="$REPO_ROOT/$WORKTREE_REL" ;;
esac

log "repo root:      $REPO_ROOT"
log "public URL:     $PUBLIC_URL"
log "worktree path:  $WORKTREE_PATH"
log "marker file:    $MARKER_FILE"

# -----------------------------------------------------------------------------
# Read the marker file's reconciled_tags array (read-only, lock-protected).
#
# Absence of the marker file is not an error — it means nothing has been
# reconciled yet (empty set). This script never creates or writes the file;
# that stays E51_S05_T02's job.
# -----------------------------------------------------------------------------

read_reconciled_tags() {
  if [ ! -f "$MARKER_FILE" ]; then
    log "marker file not found at $MARKER_FILE — treating reconciled_tags as empty"
    return 0
  fi

  local reader_result
  if command -v jq >/dev/null 2>&1; then
    reader_result="$("$WITH_LOCK_SCRIPT" "$MARKER_FILE" -- jq -r '.reconciled_tags[]? // empty' "$MARKER_FILE" 2>/dev/null)" || {
      warn "failed to read $MARKER_FILE under lock — treating reconciled_tags as empty"
      return 0
    }
  elif command -v python3 >/dev/null 2>&1; then
    reader_result="$("$WITH_LOCK_SCRIPT" "$MARKER_FILE" -- python3 -c '
import json, sys
try:
    with open(sys.argv[1]) as fh:
        data = json.load(fh)
    for t in (data.get("reconciled_tags") or []):
        print(t)
except Exception:
    pass
' "$MARKER_FILE" 2>/dev/null)" || {
      warn "failed to read $MARKER_FILE under lock — treating reconciled_tags as empty"
      return 0
    }
  else
    die "neither jq nor python3 available to parse $MARKER_FILE"
  fi

  printf '%s' "$reader_result"
}

RECONCILED_TAGS_RAW="$(read_reconciled_tags)"

is_already_reconciled() {
  local tag="$1"
  [ -n "$RECONCILED_TAGS_RAW" ] || return 1
  local line
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    if [ "$line" = "$tag" ]; then
      return 0
    fi
  done <<EOF
$RECONCILED_TAGS_RAW
EOF
  return 1
}

# -----------------------------------------------------------------------------
# Tag pattern filter — only vX.Y.Z-stage or vX.Y.Z survive. Anything else
# (e.g. last-mirror-sync, pre-force-*, or a malformed tag) is silently
# ignored, not an error.
#
# Prints "stage" or "prod" on match (to stdout of this function call), or
# nothing + returns 1 if the tag doesn't match either shape.
# -----------------------------------------------------------------------------

classify_tag() {
  local tag="$1"
  case "$tag" in
    v[0-9]*.[0-9]*.[0-9]*-stage)
      # Defensive: reject anything with characters beyond digits/dots in the
      # numeric portion (e.g. v1.2.3rc1-stage) by re-validating with a
      # stricter regex via case globbing is awkward, so use a regex here.
      if [[ "$tag" =~ ^v[0-9]+\.[0-9]+\.[0-9]+-stage$ ]]; then
        printf 'stage\n'
        return 0
      fi
      ;;
    v[0-9]*.[0-9]*.[0-9]*)
      if [[ "$tag" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        printf 'prod\n'
        return 0
      fi
      ;;
  esac
  return 1
}

version_from_tag() {
  local tag="$1"
  local ver="$tag"
  ver="${ver#v}"
  ver="${ver%-stage}"
  printf '%s\n' "$ver"
}

# -----------------------------------------------------------------------------
# Source-Commit trailer extraction — reads `git log -1 --format=%B <tag>`
# against the given git dir and greps for the exact trailer key/format
# mirror.sh writes: `Source-Commit: <40-char-lowercase-hex-sha>`. Prints the
# SHA on match, returns 1 (no output) if absent.
# -----------------------------------------------------------------------------

extract_source_commit() {
  local git_dir="$1" tag="$2"
  local body sha
  body="$(git -C "$git_dir" log -1 --format=%B "$tag" 2>/dev/null)" || return 1
  sha="$(printf '%s\n' "$body" | grep -E '^Source-Commit: [0-9a-f]{40}$' | head -1 | sed 's/^Source-Commit: //')"
  [ -n "$sha" ] || return 1
  printf '%s\n' "$sha"
}

# -----------------------------------------------------------------------------
# Discovery + resolution
#
# Two paths:
#   A) Reuse existing mirror-public scratch clone (fetch --tags, read local
#      tags directly from it).
#   B) Bootstrap path: ls-remote for discovery, then a throwaway scratch bare
#      repo + per-tag shallow fetch to pull just the commit object needed.
#
# Any network failure in either path triggers graceful degradation (warn +
# exit 0 + empty stdout) rather than a hard error.
# -----------------------------------------------------------------------------

RESULTS=()  # each entry: "tag_type<TAB>version<TAB>tag<TAB>sha"

process_candidate_tag() {
  local git_dir="$1" tag="$2"
  local tag_type
  tag_type="$(classify_tag "$tag")" || return 0   # not a recognized shape — silently skip

  if is_already_reconciled "$tag"; then
    log "skip (already reconciled): $tag"
    return 0
  fi

  local sha
  if ! sha="$(extract_source_commit "$git_dir" "$tag")"; then
    warn "tag '$tag' has no Source-Commit: trailer on its commit — skipping"
    return 0
  fi

  local version
  version="$(version_from_tag "$tag")"
  RESULTS+=("$tag_type"$'\t'"$version"$'\t'"$tag"$'\t'"$sha")
  log "resolved: $tag_type $version $tag -> $sha"
}

SCRATCH_BARE=""
cleanup_scratch() {
  if [ -n "$SCRATCH_BARE" ] && [ -d "$SCRATCH_BARE" ]; then
    rm -rf "$SCRATCH_BARE"
  fi
}
trap cleanup_scratch EXIT

if [ -d "$WORKTREE_PATH/.git" ]; then
  log "reusing existing mirror-public scratch clone at $WORKTREE_PATH"
  if ! git -C "$WORKTREE_PATH" fetch --tags origin >/dev/null 2>&1; then
    warn "could not reach public repo $PUBLIC_URL (fetch --tags failed against $WORKTREE_PATH); skipping deploy-reconcile this run."
    exit 0
  fi

  TAG_LIST="$(git -C "$WORKTREE_PATH" tag -l 'v*' 2>/dev/null || true)"
  while IFS= read -r tag; do
    [ -n "$tag" ] || continue
    process_candidate_tag "$WORKTREE_PATH" "$tag"
  done <<EOF
$TAG_LIST
EOF

else
  log "no existing scratch clone at $WORKTREE_PATH — falling back to ls-remote + targeted fetch"

  LS_REMOTE_OUTPUT="$(git ls-remote --tags "$PUBLIC_URL" 2>/dev/null)"
  LS_REMOTE_STATUS=$?
  if [ "$LS_REMOTE_STATUS" -ne 0 ]; then
    warn "could not reach public repo $PUBLIC_URL; skipping deploy-reconcile this run."
    exit 0
  fi

  # Parse refs/tags/<name> out of each line, stripping any ^{} peeled
  # dereference suffix (annotated-tag dereference entries), and dedupe.
  CANDIDATE_TAGS="$(printf '%s\n' "$LS_REMOTE_OUTPUT" \
    | awk '{print $2}' \
    | sed -n 's#^refs/tags/##p' \
    | sed 's/\^{}$//' \
    | sort -u)"

  if [ -z "$CANDIDATE_TAGS" ]; then
    log "no tags found on public repo"
    exit 0
  fi

  SCRATCH_BARE="$(mktemp -d -t deploy-reconcile-scratch.XXXXXX)"
  git init -q --bare "$SCRATCH_BARE"

  FETCH_FAILED=0
  while IFS= read -r tag; do
    [ -n "$tag" ] || continue

    # Only bother fetching tags that match the allowed shapes AND are not
    # already reconciled — minimizes network calls in the bootstrap path.
    tag_type="$(classify_tag "$tag")" || continue
    if is_already_reconciled "$tag"; then
      log "skip (already reconciled): $tag"
      continue
    fi

    if ! git -C "$SCRATCH_BARE" fetch --depth 1 "$PUBLIC_URL" "refs/tags/$tag:refs/tags/$tag" >/dev/null 2>&1; then
      warn "could not reach public repo $PUBLIC_URL (targeted fetch of tag '$tag' failed); skipping deploy-reconcile this run."
      FETCH_FAILED=1
      break
    fi

    process_candidate_tag "$SCRATCH_BARE" "$tag"
  done <<EOF
$CANDIDATE_TAGS
EOF

  if [ "$FETCH_FAILED" -eq 1 ]; then
    exit 0
  fi
fi

# -----------------------------------------------------------------------------
# Emit results
# -----------------------------------------------------------------------------

if [ "${#RESULTS[@]}" -eq 0 ]; then
  log "nothing to reconcile"
  exit 0
fi

for line in "${RESULTS[@]}"; do
  printf '%s\n' "$line"
done

exit 0
