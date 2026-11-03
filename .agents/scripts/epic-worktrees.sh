#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# scripts/epic-worktrees.sh - find and remove the merged worktrees that belong to one epic
#
# USAGE
#   epic-worktrees.sh list   <epic> [<base>]
#   epic-worktrees.sh remove <epic> [<base>]
#
#   <epic>   an epic id such as E65 (E followed by digits; case-sensitive)
#   <base>   the branch the worktrees must be merged into (default: main)
#
# A worktree belongs to the epic when its branch name or its directory name carries the epic id as a whole
# token: E65 followed by "_", "-", "/" or the end, and preceded by the start or a non-alphanumeric character
# (so E650 and agent-a1e65 never match). Worktrees named only by a hash (agent-<hash>) cannot be attributed to
# an epic by name and are never selected.
#
# A matching worktree is REMOVABLE only when all of these hold: its HEAD is an ancestor of <base>, its working
# tree is clean (untracked files count as dirty), it is not locked, its directory exists, and it is neither the
# main worktree nor the one this command runs in. Anything else is KEPT with the reason.
#
# list    prints one line per matching worktree: "removable|kept<TAB><branch or (detached)><TAB><path><TAB><reason>".
#         Prints "none" when no worktree matches. Never changes anything.
# remove  removes every removable worktree through scripts/worktree-remove-guard.sh (the liveness check applies)
#         and then deletes its branch with `git branch -d` (never -D: an unmerged branch is kept). Prints one
#         "removed|kept|failed" line per worktree. Exit 1 when any removal failed, 0 otherwise.
#
# EXIT CODES
#   0 success   1 a removal failed   2 usage error or not inside a git repository
# ---------------------------------------------------------------------------
set -u

die() { printf 'epic-worktrees.sh: %s\n' "$1" >&2; exit 2; }

[ "$#" -ge 2 ] && [ "$#" -le 3 ] || die "usage: epic-worktrees.sh list|remove <epic> [<base>]"
mode="$1"; epic="$2"; base="${3:-main}"
case "$mode" in list|remove) ;; *) die "unknown mode '$mode' (expected list or remove)" ;; esac
printf '%s' "$epic" | grep -Eq '^E[0-9]+$' || die "invalid epic id '$epic' (expected E followed by digits)"

SELF_DIR="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
GUARD="$SELF_DIR/worktree-remove-guard.sh"

git rev-parse --git-dir >/dev/null 2>&1 || die "not inside a git repository"
git rev-parse --verify --quiet "$base^{commit}" >/dev/null || die "base branch '$base' does not exist"

here="$(git rev-parse --show-toplevel)"
here="$(CDPATH='' cd -P -- "$here" && pwd)"
token="(^|[^A-Za-z0-9])${epic}([_/-]|$)"

# Parse the porcelain listing into one record per worktree.
records="$(git worktree list --porcelain)"
first=1
path=""; head=""; branch=""; locked=0; prunable=0
rc=0
found=0

emit() {
  [ -n "$path" ] || return 0
  local is_main="$1" name label state reason physical
  name="${branch:-}"
  label="${branch:-(detached)}"
  if ! printf '%s\n%s\n' "$name" "$(basename -- "$path")" | grep -Eq "$token"; then
    return 0
  fi
  found=1
  state=removable; reason="merged into $base and clean"
  physical=""
  [ -d "$path" ] && physical="$(CDPATH='' cd -P -- "$path" 2>/dev/null && pwd)"
  if [ "$is_main" -eq 1 ]; then
    state=kept; reason="main worktree"
  elif [ -n "$physical" ] && [ "$physical" = "$here" ]; then
    state=kept; reason="current worktree"
  elif [ "$locked" -eq 1 ]; then
    state=kept; reason="locked"
  elif [ ! -d "$path" ] || [ "$prunable" -eq 1 ]; then
    state=kept; reason="directory missing (run git worktree prune)"
  elif ! git merge-base --is-ancestor "$head" "$base" 2>/dev/null; then
    state=kept; reason="not merged into $base"
  elif [ -n "$(git -C "$path" status --porcelain 2>/dev/null)" ]; then
    state=kept; reason="uncommitted or untracked changes"
  fi

  if [ "$mode" = "list" ]; then
    printf '%s\t%s\t%s\t%s\n' "$state" "$label" "$path" "$reason"
  elif [ "$state" = "kept" ]; then
    printf 'kept\t%s\t%s\t%s\n' "$label" "$path" "$reason"
  elif "$GUARD" "$path" >&2; then
    if [ -n "$name" ] && git branch -d "$name" >&2 2>&1; then
      printf 'removed\t%s\t%s\tworktree and branch\n' "$label" "$path"
    elif [ -n "$name" ]; then
      printf 'removed\t%s\t%s\tworktree only (branch kept)\n' "$label" "$path"
    else
      printf 'removed\t%s\t%s\tworktree\n' "$label" "$path"
    fi
  else
    printf 'failed\t%s\t%s\tremoval refused or failed (see stderr)\n' "$label" "$path"
    rc=1
  fi
}

while IFS= read -r line || [ -n "$line" ]; do
  case "$line" in
    "worktree "*) path="${line#worktree }"; head=""; branch=""; locked=0; prunable=0 ;;
    "HEAD "*)     head="${line#HEAD }" ;;
    "branch "*)   branch="${line#branch refs/heads/}" ;;
    "locked"*)    locked=1 ;;
    "prunable"*)  prunable=1 ;;
    "")           emit "$first"; first=0; path="" ;;
  esac
done <<EOF
$records

EOF

[ "$found" -eq 1 ] || echo "none"
exit "$rc"
