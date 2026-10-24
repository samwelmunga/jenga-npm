#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# scripts/merge-task-into-perceived-branch.sh - merge finished task work into the session's perceived branch
# (epic E78, task E78_S02_T04)
#
# A session can treat a branch other than the checked-out one as its working branch (scripts/perceived-branch.sh,
# the j-checkout skill) WITHOUT moving the real checkout. Finished task work must then land on the perceived
# branch, not on the real one. A plain "git merge" merges into whatever the CURRENT tree has checked out, and a
# branch cannot be checked out in two trees at once, so merging into the perceived branch from the main tree
# would mean moving the main tree's checkout. This script instead merges inside a DEDICATED worktree whose
# checkout is the perceived branch. The main tree's HEAD, index and working files are never touched. The
# reasoning and the "who merges today" finding are in project/documentation/task-merge-back-today.md (E78_S02_T01).
#
# ---------------------------------------------------------------------------
# USAGE
# ---------------------------------------------------------------------------
#   merge-task-into-perceived-branch.sh <task-branch> [--session <key>]
#   merge-task-into-perceived-branch.sh --cleanup [--branch <name> | --all] [--session <key>]
#   merge-task-into-perceived-branch.sh -h | --help | help        print this usage on stdout, exit 0
#
# <task-branch>
#   A local branch holding finished task work (the task worktree's branch, for example
#   E78_S02_T04-merge-into-perceived). It is merged into the perceived branch with "git merge --no-ff" (a merge
#   commit even when a fast-forward would be possible, subject "merge: <task-branch> into <perceived>"), run
#   INSIDE the dedicated worktree. Merging a branch that is already merged is a successful no-op (exit 0).
#
# --cleanup
#   Removes the dedicated worktree instead of merging (see LIFECYCLE). With no other flag it removes the one for
#   this session's current perceived branch; --branch <name> names the branch explicitly (use it after the
#   perceived branch has been cleared); --all removes every dedicated worktree that this script manages.
#
# --session <key> (also --session=<key>)
#   Passed to scripts/perceived-branch.sh to override the resolved session key (the test seam).
#
# What it will NOT do: no checkout or switch of any tree, no push, no change to the main tree's HEAD, index or
# working files, no merge into HEAD when the perceived branch is missing.
#
# ---------------------------------------------------------------------------
# EXIT STATUSES
# ---------------------------------------------------------------------------
#   0  applied      the task branch is merged into the perceived branch (or already was). With --cleanup: the
#                   worktree was removed, or there was nothing to remove.
#   1  usage        unknown or missing argument, malformed session key, <task-branch> is not a local branch or
#                   is the perceived branch itself.
#   2  conflict     the merge conflicts. The merge was aborted ("git merge --abort") inside the dedicated
#                   worktree, which is left clean; the conflicted paths are printed on stdout, one per line,
#                   after a "conflict:" line. Resolution is the existing rule in agents/developer.md
#                   ("Conflict Resolution"), unchanged.
#   3  not applicable   no perceived branch is set for this session, or it equals the main tree's checked-out
#                   branch. Nothing was done and nothing was created; one line on stdout says so. The caller
#                   uses the existing merge procedure, exactly as before E78.
#   4  perceived branch missing   a perceived branch is recorded but no longer exists. Names it on stderr and
#                   merges nothing (never falls back to HEAD).
#   6  branch checked out elsewhere   the perceived branch is checked out in a worktree other than the
#                   dedicated one; the path is named on stderr and nothing is merged.
#   7  worktree or git problem   the dedicated worktree could not be created or is not usable (path taken by
#                   something else, dirty, mid-merge, or on another branch), the merge failed for a reason
#                   other than a conflict, or (--cleanup) a removal was refused. The reason is on stderr.
#   (5 is unused; it is reserved to keep the numbering aligned with scripts/perceived-branch.sh.)
#
# ---------------------------------------------------------------------------
# DEDICATED WORKTREE: NAME AND LIFECYCLE
# ---------------------------------------------------------------------------
#   Location  <main working tree>/.claude/worktrees/perceived-<branch>-<n>, next to the task worktrees. <branch>
#             is the perceived branch with every character outside [A-Za-z0-9._-] replaced by "-"
#             (shortened to 60 characters), and <n> is the cksum of the unmodified branch name, so "a/b" and
#             "a-b" get different directories. Task worktrees are named <E##_S##_T##-slug>, so the "perceived-"
#             prefix can never collide with a task id.
#   Created   on the first applicable call, with a plain "git worktree add <path> <perceived-branch>" (no new
#             branch, no start-point). The WorktreeCreate hook is NOT involved and scripts/
#             install-worktree-commit-guard.sh is never run for it: that guard rejects any commit whose
#             branch differs from the task branch, and would reject this worktree's merge commit. Its
#             per-worktree core.hooksPath is private to each task worktree, so it does not leak into this one.
#   Reused    every later call finds it by path and merges in it; no second one is ever created. A reused
#             worktree must be clean, not mid-merge, and still on the perceived branch (exit 7 otherwise), and
#             a registered-but-deleted directory is re-created. If the perceived branch is checked out in any
#             OTHER worktree git itself forbids a second checkout; the script reports that path (exit 6).
#   Removed   with --cleanup (preferred) or "git worktree remove <path>" once the perceived branch is cleared
#             (scripts/perceived-branch.sh clear) or the session ends. Removal goes through scripts/
#             worktree-remove-guard.sh, the same liveness precondition the WorktreeRemove hook applies to task
#             worktrees (a plain "git worktree remove" when the guard script is absent), and is refused while
#             the worktree is dirty or mid-merge. Only the checkout is removed; the perceived branch and the
#             merged commits stay. The directory sits under ".claude/worktrees/", which must be gitignored
#             (as task worktrees already require), or the main tree's "git status" would list it.
#
# ---------------------------------------------------------------------------
# HOW IT FINDS THINGS
# ---------------------------------------------------------------------------
#   The main working tree is the first entry of "git worktree list", so the script works the same when run from
#   the main tree or from inside a task worktree. scripts/perceived-branch.sh (the sibling script) is the only
#   reader of the per-session state; it runs with the MAIN tree as its cwd so that its queue directory resolves
#   there and not to the copy of project/ inside a task worktree. "Unset" and "set but the branch is gone" both
#   make "perceived-branch.sh get --perceived" exit 1 with empty stdout; they are told apart by the
#   "no longer exists" notice that command writes on stderr (a coupling to that wording, noted in the task
#   summary). Environment: JENGA_CHECKLIST_SESSION_ID, CLAUDE_CODE_SESSION_ID, JENGA_SESSION_ID,
#   JENGA_PROJECT_ROOT are honoured through perceived-branch.sh.
#
# Compatible with macOS bash 3.2 (no associative arrays, mapfile or case-modifying expansions).
# ---------------------------------------------------------------------------

set -u

# A caller may be a git hook that exported these; they would redirect every git command below.
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR GIT_PREFIX

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PERCEIVED_SCRIPT="$SCRIPT_DIR/perceived-branch.sh"
REMOVE_GUARD="$SCRIPT_DIR/worktree-remove-guard.sh"
WT_PREFIX="perceived-"
NO_LONGER_EXISTS="no longer exists"

err() { printf 'merge-task-into-perceived-branch: %s\n' "$*" >&2; }
die() {
  local code="$1"
  shift
  err "$*"
  exit "$code"
}

usage() {
  # Prints the USAGE block of the header above, without the leading "# ".
  sed -n '/^# USAGE$/,/^# EXIT STATUSES$/{
    /^# ---/d
    /^# USAGE$/d
    /^# EXIT STATUSES$/d
    s/^# \{0,1\}//
    p
  }' "${BASH_SOURCE[0]}"
}

# ---------------------------------------------------------------------------
# Arguments
# ---------------------------------------------------------------------------
TASK_BRANCH=""
SESSION=""
CLEANUP=0
CLEAN_BRANCH=""
CLEAN_ALL=0

while [ "$#" -gt 0 ]; do
  case "$1" in
    -h | --help | help)
      usage
      exit 0
      ;;
    --session)
      [ "$#" -ge 2 ] && [ -n "$2" ] || die 1 "--session needs a key"
      SESSION="$2"
      shift 2
      ;;
    --session=*)
      SESSION="${1#--session=}"
      [ -n "$SESSION" ] || die 1 "--session needs a key"
      shift
      ;;
    --cleanup)
      CLEANUP=1
      shift
      ;;
    --branch)
      [ "$#" -ge 2 ] && [ -n "$2" ] || die 1 "--branch needs a branch name"
      CLEAN_BRANCH="$2"
      shift 2
      ;;
    --all)
      CLEAN_ALL=1
      shift
      ;;
    --)
      shift
      break
      ;;
    -*)
      die 1 "unknown option '$1' (see --help)"
      ;;
    *)
      [ -z "$TASK_BRANCH" ] || die 1 "only one <task-branch> may be given"
      TASK_BRANCH="$1"
      shift
      ;;
  esac
done
if [ "$#" -gt 0 ]; then
  [ -z "$TASK_BRANCH" ] && [ "$#" -eq 1 ] || die 1 "only one <task-branch> may be given"
  TASK_BRANCH="$1"
fi

if [ "$CLEANUP" -eq 1 ]; then
  [ -z "$TASK_BRANCH" ] || die 1 "--cleanup takes no <task-branch>"
  [ -z "$CLEAN_BRANCH" ] || [ "$CLEAN_ALL" -eq 0 ] || die 1 "--branch and --all are mutually exclusive"
else
  [ -n "$TASK_BRANCH" ] || die 1 "missing <task-branch> (see --help)"
  [ -z "$CLEAN_BRANCH" ] && [ "$CLEAN_ALL" -eq 0 ] || die 1 "--branch and --all only apply to --cleanup"
fi

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

# The main working tree: first entry of "git worktree list", independent of the cwd's worktree.
MAIN_TREE="$(git worktree list --porcelain 2>/dev/null | awk 'NR == 1 { print substr($0, 10); exit }')"
[ -n "$MAIN_TREE" ] && [ -d "$MAIN_TREE" ] || die 7 "not inside a git repository (cannot locate the main working tree)"
WORKTREES_DIR="$MAIN_TREE/.claude/worktrees"

# perceived-branch.sh <subcommand> <flag>, with the main tree as cwd and the optional session key.
pb() {
  if [ -n "$SESSION" ]; then
    (cd "$MAIN_TREE" && "$PERCEIVED_SCRIPT" "$1" "$2" --session "$SESSION") 2>&1
  else
    (cd "$MAIN_TREE" && "$PERCEIVED_SCRIPT" "$1" "$2") 2>&1
  fi
}

branch_exists() { git -C "$MAIN_TREE" show-ref --verify --quiet "refs/heads/$1" 2>/dev/null; }

# Prints the worktree path that has branch $1 checked out, or nothing.
checked_out_at() {
  git -C "$MAIN_TREE" worktree list --porcelain 2>/dev/null | awk -v r="refs/heads/$1" '
    /^worktree / { cur = substr($0, 10) }
    /^branch / && substr($0, 8) == r { print cur; exit }'
}

# Returns 0 when path $1 is a registered worktree of this repository.
is_registered() {
  git -C "$MAIN_TREE" worktree list --porcelain 2>/dev/null | awk -v p="$1" '
    /^worktree / && substr($0, 10) == p { found = 1 }
    END { exit found ? 0 : 1 }'
}

# Prints the dedicated worktree path for branch $1.
dedicated_path() {
  local slug sum
  slug="$(printf '%s' "$1" | tr -c 'A-Za-z0-9._-' '-' | cut -c1-60)"
  sum="$(printf '%s' "$1" | cksum | awk '{ print $1 }')"
  printf '%s/%s%s-%s\n' "$WORKTREES_DIR" "$WT_PREFIX" "$slug" "$sum"
}

# Returns 0 when worktree $1 has no changes and no merge in progress.
worktree_is_clean() {
  [ -z "$(git -C "$1" status --porcelain 2>/dev/null)" ] || return 1
  git -C "$1" rev-parse -q --verify MERGE_HEAD >/dev/null 2>&1 && return 1
  return 0
}

# Resolves the perceived branch. Sets PERCEIVED ("" when none) and PERCEIVED_STATE: set | unset | missing.
resolve_perceived() {
  local out status
  out="$(pb get --perceived)"
  status=$?
  PERCEIVED=""
  PERCEIVED_STATE="unset"
  case "$status" in
    0)
      PERCEIVED="$(printf '%s\n' "$out" | grep -v '^perceived-branch:' | head -n 1)"
      if [ -n "$PERCEIVED" ]; then PERCEIVED_STATE="set"; fi
      ;;
    1)
      if printf '%s' "$out" | grep -q "$NO_LONGER_EXISTS"; then
        PERCEIVED_STATE="missing"
        PERCEIVED="$(printf '%s\n' "$out" | sed -n 's/^perceived-branch: note: perceived branch \(.*\) no longer exists.*/\1/p' | head -n 1)"
      fi
      ;;
    2) die 1 "perceived-branch.sh rejected the session key: $out" ;;
    *) die 7 "perceived-branch.sh failed (exit $status): $out" ;;
  esac
}

# ---------------------------------------------------------------------------
# --cleanup
# ---------------------------------------------------------------------------

# Removes the dedicated worktree at $1 when it is registered and clean. Returns 0 on removal or nothing to do.
remove_one() {
  local path="$1"
  if ! is_registered "$path"; then
    printf 'nothing to remove: %s is not a worktree\n' "$path"
    return 0
  fi
  if ! worktree_is_clean "$path"; then
    err "refusing to remove $path: it has changes or a merge in progress"
    return 7
  fi
  if [ -x "$REMOVE_GUARD" ]; then
    (cd "$MAIN_TREE" && "$REMOVE_GUARD" "$path") || {
      err "worktree-remove-guard.sh did not remove $path"
      return 7
    }
  else
    git -C "$MAIN_TREE" worktree remove "$path" || {
      err "git worktree remove failed for $path"
      return 7
    }
  fi
  printf 'removed dedicated worktree %s\n' "$path"
  return 0
}

if [ "$CLEANUP" -eq 1 ]; then
  rc=0
  if [ "$CLEAN_ALL" -eq 1 ]; then
    paths="$(git -C "$MAIN_TREE" worktree list --porcelain 2>/dev/null | awk -v pre="$WORKTREES_DIR/$WT_PREFIX" '
      /^worktree / { p = substr($0, 10); if (index(p, pre) == 1) print p }')"
    if [ -z "$paths" ]; then
      echo "nothing to remove: no dedicated perceived-branch worktrees"
      exit 0
    fi
    while IFS= read -r p; do
      remove_one "$p" || rc=7
    done <<EOF
$paths
EOF
    exit "$rc"
  fi
  target="$CLEAN_BRANCH"
  if [ -z "$target" ]; then
    resolve_perceived
    target="$PERCEIVED"
    if [ -z "$target" ]; then
      echo "nothing to remove: no perceived branch is set (use --branch <name> or --all)"
      exit 0
    fi
  fi
  remove_one "$(dedicated_path "$target")"
  exit $?
fi

# ---------------------------------------------------------------------------
# Merge
# ---------------------------------------------------------------------------

resolve_perceived
case "$PERCEIVED_STATE" in
  unset)
    echo "not applicable: no perceived branch is set for this session; use the existing merge procedure"
    exit 3
    ;;
  missing)
    die 4 "the perceived branch ${PERCEIVED:-recorded for this session} no longer exists; nothing was merged"
    ;;
esac

REAL="$(pb get --real)"
if [ $? -ne 0 ]; then REAL=""; fi # detached HEAD in the main tree: no real branch name, so never equal
if [ "$PERCEIVED" = "$REAL" ]; then
  echo "not applicable: the perceived branch $PERCEIVED is the main tree's checked-out branch; use the existing merge procedure"
  exit 3
fi

branch_exists "$PERCEIVED" || die 4 "the perceived branch $PERCEIVED no longer exists; nothing was merged"
branch_exists "$TASK_BRANCH" || die 1 "<task-branch> '$TASK_BRANCH' is not a local branch"
[ "$TASK_BRANCH" != "$PERCEIVED" ] || die 1 "<task-branch> is the perceived branch itself; nothing to merge"

DEDICATED="$(dedicated_path "$PERCEIVED")"
HOLDER="$(checked_out_at "$PERCEIVED")"

if [ -n "$HOLDER" ] && [ "$HOLDER" != "$DEDICATED" ]; then
  die 6 "the perceived branch $PERCEIVED is already checked out in $HOLDER; git allows one checkout per branch, so the dedicated worktree cannot be created. Nothing was merged"
fi

if [ "$HOLDER" = "$DEDICATED" ]; then
  # Registered for this branch already. Re-create the checkout if its directory was deleted by hand.
  if [ ! -d "$DEDICATED" ]; then
    git -C "$MAIN_TREE" worktree add --force "$DEDICATED" "$PERCEIVED" >/dev/null 2>&1 \
      || die 7 "could not re-create the dedicated worktree $DEDICATED"
  fi
else
  if is_registered "$DEDICATED"; then
    die 7 "$DEDICATED is registered as a worktree of another branch; remove it with --cleanup --all first"
  fi
  [ ! -e "$DEDICATED" ] || die 7 "$DEDICATED exists and is not a worktree; refusing to use it"
  git -C "$MAIN_TREE" worktree add "$DEDICATED" "$PERCEIVED" >/dev/null 2>&1 \
    || die 7 "could not create the dedicated worktree $DEDICATED for $PERCEIVED"
fi

CURRENT="$(git -C "$DEDICATED" symbolic-ref -q --short HEAD 2>/dev/null)"
[ "$CURRENT" = "$PERCEIVED" ] || die 7 "dedicated worktree $DEDICATED is on '${CURRENT:-a detached HEAD}', not $PERCEIVED"
worktree_is_clean "$DEDICATED" || die 7 "dedicated worktree $DEDICATED has changes or a merge in progress; refusing to merge into it"

MERGE_OUT="$(git -C "$DEDICATED" merge --no-ff --no-edit -m "merge: $TASK_BRANCH into $PERCEIVED" "$TASK_BRANCH" 2>&1)"
MERGE_RC=$?

if [ "$MERGE_RC" -eq 0 ]; then
  SHA="$(git -C "$DEDICATED" rev-parse --short HEAD)"
  case "$MERGE_OUT" in
    *"Already up to date"*)
      printf 'applied: %s is already merged into %s (%s, worktree %s)\n' "$TASK_BRANCH" "$PERCEIVED" "$SHA" "$DEDICATED"
      ;;
    *)
      printf 'applied: merged %s into %s as %s (worktree %s)\n' "$TASK_BRANCH" "$PERCEIVED" "$SHA" "$DEDICATED"
      ;;
  esac
  exit 0
fi

# Failure: gather conflicted paths before aborting, then leave the dedicated worktree clean.
CONFLICTS="$(git -C "$DEDICATED" diff --name-only --diff-filter=U 2>/dev/null)"
IN_MERGE=0
git -C "$DEDICATED" rev-parse -q --verify MERGE_HEAD >/dev/null 2>&1 && IN_MERGE=1
if [ "$IN_MERGE" -eq 1 ]; then
  git -C "$DEDICATED" merge --abort >/dev/null 2>&1
fi
worktree_is_clean "$DEDICATED" || die 7 "merge failed and the dedicated worktree $DEDICATED could not be returned to a clean state: $MERGE_OUT"

if [ -n "$CONFLICTS" ]; then
  printf 'conflict: merging %s into %s conflicted; the merge was aborted and %s is clean. Conflicted paths:\n' \
    "$TASK_BRANCH" "$PERCEIVED" "$DEDICATED"
  printf '%s\n' "$CONFLICTS"
  exit 2
fi
die 7 "merging $TASK_BRANCH into $PERCEIVED failed without a conflict: $MERGE_OUT"
