#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# skills/j-reconcile/scripts/commit-evidence.sh - /j-reconcile's "is there commit evidence for this task" lookup
# (epic E79, story E79_S02, task E79_S02_T06)
#
# /j-reconcile Phase 2 (verify a "completed" task) and Phase 3 (is an "incomplete" task secretly implemented) both
# start with a git-history search by task id. That used to be an inline `git log --all --oneline --grep="<id>"` in
# SKILL.md prose (audit rows M8 and M9 in project/documentation/commit-consumer-audit.md). It now lives here and
# resolves through the shared resolver scripts/commits-for-item.sh, so reconcile finds a task's commits the same way
# close-story and mark-merged do (EST subject, any message naming the id, or a `Jenga-Task:` trailer).
#
# Why a wrapper rather than calling the resolver straight from SKILL.md: Phase 2 is the one consumer whose empty
# result can demote a completed task to Pending, so "empty" has to be told apart from "history unavailable" before
# the agent acts on it. The resolver already knows (exit 1 versus exit 3 under --require-nonempty); this script asks
# it that way and translates, so the shallow-clone test is not re-implemented here.
#
# ---------------------------------------------------------------------------
# USAGE
# ---------------------------------------------------------------------------
#   commit-evidence.sh <task_id> [--repo <dir>]
#   commit-evidence.sh -h | --help            print this usage on stdout, exit 0
#
#   <task_id>   a board id (E##_S##_T## for reconcile; the resolver also accepts E## and E##_S##)
#   --repo      the repository to search (default: the current directory)
#
# ---------------------------------------------------------------------------
# OUTPUT (stdout) AND EXIT STATUS
# ---------------------------------------------------------------------------
# The first line is always `status: <found|none|unavailable>`; reconcile reads that line, not the exit code.
#
#   status: found         one or more commits carry the id. Followed by `count: <N>` and one
#                         `<short-sha> <subject>` line per commit (what `git log --oneline` printed), newest first.
#                         A matching commit is strong evidence of implementation.
#   status: none          no commit carries the id, in a repository with full history. This is "no evidence",
#                         not an error: reconcile falls through to its other checks exactly as before.
#   status: unavailable   no commit was found AND the repository is a shallow clone, so the history that would
#                         hold the commit may simply not be present. This is NOT "no evidence": reconcile must
#                         not demote a completed task on the strength of it (commit-traceability-contract.md
#                         section 5.6 cell O3.H6, "cannot verify (shallow)").
#
#   0   one of the three statuses above was printed (an empty result is a legitimate answer, never an error)
#   2   usage error (unknown flag, missing or extra argument, malformed id)
#   4   the lookup itself could not run: the resolver is missing, or git failed (not a git repository, ...)
#       Nothing is printed on stdout in that case; the cause is on stderr. Treat it as "cannot verify".
#
# Bash 3.2 compatible (macOS); no jq, no associative arrays.
# ---------------------------------------------------------------------------

set -u

SELF="commit-evidence.sh"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() { sed -n '2,/^# Bash 3.2/p' "$0" | sed 's/^# \{0,1\}//'; }
die() { printf '%s: %s\n' "$SELF" "$1" >&2; exit "$2"; }

id=""
repo=""
while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --repo)
      [ $# -ge 2 ] || die "--repo needs a directory" 2
      repo="$2"; shift 2 ;;
    --repo=*) repo="${1#--repo=}"; shift ;;
    -*) die "unknown argument: $1" 2 ;;
    *)
      [ -z "$id" ] || die "unexpected extra argument: $1" 2
      id="$1"; shift ;;
  esac
done
[ -n "$id" ] || die "usage: $SELF <task_id> [--repo <dir>]" 2

# Locate the resolver: repo layout first (skills/j-reconcile/scripts -> scripts), then a consumer's scripts/, then
# the installed package.
RESOLVER=""
for cand in "$SCRIPT_DIR/../../../scripts/commits-for-item.sh" \
            "scripts/commits-for-item.sh" \
            "node_modules/@jenga-ai/agent/scripts/commits-for-item.sh"; do
  if [ -f "$cand" ]; then RESOLVER="$cand"; break; fi
done
[ -n "$RESOLVER" ] || die "cannot find scripts/commits-for-item.sh (searched next to this skill, ./scripts, node_modules/@jenga-ai/agent/scripts)" 4

args=("$id" --require-nonempty)
[ -z "$repo" ] || args=("$id" --require-nonempty --repo "$repo")

err="$(mktemp 2>/dev/null)" || die "cannot create a temp file" 4
trap 'rm -f "$err"' EXIT

out="$(bash "$RESOLVER" "${args[@]}" 2>"$err")"
rc=$?

case "$rc" in
  0)
    count="$(printf '%s\n' "$out" | grep -c .)"
    printf 'status: found\ncount: %s\n' "$count"
    # Same shape as the old `git log --all --oneline` lines. --no-walk=unsorted keeps the resolver's order.
    printf '%s\n' "$out" | git -C "${repo:-.}" log --no-walk=unsorted --format='%h %s' --stdin 2>/dev/null \
      || printf '%s\n' "$out"
    exit 0 ;;
  1)
    printf 'status: none\n'
    exit 0 ;;
  3)
    printf 'status: unavailable\n'
    # Say why on stderr so the report can quote it; stdout stays machine-readable.
    cat "$err" >&2
    exit 0 ;;
  2)
    cat "$err" >&2
    exit 2 ;;
  *)
    cat "$err" >&2
    exit 4 ;;
esac
