#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# skills/j-gitignore/scripts/untrack-jenga-files.sh
#
# Removes Jenga-owned paths from git WITHOUT removing them from disk —
# `git rm -r --cached`, never a plain `git rm`. The files stay exactly where
# they are; git simply stops tracking them, and the .gitignore entries written
# by repair-gitignore.sh then keep them from coming back.
#
# Run repair-gitignore.sh FIRST. .gitignore has no effect on an already-tracked
# file, so untracking without the entries in place just means the next
# `git add -A` re-adds everything.
#
# ─── What "removed from origin" does and does not mean ──────────────────────
# With --commit --push, these paths disappear from the branch TIP on the
# remote: clone it fresh and they are gone. Earlier commits are UNTOUCHED —
# the blobs remain reachable in history, so this is not a secret-scrubbing
# tool. If something sensitive was committed, treat it as compromised, rotate
# it, and use a history-rewriting tool (git-filter-repo) separately.
#
# Invoked via `bash`, not executed directly.
#
# Usage:
#   untrack-jenga-files.sh [project_root]
#                          [--tiers scaffold,hybrid,board,optional]
#                          [--dry-run] [--commit] [--push]
#                          [--allow-dirty-index]
#
# Options:
#   --dry-run             List what would be untracked; touch nothing.
#   --commit              Commit the removals. Without it, changes are left
#                         staged for you to inspect and commit yourself.
#   --push                Push to the branch's upstream. Requires --commit.
#                         Never implied — this is the only outward-facing step.
#   --allow-dirty-index   Proceed even if unrelated changes are already staged.
#                         Off by default so this can never sweep your staged
#                         work into its commit.
#
# Exit codes:
#   0  Success (including "nothing tracked — nothing to do")
#   1  Bad usage or missing prerequisite
#   2  Invalid tier
#   3  git operation failed
#   4  Refused: index already dirty, or --push without --commit
# -----------------------------------------------------------------------------

set -uo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_catalog.sh"

info() { echo "[untrack] $*"; }
warn() { echo "[untrack] WARNING: $*"; }
err()  { echo "[untrack] ERROR: $*" >&2; }

PROJECT_ROOT=""
TIERS="scaffold"
DRY_RUN=0
DO_COMMIT=0
DO_PUSH=0
ALLOW_DIRTY=0

while [ $# -gt 0 ]; do
  case "$1" in
    --tiers)   TIERS="${2:-}"; shift 2 ;;
    --tiers=*) TIERS="${1#*=}"; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    --commit)  DO_COMMIT=1; shift ;;
    --push)    DO_PUSH=1; shift ;;
    --allow-dirty-index) ALLOW_DIRTY=1; shift ;;
    -h|--help)
      echo "Usage: $(basename "$0") [project_root] [--tiers <csv>] [--dry-run] [--commit] [--push] [--allow-dirty-index]"
      exit 0 ;;
    -*) err "Unknown option: $1"; exit 1 ;;
    *)
      if [ -n "$PROJECT_ROOT" ]; then err "More than one project root given."; exit 1; fi
      PROJECT_ROOT="$1"; shift ;;
  esac
done

if [ "$DO_PUSH" -eq 1 ] && [ "$DO_COMMIT" -eq 0 ]; then
  err "--push requires --commit. There would be nothing to push."
  exit 4
fi

PROJECT_ROOT="${PROJECT_ROOT:-$PWD}"
validate_tiers "$TIERS" || exit 2
resolve_root "$PROJECT_ROOT" || exit 1
load_catalog "$TIERS" || exit 1

# ─── Refuse to run on a dirty index ─────────────────────────────────────────
# .gitignore is the one staged path that is never "unrelated": it is the
# companion change repair-gitignore.sh just made, and untracking without it is
# pointless. Staged alone, it is allowed through and folded into this commit.
# Anything else staged is refused.
if [ "$ALLOW_DIRTY" -eq 0 ] && [ "$DRY_RUN" -eq 0 ]; then
  if ! git diff --cached --quiet 2>/dev/null; then
    staged="$(git diff --cached --name-only)"
    if [ "$staged" = ".gitignore" ]; then
      info "Staged .gitignore detected — folding the ignore-rule change into this commit."
    else
      err "The index already has staged changes:"
      printf '%s\n' "$staged" | sed 's/^/        /' >&2
      err "Refusing to run — a --commit here would sweep them into this commit."
      err "Commit or unstage them first, or pass --allow-dirty-index if you"
      err "genuinely want them included."
      exit 4
    fi
  fi
fi

# ─── Find what is actually tracked ──────────────────────────────────────────
TRACKED_PATHS=()
TOTAL_FILES=0
for i in "${!CATALOG_PATHS[@]}"; do
  path="${CATALOG_PATHS[$i]}"
  count="$(git ls-files -- "$path" 2>/dev/null | wc -l | tr -d ' ')"
  if [ "${count:-0}" -gt 0 ]; then
    TRACKED_PATHS+=("$path")
    TOTAL_FILES=$((TOTAL_FILES + count))
    printf '  %-36s %s tracked file(s)\n' "$path" "$count"
  fi
done

if [ "${#TRACKED_PATHS[@]}" -eq 0 ]; then
  info "No catalog path (tiers: ${TIERS}) is tracked — nothing to untrack."
  exit 0
fi

echo
info "${#TRACKED_PATHS[@]} path(s), ${TOTAL_FILES} file(s) would stop being tracked."
info "All of them remain on disk — this uses 'git rm -r --cached'."

if [ "$DRY_RUN" -eq 1 ]; then
  info "--dry-run — nothing changed."
  exit 0
fi

# ─── Untrack ────────────────────────────────────────────────────────────────
for path in "${TRACKED_PATHS[@]}"; do
  if ! git rm -r --cached --quiet -- "$path"; then
    err "git rm --cached failed for '${path}'. The index may be partially staged;"
    err "inspect with 'git status' and 'git reset' to back out."
    exit 3
  fi
  info "Untracked: ${path}"
done

# Verify nothing was deleted from disk before reporting success.
MISSING=0
for path in "${TRACKED_PATHS[@]}"; do
  probe="${path%/}"
  if [ ! -e "$probe" ]; then
    warn "'${probe}' is not on disk. It was already absent before this ran"
    warn "(git tracked it, the working tree did not), so nothing was lost here."
    MISSING=$((MISSING + 1))
  fi
done
[ "$MISSING" -eq 0 ] && info "Verified: every untracked path is still present on disk."

if [ "$DO_COMMIT" -eq 0 ]; then
  echo
  info "Changes are STAGED but not committed. Review with:"
  info "    git status"
  info "    git diff --cached --stat"
  info "Then commit yourself, or re-run with --commit."
  exit 0
fi

# ─── Commit ─────────────────────────────────────────────────────────────────
COMMIT_MSG="chore(jenga): untrack Jenga-owned files, keep them on disk

Removes the Jenga scaffold from version control via 'git rm --cached' and
relies on the j.gitignore managed block to keep it out. Files are untouched
on disk. Tiers: ${TIERS}.

Note: this changes the branch tip only — earlier commits still contain these
paths."

if ! git commit -q -m "$COMMIT_MSG"; then
  err "git commit failed. Your removals are still staged."
  exit 3
fi
info "Committed: $(git rev-parse --short HEAD)"

if [ "$DO_PUSH" -eq 0 ]; then
  echo
  info "Not pushed. The remote still has these files until you push."
  exit 0
fi

# ─── Push ───────────────────────────────────────────────────────────────────
BRANCH="$(git rev-parse --abbrev-ref HEAD)"
UPSTREAM="$(git rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>/dev/null)"

if [ -z "$UPSTREAM" ]; then
  err "Branch '${BRANCH}' has no upstream — refusing to guess a remote."
  err "Set one, then push yourself:  git push -u origin ${BRANCH}"
  err "The commit itself succeeded and is safe on your local branch."
  exit 3
fi

info "Pushing ${BRANCH} → ${UPSTREAM} ..."
if ! git push; then
  err "Push failed — most likely the branch is behind its upstream."
  err "Reconcile (git pull --rebase) and push yourself. The commit is safe locally."
  exit 3
fi

info "Pushed. These paths are gone from ${UPSTREAM}'s tip."
info "They REMAIN in earlier commits — this did not rewrite history."
exit 0
