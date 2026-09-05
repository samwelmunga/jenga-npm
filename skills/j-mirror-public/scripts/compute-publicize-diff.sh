#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# skills/j-mirror-public/scripts/compute-publicize-diff.sh
#
# Computes "what changed in the public mirror scratch worktree between two
# given SHAs" — the input E51_S03_T02 needs to decide which closed tickets'
# files all shipped in a given /mirror-public run and should therefore be
# marked `Publicized`.
#
# Unlike skills/self-sync/scripts/compute-sync-diff.sh (E51_S02_T01), this
# script does NOT own or manage any marker tag. mirror.sh already maintains
# its own `last-mirror-sync` tag inside the scratch clone
# ($WORKTREE_PATH) — reading it near the top of a run (MARKER_SHA) and
# advancing it (`git tag -f last-mirror-sync HEAD`) right after the squash
# commit, at the very end of a successful run. This script's only job is
# the diff arithmetic between two SHAs it is handed by its caller; it never
# reads, creates, or advances refs/tags/last-mirror-sync itself.
#
# Arguments:
#   <old-marker-sha>  The prior last-mirror-sync SHA, or an empty string
#                      ("") if there was no prior marker (first-run/
#                      bootstrap case — mirrors mirror.sh's own "no marker
#                      yet" handling).
#   <new-sha>          The SHA to diff up to (required, must resolve to a
#                      commit in the scratch worktree).
#
# Behavior:
#   - Empty <old-marker-sha>: there is no prior point to diff from, so the
#     whole tree at <new-sha> is, by definition, everything this run
#     shipped. Prints `git ls-tree -r --name-only <new-sha>` (a full-tree
#     listing), NOT a diff against nothing.
#   - Non-empty <old-marker-sha>: prints
#     `git diff --name-only <old-marker-sha> <new-sha>`, one changed path
#     per line.
#
# Worktree resolution: reads skills/j-mirror-public/assets/config.json's
# worktreePath field using the exact same resolution logic as mirror.sh
# (symlink-resolved SCRIPT_DIR -> SKILL_DIR -> REPO_ROOT via git, jq-first
# with a python3 fallback, relative-vs-absolute path handling) so this
# script can never resolve a different worktree path than mirror.sh itself
# would for the same repo state. This is deliberate duplication of that
# small resolution block rather than a shared library, matching the
# existing precedent set by compute-sync-diff.sh's own standalone
# repo-root resolution.
#
# Output contract:
#   stdout — machine-parseable: one path per line, nothing else.
#   stderr — all human-readable log/diagnostic output.
#
# Exit codes:
#   0  success (diff or full-tree listing printed, including an empty result)
#   1  error (see stderr message)
#
# This task does not wire this script into mirror.sh — that is
# E51_S03_T04's job. This script is written to be independently testable
# with explicit SHA arguments.
# ---------------------------------------------------------------------------

set -euo pipefail
IFS=$'\n\t'

# -----------------------------------------------------------------------------
# Helpers
# -----------------------------------------------------------------------------

die() {
  printf 'compute-publicize-diff.sh: error: %s\n' "$*" >&2
  exit 1
}

log() {
  printf 'compute-publicize-diff.sh: %s\n' "$*" >&2
}

usage() {
  cat <<'EOF'
Usage: compute-publicize-diff.sh <old-marker-sha|""> <new-sha>

Prints the paths that changed between <old-marker-sha> and <new-sha> in the
mirror-public scratch worktree, one path per line on stdout. If
<old-marker-sha> is an empty string, prints a full-tree listing at
<new-sha> instead (bootstrap/first-run case — there is no prior point to
diff from).

This script never reads, creates, or advances the last-mirror-sync tag —
mirror.sh already owns that tag's full lifecycle. It only operates on the
two SHA values it is given.

All log output goes to stderr; stdout carries only the path list, so it can
be consumed directly by a downstream script.
EOF
}

# -----------------------------------------------------------------------------
# Parse arguments
# -----------------------------------------------------------------------------

if [ $# -eq 1 ] && { [ "$1" = "-h" ] || [ "$1" = "--help" ]; }; then
  usage
  exit 0
fi

if [ $# -ne 2 ]; then
  usage >&2
  die "expected exactly 2 arguments (old-marker-sha, new-sha), got $#"
fi

OLD_SHA="$1"
NEW_SHA="$2"

[ -n "$NEW_SHA" ] || die "<new-sha> must not be empty"

# -----------------------------------------------------------------------------
# Locate script + repo root
#
# Same symlink-resolution + repo-root derivation pattern as
# skills/j-mirror-public/scripts/mirror.sh, so this script behaves identically
# whether invoked directly or via a symlink.
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
SKILL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

REPO_ROOT="$(git -C "$SKILL_DIR" rev-parse --show-toplevel 2>/dev/null || true)"
[ -n "$REPO_ROOT" ] || die "could not locate repo root (git rev-parse failed from $SKILL_DIR)"

CONFIG_FILE="$SKILL_DIR/assets/config.json"
[ -f "$CONFIG_FILE" ] || die "config not found: $CONFIG_FILE"

# -----------------------------------------------------------------------------
# Load config (jq preferred, python3 fallback) — same helper as mirror.sh
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

WORKTREE_REL="$(read_config_field worktreePath)" || die "config missing worktreePath"

# Resolve worktree path against repo root if it's relative — same logic as
# mirror.sh.
case "$WORKTREE_REL" in
  /*) WORKTREE_PATH="$WORKTREE_REL" ;;
  *)  WORKTREE_PATH="$REPO_ROOT/$WORKTREE_REL" ;;
esac

[ -d "$WORKTREE_PATH/.git" ] || die "scratch worktree not found or not a git repo: $WORKTREE_PATH (run mirror.sh at least once first)"

log "repo root:      $REPO_ROOT"
log "worktree path:  $WORKTREE_PATH"
log "old marker sha: ${OLD_SHA:-<empty — bootstrap/first-run>}"
log "new sha:        $NEW_SHA"

# -----------------------------------------------------------------------------
# Validate <new-sha> resolves to a commit in the scratch worktree
# -----------------------------------------------------------------------------

git -C "$WORKTREE_PATH" rev-parse --verify -q "${NEW_SHA}^{commit}" >/dev/null 2>&1 \
  || die "<new-sha> ($NEW_SHA) does not resolve to a commit in $WORKTREE_PATH"

# -----------------------------------------------------------------------------
# Empty old marker: no prior point to diff from — full-tree listing at
# <new-sha> is, by definition, everything this run shipped.
# -----------------------------------------------------------------------------

if [ -z "$OLD_SHA" ]; then
  log "no old marker sha supplied — printing full-tree listing at $NEW_SHA (bootstrap case)"
  git -C "$WORKTREE_PATH" ls-tree -r --name-only "$NEW_SHA"
  exit 0
fi

# -----------------------------------------------------------------------------
# Non-empty old marker: validate it too, then diff.
# -----------------------------------------------------------------------------

git -C "$WORKTREE_PATH" rev-parse --verify -q "${OLD_SHA}^{commit}" >/dev/null 2>&1 \
  || die "<old-marker-sha> ($OLD_SHA) does not resolve to a commit in $WORKTREE_PATH"

log "diffing $OLD_SHA..$NEW_SHA"
git -C "$WORKTREE_PATH" diff --name-only "$OLD_SHA" "$NEW_SHA"
