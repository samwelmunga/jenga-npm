#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# scripts/create-task-worktree.sh - create a task worktree from the session's perceived branch
# (epic E78, task E78_S02_T02)
#
# One place that decides where a new task worktree is cut from. The WorktreeCreate hook and the developer
# agent's manual path both call it (wired by E78_S02_T03), so "honour the perceived branch" exists once.
#
# The perceived branch is a branch the session treats as its working branch while the real checkout stays where
# it is. It is resolved ONLY through scripts/perceived-branch.sh; this script knows nothing about how or where
# it is stored, and it never moves the checkout or touches the main working tree's files or index.
#
# ---------------------------------------------------------------------------
# USAGE
# ---------------------------------------------------------------------------
#   create-task-worktree.sh <dir> <name> [--session <key>]
#   create-task-worktree.sh -h | --help       print this usage on stdout, exit 0
#
#   <dir>             the worktree directory to create (must not start with "-")
#   <name>            the new task branch, created together with the worktree
#   --session <key>   also --session=<key>; handed to perceived-branch.sh unchanged. Needed where the session id
#                     is not in the environment (see project/documentation/perceived-branch-session-id.md).
#
# Run it from the repository whose HEAD you would otherwise branch from (the hook's working directory), exactly
# as the bare "git worktree add" call it replaces.
#
# ---------------------------------------------------------------------------
# BEHAVIOUR (the three cases)
# ---------------------------------------------------------------------------
#   1. No perceived branch set
#        git worktree add "<dir>" -b "<name>"
#      No start-point argument, so the result is identical to today's: <name> starts at HEAD of the current
#      working tree.
#   2. Perceived branch set and it exists
#        git worktree add "<dir>" -b "<name>" "<perceived-branch>"
#      <name> starts at the tip of the perceived branch. The main tree's checked-out branch and files are
#      untouched.
#   3. Perceived branch set but it no longer exists
#      No worktree and no <name> branch are created, and HEAD is NOT used as a fallback. A message naming the
#      branch goes to stderr and the exit status is 4.
#
# Output contract: STDOUT carries exactly one line, <dir>, and only on success. On any failure nothing is
# written to stdout, so a caller that echoes stdout as the worktree path (the hook) cannot report a path that
# was never created. Git's own stdout (for example "HEAD is now at ...") is redirected to stderr so it cannot
# end up in front of the path; git's stderr passes through unchanged. Notices from perceived-branch.sh are
# passed through on stderr.
#
# ---------------------------------------------------------------------------
# EXIT CODES
# ---------------------------------------------------------------------------
#   0  the worktree was created; <dir> is on stdout
#   2  usage error: missing, extra or unknown argument, empty <dir> or <name>, <dir> starting with "-"
#   4  a perceived branch is set but no longer exists; nothing was created
#   5  the perceived branch could not be determined (perceived-branch.sh is missing or failed with an
#      unexpected status); nothing was created, because guessing HEAD could cut the task from the wrong branch
#   other  git's own exit status, unchanged, when "git worktree add" fails (for example an existing <name>
#      branch or an existing <dir>)
#
# Perceived-branch detection: "perceived-branch.sh get --perceived" prints a set, still-existing branch (exit 0)
# and otherwise prints nothing and exits 1, both when nothing is set and when the recorded branch was deleted.
# The two are told apart by the "no longer exists" notice that script writes on stderr in the deleted case
# (documented in its header). A branch that is reported set is re-confirmed with "perceived-branch.sh exists"
# immediately before use.
#
# Compatible with macOS bash 3.2 (no associative arrays, mapfile or case-modifying expansions).
# ---------------------------------------------------------------------------

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PERCEIVED_BRANCH="$SCRIPT_DIR/perceived-branch.sh"

err() { printf 'create-task-worktree: %s\n' "$*" >&2; }
die() {
  local code="$1"
  shift
  err "$*"
  exit "$code"
}

usage() {
  # Prints the USAGE block of the header above, without the leading "# ".
  sed -n '/^# USAGE$/,/^# BEHAVIOUR/{
    /^# ---/d
    /^# USAGE$/d
    /^# BEHAVIOUR/d
    s/^# \{0,1\}//
    p
  }' "${BASH_SOURCE[0]}"
}

DIR=""
NAME=""
SESSION=""
have_dir=0
have_name=0

while [ $# -gt 0 ]; do
  case "$1" in
    -h | --help | help)
      usage
      exit 0
      ;;
    --session)
      [ $# -ge 2 ] || die 2 "--session needs a value"
      SESSION="$2"
      shift 2
      ;;
    --session=*)
      SESSION="${1#--session=}"
      shift
      ;;
    -*)
      die 2 "unknown option: $1"
      ;;
    *)
      if [ "$have_dir" -eq 0 ]; then
        DIR="$1"
        have_dir=1
      elif [ "$have_name" -eq 0 ]; then
        NAME="$1"
        have_name=1
      else
        die 2 "unexpected argument: $1"
      fi
      shift
      ;;
  esac
done

[ -n "$DIR" ] || die 2 "usage: create-task-worktree.sh <dir> <name> [--session <key>]"
[ -n "$NAME" ] || die 2 "usage: create-task-worktree.sh <dir> <name> [--session <key>]"
case "$NAME" in
  -*) die 2 "invalid branch name: $NAME" ;;
esac

[ -f "$PERCEIVED_BRANCH" ] || die 5 "cannot determine the perceived branch: $PERCEIVED_BRANCH is missing; no worktree was created"

# ---------------------------------------------------------------------------
# Resolve the perceived branch (only through perceived-branch.sh)
# ---------------------------------------------------------------------------

ERR_FILE="$(mktemp "${TMPDIR:-/tmp}/create-task-worktree.XXXXXX")" || die 5 "could not create a temporary file; no worktree was created"
trap 'rm -f "$ERR_FILE"' EXIT

pb_args=(get --perceived)
if [ -n "$SESSION" ]; then
  pb_args+=(--session "$SESSION")
fi

perceived="$(bash "$PERCEIVED_BRANCH" "${pb_args[@]}" 2>"$ERR_FILE")"
pb_status=$?
cat "$ERR_FILE" >&2

missing=""
case "$pb_status" in
  0)
    [ -n "$perceived" ] || die 5 "perceived-branch.sh reported success but printed no branch; no worktree was created"
    if ! bash "$PERCEIVED_BRANCH" exists "$perceived"; then
      missing="$perceived"
    fi
    ;;
  1)
    perceived=""
    if grep -q 'no longer exists' "$ERR_FILE"; then
      missing="$(sed -n 's/.*perceived branch \([^ ]*\) no longer exists.*/\1/p' "$ERR_FILE" | head -n 1)"
      [ -n "$missing" ] || missing="(unknown)"
    fi
    ;;
  *)
    die 5 "could not determine the perceived branch (perceived-branch.sh exited $pb_status); no worktree was created"
    ;;
esac

if [ -n "$missing" ]; then
  die 4 "perceived branch '$missing' no longer exists; run j.checkout --clear or recreate it. No worktree was created and HEAD was not used as a fallback."
fi

# ---------------------------------------------------------------------------
# Create the worktree. Git's stdout goes to stderr so stdout stays "the path, on success, nothing otherwise".
# ---------------------------------------------------------------------------

if [ -n "$perceived" ]; then
  git worktree add "$DIR" -b "$NAME" "$perceived" >&2
else
  git worktree add "$DIR" -b "$NAME" >&2
fi
git_status=$?
if [ "$git_status" -ne 0 ]; then
  exit "$git_status"
fi

printf '%s\n' "$DIR"
exit 0
