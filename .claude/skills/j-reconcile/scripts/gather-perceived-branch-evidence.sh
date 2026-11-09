#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# skills/j-reconcile/scripts/gather-perceived-branch-evidence.sh - per-branch git evidence for one task
# (epic E78, story E78_S05, task E78_S05_T01)
#
# A session can work against a "perceived branch" (see scripts/perceived-branch.sh) while the real checkout stays
# on another branch. A task can therefore be merged only into the perceived branch while the board, read on the
# real branch, says "Done" and the real branch has no commit for it. /j-reconcile's phases 2 and 3 used to look at
# git history without knowing which branch it was looking at. This script answers one narrow question
# deterministically, so SKILL.md only interprets the result (Scripts Over Inline Logic): for one task id, does a
# commit that names the id exist on the real branch, on the perceived branch, on both, or on neither?
#
# It is strictly read-only: it runs only `git log`, `git rev-parse` and `git show-ref`-style reads (through
# perceived-branch.sh for the branch names), and never merges, checks out, creates a branch or worktree, or writes
# a file. The perceived branch is obtained ONLY through scripts/perceived-branch.sh (`get --real` and
# `get --perceived`), which asks for this session's value alone; another session's state file is never opened.
#
# ---------------------------------------------------------------------------
# USAGE
# ---------------------------------------------------------------------------
#   gather-perceived-branch-evidence.sh <task_id> [--session <key>]
#   gather-perceived-branch-evidence.sh -h | --help         print this usage on stdout, exit 0
#
#   <task_id>        a board task id, E##_S##_T## (an E## or E##_S## id is also accepted)
#   --session <key>  also --session=<key>; handed unchanged to perceived-branch.sh. Needed where the session id
#                    is not in the environment (see project/documentation/perceived-branch-session-id.md).
#
# Run it from inside the repository (any worktree of it). Git is run in the current directory.
#
# ---------------------------------------------------------------------------
# OUTPUT (stdout): exactly ONE line of space-separated key=value pairs, in this fixed order
# ---------------------------------------------------------------------------
#   task_id=<id> real_branch=<name> perceived_branch=<name> perceived_stale=<yes|no> \
#     evidence_on_real=<yes|no> evidence_on_perceived=<yes|no> evidence_branch=<real|perceived|both|none>
#
#   task_id                the id that was searched
#   real_branch            the real checked-out branch of the main working tree. Empty on a detached HEAD, in
#                          which case the real-side search runs against HEAD.
#   perceived_branch       this session's perceived branch. EMPTY when none is set. When the recorded branch no
#                          longer exists it still names that branch (see perceived_stale).
#   perceived_stale        yes when a perceived branch is recorded for this session but the branch is gone; no
#                          otherwise. A stale branch is an observation, not an error: it is treated as not set
#                          for evidence purposes (evidence_on_perceived=no, never searched), the exit status is
#                          0, and nothing is written on stderr. SKILL.md reports it once.
#   evidence_on_real       yes when a commit reachable from the real branch has a message naming the task id
#   evidence_on_perceived  yes when a commit reachable from a set, existing perceived branch names the task id;
#                          always no when none is set or it is stale
#   evidence_branch        which branch supplied the evidence:
#                            real       only the real branch has it (also the answer with no perceived branch)
#                            perceived  only the perceived branch has it
#                            both       both have it
#                            none       neither has it
#
# With no perceived branch set the record is the same one-line shape with perceived_branch empty,
# perceived_stale=no and evidence_on_perceived=no, and no extra lines: the existing /j-reconcile flow is
# unchanged. If the perceived branch is the real branch itself, both sides search the same history, so
# evidence_branch reads real (or none) and is never both.
#
# A commit "names the task id" when the id appears anywhere in its message (subject or body, which includes a
# `Jenga-Task:` trailer) and is not followed by a digit or an underscore, the same anchor scripts/commits-for-item.sh
# uses, so E78_S05_T01 does not match E78_S05_T010. Merge commits count: a merge message that names the id is a
# commit on that branch that names it. Reachability is per branch (`git log <branch>`), which is the point of the
# script: `git log --all` cannot say which branch holds the work.
#
# ---------------------------------------------------------------------------
# EXIT CODES
# ---------------------------------------------------------------------------
#   0  the record was printed (including: no perceived branch, stale perceived branch, no evidence anywhere)
#   2  usage error: missing or extra argument, unknown flag, malformed task id, or a malformed --session key
#   3  git problem: not inside a git repository, or a branch listed above could not be searched
#   4  scripts/perceived-branch.sh is missing or not executable
#   5  perceived-branch.sh reported a state problem (for example jq is missing); no record is printed. A caller
#      that wants today's behaviour should treat any non-zero status as "no perceived-branch information".
# On every non-zero status nothing is written to stdout, and one diagnostic line goes to stderr.
#
# Compatible with macOS bash 3.2 (no associative arrays, mapfile or case-modifying expansions).
# ---------------------------------------------------------------------------

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
PERCEIVED_BRANCH="$SCRIPT_DIR/../../../scripts/perceived-branch.sh"

err() { printf 'gather-perceived-branch-evidence: %s\n' "$*" >&2; }
die() {
  local code="$1"
  shift
  err "$*"
  exit "$code"
}

usage() {
  sed -n '/^# USAGE$/,/^# OUTPUT/{
    /^# ---/d
    /^# USAGE$/d
    /^# OUTPUT/d
    s/^# \{0,1\}//
    p
  }' "${BASH_SOURCE[0]}"
}

TASK_ID=""
SESSION_ARGS=()

while [ $# -gt 0 ]; do
  case "$1" in
    -h | --help | help)
      usage
      exit 0
      ;;
    --session)
      [ $# -ge 2 ] || die 2 "--session needs a value"
      SESSION_ARGS=(--session "$2")
      shift 2
      ;;
    --session=*)
      SESSION_ARGS=(--session "${1#--session=}")
      shift
      ;;
    -*)
      die 2 "unknown option: $1"
      ;;
    *)
      [ -z "$TASK_ID" ] || die 2 "unexpected extra argument: $1"
      TASK_ID="$1"
      shift
      ;;
  esac
done

[ -n "$TASK_ID" ] || die 2 "missing <task_id> (usage: gather-perceived-branch-evidence.sh <task_id> [--session <key>])"
printf '%s\n' "$TASK_ID" | grep -Eq '^E[0-9]+(_S[0-9]+(_T[0-9]+)?)?$' ||
  die 2 "malformed task id (expected E##_S##_T##): $TASK_ID"

[ -x "$PERCEIVED_BRANCH" ] || die 4 "scripts/perceived-branch.sh not found or not executable at $PERCEIVED_BRANCH"
git rev-parse --git-dir >/dev/null 2>&1 || die 3 "not inside a git repository"

# ---------------------------------------------------------------------------
# Branch names, only through perceived-branch.sh
# ---------------------------------------------------------------------------
# Real branch. On a detached HEAD, get --real prints nothing and exits 1: search HEAD instead.
real_branch=""
real_rev="HEAD"
real_out="$("$PERCEIVED_BRANCH" get --real ${SESSION_ARGS[@]+"${SESSION_ARGS[@]}"} 2>/dev/null)"
real_rc=$?
case "$real_rc" in
  0) real_branch="$real_out" ;;
  1) real_branch="" ;;
  *) die 3 "could not determine the real branch (perceived-branch.sh get --real exited $real_rc)" ;;
esac
[ -z "$real_branch" ] || real_rev="refs/heads/$real_branch"

# Perceived branch. get --perceived prints only a set, still-existing branch (exit 0); otherwise it prints nothing
# and exits 1. A recorded-but-deleted branch is told apart from "nothing set" by the notice it writes on stderr,
# which names the branch, so the name is recovered without reading the state file here.
perceived_branch=""
perceived_stale="no"
perceived_rev=""
perc_err_file="$(mktemp 2>/dev/null)" || die 3 "could not create a temporary file"
trap 'rm -f "$perc_err_file"' EXIT
perc_out="$("$PERCEIVED_BRANCH" get --perceived ${SESSION_ARGS[@]+"${SESSION_ARGS[@]}"} 2>"$perc_err_file")"
perc_rc=$?
case "$perc_rc" in
  0)
    perceived_branch="$perc_out"
    perceived_rev="refs/heads/$perceived_branch"
    ;;
  1)
    stale_name="$(sed -n 's/^perceived-branch: note: perceived branch \(.*\) no longer exists; falling back.*$/\1/p' "$perc_err_file" | head -n 1)"
    if [ -n "$stale_name" ]; then
      perceived_branch="$stale_name"
      perceived_stale="yes"
    fi
    ;;
  2) die 2 "perceived-branch.sh rejected the arguments (malformed --session key?)" ;;
  3) die 3 "perceived-branch.sh reported a git problem" ;;
  *) die 5 "perceived-branch.sh reported a state problem (exit $perc_rc)" ;;
esac

# ---------------------------------------------------------------------------
# Evidence: does a commit reachable from <rev> name the task id?
# ---------------------------------------------------------------------------
# Prints yes/no. A git failure is reported by the caller through the exit status of this function.
branch_has_evidence() {
  local rev="$1" out
  out="$(git log "$rev" --max-count=1 --format=%H -E --grep="${TASK_ID}([^0-9_]|\$)" 2>/dev/null)" || return 1
  if [ -n "$out" ]; then
    printf 'yes\n'
  else
    printf 'no\n'
  fi
}

evidence_on_real="$(branch_has_evidence "$real_rev")" || die 3 "could not search history of ${real_branch:-HEAD}"
evidence_on_perceived="no"
if [ -n "$perceived_rev" ]; then
  if [ "$perceived_branch" = "$real_branch" ]; then
    evidence_on_perceived="$evidence_on_real"
  else
    evidence_on_perceived="$(branch_has_evidence "$perceived_rev")" || die 3 "could not search history of $perceived_branch"
  fi
fi

if [ "$evidence_on_real" = "yes" ] && [ "$evidence_on_perceived" = "yes" ]; then
  if [ "$perceived_branch" = "$real_branch" ]; then
    evidence_branch="real"
  else
    evidence_branch="both"
  fi
elif [ "$evidence_on_real" = "yes" ]; then
  evidence_branch="real"
elif [ "$evidence_on_perceived" = "yes" ]; then
  evidence_branch="perceived"
else
  evidence_branch="none"
fi

printf 'task_id=%s real_branch=%s perceived_branch=%s perceived_stale=%s evidence_on_real=%s evidence_on_perceived=%s evidence_branch=%s\n' \
  "$TASK_ID" "$real_branch" "$perceived_branch" "$perceived_stale" \
  "$evidence_on_real" "$evidence_on_perceived" "$evidence_branch"
exit 0
