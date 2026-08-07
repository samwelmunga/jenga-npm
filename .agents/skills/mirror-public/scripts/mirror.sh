#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# skills/mirror-public/scripts/mirror.sh
#
# One-way sync engine for /mirror-public.
#
# Reads: skills/mirror-public/assets/config.json
#          - publicRepoUrl   : URL of the public downstream repo
#          - defaultBranch   : branch to sync (typically "main")
#          - worktreePath    : scratch worktree path (relative to repo root)
#        .publicignore       : rsync blocklist (single source of truth for
#                              private-only paths — see T01)
#
# Flow:
#   1. Prepare a scratch clone of <publicRepoUrl> at <worktreePath>, checked
#      out to <defaultBranch> at the tip of origin/<defaultBranch>.
#   2. Safety-check origin/<defaultBranch> against the local `last-mirror-sync`
#      tag in the scratch clone. Abort if the public branch has diverged
#      unless --force is passed.
#   3. rsync the private repo root into the worktree, respecting
#      .publicignore and explicitly excluding .git/.
#   4. If nothing changed, exit 0 idempotently.
#   5. Otherwise squash everything into a single "chore(mirror): sync from
#      private at <short-sha> <UTC-timestamp>" commit with a
#      `Source-Commit: <full-sha>` trailer, advance the local marker tag,
#      and push origin/<defaultBranch>.
#   6. Print a summary (files-changed count, new commit SHA, remote branch,
#      public URL).
#
# Flags:
#   --dry-run   Read-only preview mode. Prepares the scratch worktree
#               (fetch+reset only — no rsync writes, no commit, no push),
#               then prints two labeled sections:
#                 - "Files that would ship" (from rsync --dry-run)
#                 - "Files that would be blocked" (candidates \ shipped)
#               Followed by totals and an explicit "dry run — no push" notice.
#   --force     Override the safety-abort when the public branch is ahead
#               of the recorded last mirror.
#   -h|--help   Print usage and exit.
#
# Env overrides:
#   MIRROR_PUBLIC_URL_OVERRIDE   Swap the configured publicRepoUrl at
#                                runtime (used for local-remote testing).
#
# The script NEVER modifies the private repo's .git/ or working tree.
# ---------------------------------------------------------------------------

set -euo pipefail
IFS=$'\n\t'

# -----------------------------------------------------------------------------
# Helpers
# -----------------------------------------------------------------------------

die() {
  printf 'mirror.sh: error: %s\n' "$*" >&2
  exit 1
}

log() {
  printf 'mirror.sh: %s\n' "$*"
}

usage() {
  cat <<'EOF'
Usage: mirror.sh [--dry-run] [--force] [-h|--help]

Options:
  --dry-run   Read-only preview. Prints the exact list of files that would
              ship and the list of files blocked by .publicignore, then
              exits with no commit and no push.
  --force     Override the safety abort when the public branch has moved
              since the last mirror.
  -h, --help  Show this message and exit.

Env:
  MIRROR_PUBLIC_URL_OVERRIDE  Override the configured publicRepoUrl.
EOF
}

# -----------------------------------------------------------------------------
# Locate script + repo root
# -----------------------------------------------------------------------------

SCRIPT_PATH="${BASH_SOURCE[0]}"
# Resolve symlinks to a real path so SCRIPT_DIR points at the on-disk file.
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
[ -n "$REPO_ROOT" ] || die "could not locate private repo root (git rev-parse failed from $SKILL_DIR)"

CONFIG_FILE="$SKILL_DIR/assets/config.json"
[ -f "$CONFIG_FILE" ] || die "config not found: $CONFIG_FILE"

PUBLICIGNORE="$REPO_ROOT/.publicignore"
[ -f "$PUBLICIGNORE" ] || die ".publicignore not found at $PUBLICIGNORE (should have been created in T01)"

# -----------------------------------------------------------------------------
# Parse flags
# -----------------------------------------------------------------------------

DRY_RUN=0
FORCE=0

while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY_RUN=1 ;;
    --force)   FORCE=1 ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; die "unknown argument: $1" ;;
  esac
  shift
done

# -----------------------------------------------------------------------------
# Load config (jq preferred, python3 fallback)
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
DEFAULT_BRANCH="$(read_config_field defaultBranch)" || die "config missing defaultBranch"
WORKTREE_REL="$(read_config_field worktreePath)" || die "config missing worktreePath"

# Env override for local-remote testing.
if [ -n "${MIRROR_PUBLIC_URL_OVERRIDE:-}" ]; then
  log "using MIRROR_PUBLIC_URL_OVERRIDE=$MIRROR_PUBLIC_URL_OVERRIDE (config value ignored)"
  PUBLIC_URL="$MIRROR_PUBLIC_URL_OVERRIDE"
fi

# Resolve worktree path against repo root if it's relative.
case "$WORKTREE_REL" in
  /*) WORKTREE_PATH="$WORKTREE_REL" ;;
  *)  WORKTREE_PATH="$REPO_ROOT/$WORKTREE_REL" ;;
esac

log "repo root:      $REPO_ROOT"
log "public URL:     $PUBLIC_URL"
log "default branch: $DEFAULT_BRANCH"
log "worktree path:  $WORKTREE_PATH"

# -----------------------------------------------------------------------------
# Prepare scratch worktree (clone if missing, fetch+reset if present)
# -----------------------------------------------------------------------------

mkdir -p "$(dirname "$WORKTREE_PATH")"

if [ ! -d "$WORKTREE_PATH/.git" ]; then
  log "cloning $PUBLIC_URL -> $WORKTREE_PATH (branch: $DEFAULT_BRANCH)"
  git clone --branch "$DEFAULT_BRANCH" --single-branch "$PUBLIC_URL" "$WORKTREE_PATH"
else
  log "refreshing existing scratch worktree at $WORKTREE_PATH"
  git -C "$WORKTREE_PATH" remote set-url origin "$PUBLIC_URL"
  git -C "$WORKTREE_PATH" fetch origin "$DEFAULT_BRANCH"
  git -C "$WORKTREE_PATH" checkout -B "$DEFAULT_BRANCH" "origin/$DEFAULT_BRANCH"
  git -C "$WORKTREE_PATH" reset --hard "origin/$DEFAULT_BRANCH"
  # Preserve the marker tag if it exists; -x would leave untracked scratch,
  # but -fd is enough because we hard-reset above.
  git -C "$WORKTREE_PATH" clean -fd
fi

# -----------------------------------------------------------------------------
# Safety check: last-mirror-sync tag vs origin/<branch>
# -----------------------------------------------------------------------------

MARKER_SHA="$(git -C "$WORKTREE_PATH" rev-parse -q --verify refs/tags/last-mirror-sync 2>/dev/null || true)"
REMOTE_HEAD="$(git -C "$WORKTREE_PATH" rev-parse "origin/$DEFAULT_BRANCH")"

if [ -z "$MARKER_SHA" ]; then
  log "no last-mirror-sync tag found (first mirror or wiped scratch) — proceeding"
elif [ "$MARKER_SHA" = "$REMOTE_HEAD" ]; then
  log "last-mirror-sync matches origin/$DEFAULT_BRANCH — safe to proceed"
else
  if [ "$FORCE" -eq 1 ]; then
    log "WARNING: origin/$DEFAULT_BRANCH ($REMOTE_HEAD) has moved past last-mirror-sync ($MARKER_SHA); proceeding due to --force"
  else
    die "origin/$DEFAULT_BRANCH ($REMOTE_HEAD) has moved past last-mirror-sync ($MARKER_SHA). The public repo has commits the mirror did not create. Re-run with --force to overwrite."
  fi
fi

command -v rsync >/dev/null 2>&1 || die "rsync not installed"

# -----------------------------------------------------------------------------
# --dry-run: full read-only preview
#
# Compute + print the exact "would ship" set (from rsync --dry-run --itemize)
# and the "would be blocked" set (git-tracked/untracked candidates minus the
# ship set). Zero rsync writes, zero commits, zero pushes.
# -----------------------------------------------------------------------------

if [ "$DRY_RUN" -eq 1 ]; then
  log "dry-run: computing ship + blocked sets (no rsync write, no commit, no push)"

  SHIP_LIST_FILE="$(mktemp -t mirror-ship.XXXXXX)"
  CANDIDATE_LIST_FILE="$(mktemp -t mirror-candidates.XXXXXX)"
  BLOCKED_LIST_FILE="$(mktemp -t mirror-blocked.XXXXXX)"
  # shellcheck disable=SC2064
  trap "rm -f '$SHIP_LIST_FILE' '$CANDIDATE_LIST_FILE' '$BLOCKED_LIST_FILE'" EXIT

  # 1. Ship list — rsync --dry-run --itemize-changes uses the SAME flag set as
  # the real run below, so the emitted transfer list is exactly what the real
  # run would transfer. Itemize flag format is 11 chars: YXcstpoguax
  #   Y (update type): >=receive, <=send, c=create local, h=hard link,
  #                    .=no update, *=message (e.g. deleting)
  #   X (file type):   f=file, d=directory, L=symlink, D=device, S=special
  # We keep any entry that transfers/creates a file OR a symlink OR a hardlink,
  # and drop directory-only entries (rsync recreates dirs implicitly) and any
  # attribute-only / deletion / message lines. This matches exactly what the
  # real rsync would push into the scratch worktree and therefore into the
  # public remote.
  rsync -a --delete \
    --exclude-from="$PUBLICIGNORE" \
    --exclude=".git" \
    --dry-run --itemize-changes --out-format='%i %n' \
    "$REPO_ROOT/" \
    "$WORKTREE_PATH/" \
    | awk '{
        flag = $1;
        first  = substr(flag, 1, 1);
        second = substr(flag, 2, 1);
        # Skip directories — public tree recreates them implicitly.
        if (second == "d") next;
        # Keep only entries that transfer or create a file/symlink/hardlink.
        keep = 0;
        if (first == ">" || first == "<") keep = 1;   # file transfer
        else if (first == "c" && second == "L") keep = 1;  # create symlink
        else if (first == "h") keep = 1;              # hard link
        if (!keep) next;
        # Rebuild path (everything after the flag token).
        $1 = "";
        sub(/^ /, "");
        # Strip trailing slash just in case (should only appear on dirs, which
        # we already skipped, but be defensive).
        sub(/\/$/, "");
        if (length($0) > 0) print $0;
      }' \
    | LC_ALL=C sort -u > "$SHIP_LIST_FILE"

  # 2. Candidate list — every tracked file plus every untracked-not-gitignored
  # file under the private repo root. This is the honest "what the maintainer
  # thinks of as the repo" set.
  git -C "$REPO_ROOT" ls-files -co --exclude-standard \
    | LC_ALL=C sort -u > "$CANDIDATE_LIST_FILE"

  # 3. Blocked = candidates \ shipped.
  LC_ALL=C comm -23 "$CANDIDATE_LIST_FILE" "$SHIP_LIST_FILE" > "$BLOCKED_LIST_FILE"

  SHIP_COUNT="$(wc -l < "$SHIP_LIST_FILE" | tr -d ' ')"
  BLOCKED_COUNT="$(wc -l < "$BLOCKED_LIST_FILE" | tr -d ' ')"

  printf '\n'
  printf '=== Files that would ship (%s) ===\n' "$SHIP_COUNT"
  if [ "$SHIP_COUNT" -eq 0 ]; then
    printf '  (none — public tree already matches private, post-blocklist)\n'
  else
    cat "$SHIP_LIST_FILE"
  fi

  printf '\n'
  printf '=== Files that would be blocked (%s) ===\n' "$BLOCKED_COUNT"
  if [ "$BLOCKED_COUNT" -eq 0 ]; then
    printf '  (none — .publicignore matched nothing under this repo)\n'
  else
    cat "$BLOCKED_LIST_FILE"
  fi

  printf '\n'
  printf '================ mirror-public dry-run summary ================\n'
  printf 'would ship    : %s files\n' "$SHIP_COUNT"
  printf 'would block   : %s files\n' "$BLOCKED_COUNT"
  printf 'public URL    : %s\n' "$PUBLIC_URL"
  printf 'remote branch : %s\n' "$DEFAULT_BRANCH"
  printf 'dry run — no push, no commit, no remote mutation\n'
  printf '===============================================================\n'

  exit 0
fi

# -----------------------------------------------------------------------------
# rsync private root -> scratch worktree
# -----------------------------------------------------------------------------

log "rsync $REPO_ROOT/ -> $WORKTREE_PATH/ (excludes: .publicignore + .git)"
rsync -a --delete \
  --exclude-from="$PUBLICIGNORE" \
  --exclude=".git" \
  "$REPO_ROOT/" \
  "$WORKTREE_PATH/"

# -----------------------------------------------------------------------------
# Stage + detect changes (idempotency)
# -----------------------------------------------------------------------------

git -C "$WORKTREE_PATH" add -A

if git -C "$WORKTREE_PATH" diff --cached --quiet; then
  log "nothing to mirror — public tree already matches private (post-blocklist)"
  exit 0
fi

# -----------------------------------------------------------------------------
# Squash commit
# -----------------------------------------------------------------------------

PRIVATE_SHORT_SHA="$(git -C "$REPO_ROOT" rev-parse --short HEAD)"
PRIVATE_FULL_SHA="$(git -C "$REPO_ROOT" rev-parse HEAD)"
UTC_TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

COMMIT_SUBJECT="chore(mirror): sync from private at $PRIVATE_SHORT_SHA $UTC_TS"
COMMIT_TRAILER="Source-Commit: $PRIVATE_FULL_SHA"

# Ensure the scratch clone has a committer identity even in ephemeral CI/test.
if ! git -C "$WORKTREE_PATH" config user.email >/dev/null 2>&1; then
  git -C "$WORKTREE_PATH" config user.email "mirror-public@jenga.local"
fi
if ! git -C "$WORKTREE_PATH" config user.name >/dev/null 2>&1; then
  git -C "$WORKTREE_PATH" config user.name "jenga mirror-public"
fi

git -C "$WORKTREE_PATH" commit -m "$COMMIT_SUBJECT" -m "$COMMIT_TRAILER" >/dev/null

NEW_SHA="$(git -C "$WORKTREE_PATH" rev-parse HEAD)"

# -----------------------------------------------------------------------------
# Advance marker tag (LOCAL to scratch clone — never pushed)
# -----------------------------------------------------------------------------

git -C "$WORKTREE_PATH" tag -f last-mirror-sync HEAD >/dev/null

# -----------------------------------------------------------------------------
# Push
# -----------------------------------------------------------------------------

log "pushing $NEW_SHA -> origin/$DEFAULT_BRANCH"
git -C "$WORKTREE_PATH" push origin "$DEFAULT_BRANCH"

# -----------------------------------------------------------------------------
# Summary
# -----------------------------------------------------------------------------

FILES_CHANGED="$(git -C "$WORKTREE_PATH" diff-tree --no-commit-id --name-only -r HEAD | wc -l | tr -d ' ')"

printf '\n'
printf '================ mirror-public summary ================\n'
printf 'files changed : %s\n' "$FILES_CHANGED"
printf 'new commit    : %s\n' "$NEW_SHA"
printf 'remote branch : %s\n' "$DEFAULT_BRANCH"
printf 'public URL    : %s\n' "$PUBLIC_URL"
printf '=======================================================\n'
