#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# scripts/apply-ref-policy.sh - turn the outcome of the commit ref resolution chain into the run-level contract
# (epic E79, story E79_S04, task E79_S04_T08; open decision 5, solution assessment Problem 10)
#
# An opted-in project puts a tracker key (for example ASD-001) into the commit messages of board work. scripts/resolve-commit-ref.sh
# walks the chain and REPORTS what it found; it does not say what an empty result means for the run. This wrapper does: Phase 1
# has exactly ONE unresolved-ref policy, `on_unresolved: fail` (open decision 5, answered 2026-10-26). A task whose ref cannot
# be resolved stops before its first commit, with a message that names the sources tried. There is no prompt, no silent fallback
# to EST naming and no placeholder ref, in interactive and in unattended (`j.jenga *`) runs alike. A different policy (for
# example a fallback literal) would be a schema change that regenerates goldens and a new task; this script has no code path
# that substitutes a ref, and never behaves as another policy.
#
# The script is read-only. It writes nothing to the per-task store, the board, the config or git, and it never reads from stdin
# or a terminal. It does not freeze the winner and it is not wired into /do or /jenga (later tasks).
#
# ---------------------------------------------------------------------------
# USAGE
# ---------------------------------------------------------------------------
#   apply-ref-policy.sh [--check] [--conventions <file>] [--root <dir>] <task-id>
#   apply-ref-policy.sh -h | --help             print this usage on stdout, exit 0
#
#   <task-id>             E##_S##_T##. Anything else is a usage error (exit 2).
#   --check               the same resolution with the same stdout, stderr and exit codes, plus the guarantee that nothing is
#                         ever written. It exists so a pre-flight (Problem 10) can report the tasks that will have no ref before
#                         any work is done, with a contract that survives a future real run that does write.
#   --conventions <file>  handed to commit-settings.sh and to the resolver unchanged (tests, and callers that hold the path).
#   --root <dir>          the project root to use, exactly as if JENGA_PROJECT_ROOT=<dir> were set (see TASK WORKTREES).
#
# ---------------------------------------------------------------------------
# WHAT IT DOES
# ---------------------------------------------------------------------------
#   1. `commit-settings.sh show` is read first. A project that is not opted in prints nothing there: this script then prints
#      nothing, exits 0 and never resolves a board path or opens a board file (the legacy path is untouched). A caller treats
#      empty output with exit 0 as "no commit ref in play".
#   2. The effective policy is the `on_unresolved` line of that output. Anything but `fail` (the validator rejects it already, so
#      this is a defensive refusal; a missing line counts too) is exit 7 with a message. It is never treated as another policy.
#   3. `resolve-commit-ref.sh <task-id>` runs with stdin from /dev/null and its exit status is mapped:
#        resolved (0)       its stdout is printed UNCHANGED (key=value lines: ref=, source=, tried=, candidate.<level>= and any
#                           line a later version adds, such as conflict=; this script reads none of them and depends on no order),
#                           exit 0.
#        not opted in (10)  nothing is printed, exit 0.
#        unresolved (1)     NOTHING on stdout, exit 6 and, on stderr, the message below.
#        2, 3, 5            passed on (usage error, settings unusable, dependency unavailable).
#        anything else      exit 5: the resolver broke its own contract.
#
# THE UNRESOLVED MESSAGE (stderr; exit 6)
#   apply-ref-policy: no commit ref could be resolved for <task-id>; sources tried: task external_refs, story external_refs,
#   epic external_refs, captured branch candidate (<branch or none>); on_unresolved=fail
#   apply-ref-policy: fix: link a Jira key with scripts/link-external-ref.sh, or create the task from a branch that carries one
# The list of sources comes from the `tried=` line of the resolver (only the levels it consulted, in its order; a level name
# it does not know is exit 5). <branch> is the branch name the store recorded when the task worktree was created
# (<queue>/commit-refs/<task-id>.json, field `branch`); `none` when nothing was captured, and `unprintable` when the stored name
# holds characters outside A-Za-z0-9._/@+- or is over 200 characters. Nothing in the message comes from the environment.
# The resolver's own notices (a rejected candidate, a level that could not be read) stay on stderr before it.
#
# ---------------------------------------------------------------------------
# NEVER INTERACTIVE
# ---------------------------------------------------------------------------
# No prompt, no `read`, no terminal device: stdin is never consulted, and every child runs with stdin from /dev/null. The
# behaviour is identical with stdin closed, from /dev/null, from a pipe that stays open, and with no controlling terminal.
# There is no EST fallback: on exit 6 no alternative subject, ref or placeholder is produced anywhere.
#
# ---------------------------------------------------------------------------
# TASK WORKTREES (where the captured candidate lives)
# ---------------------------------------------------------------------------
# The branch candidate is captured when the task worktree is created, by a process running in the MAIN working tree, so the
# store file sits under the main tree's queue directory. Settings, board and store all follow scripts/resolve-root.sh, so a
# reader running inside the task worktree would look at the worktree's own project tree and its own (empty) queue. Handling,
# deliberately and without any automatic redirection:
#   * `--root <dir>` (or JENGA_PROJECT_ROOT in the environment) names the project root to use; pass the main working tree
#     there when running from a task worktree. The settings, the resolver and the store all see it.
#   * When neither is set and the current directory is a linked git worktree, the unresolved message gets one more line saying
#     so, because "captured branch candidate (none)" would otherwise be misleading.
#
# EXIT CODES
#   0   resolved (key=value lines on stdout), or the project is not opted in (nothing on stdout)
#   2   usage error (unknown option, a missing value, a task id that is not E##_S##_T##)
#   3   the settings cannot be used (passed on from commit-settings.sh or the resolver)
#   5   a dependency is unavailable, or the resolver broke its contract
#   6   unresolved: the policy is `fail`; stdout is empty and the message above is on stderr
#   7   the effective on_unresolved is not `fail`; nothing else is attempted
#
# ENVIRONMENT
#   JENGA_PROJECT_ROOT   redirects the settings, the board and the store (tests, and callers holding a root).
#
# Compatible with macOS bash 3.2 (no associative arrays, mapfile, case-modifying expansions or `&>>`). It has no
# dynamic-execution builtin, no shell-string invocation and no file inclusion (a bats case greps for them).
# ---------------------------------------------------------------------------

set -u
export LC_ALL=C

PROG="apply-ref-policy"
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SETTINGS="$here/commit-settings.sh"
RESOLVE="$here/resolve-commit-ref.sh"
ROOTR="$here/resolve-root.sh"

NL='
'

usage() {
  cat <<'EOF'
Usage:
  apply-ref-policy.sh [--check] [--conventions <file>] [--root <dir>] <task-id>
  apply-ref-policy.sh -h | --help

Resolves the commit ref for a task and applies the Phase 1 policy on_unresolved=fail: key=value lines and exit 0 when a ref
is found or the project is not opted in (no output), exit 6 with a message naming the sources tried when none is found.
Exit codes: 0 resolved or not opted in, 2 usage error, 3 settings unusable, 5 dependency unavailable, 6 unresolved,
7 on_unresolved is not fail. See the header of this script for the contract.
EOF
}

die_usage() {
  printf '%s: usage error: %s\n' "$PROG" "$1" >&2
  printf "Try '%s --help'.\n" "$PROG" >&2
  exit 2
}

fail() { # fail <exit-code> <message>
  printf '%s: %s\n' "$PROG" "$2" >&2
  exit "$1"
}

# kv_get <text> <key>: prints the value of the first "key=value" line of <text> (split at the first "="). Returns 1 when the
# key is absent. Plain parameter expansion, so no line is ever executed and no input is read.
kv_get() {
  local rest="$1" key="$2" line
  while [ -n "$rest" ]; do
    case "$rest" in
      *"$NL"*)
        line="${rest%%"$NL"*}"
        rest="${rest#*"$NL"}"
        ;;
      *)
        line="$rest"
        rest=""
        ;;
    esac
    case "$line" in
      "$key="*)
        printf '%s' "${line#*=}"
        return 0
        ;;
    esac
  done
  return 1
}

# --- arguments -------------------------------------------------------------------------------------------------

ID=""
CONV=""
GOT_CONV=0
ROOT_GIVEN=0
CHECK=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --check) CHECK=1; shift ;;
    --conventions)
      [ "$#" -ge 2 ] || die_usage "--conventions needs a value"
      [ "$GOT_CONV" -eq 0 ] || die_usage "--conventions given twice"
      GOT_CONV=1
      CONV="$2"
      shift 2
      ;;
    --root)
      [ "$#" -ge 2 ] || die_usage "--root needs a value"
      [ "$ROOT_GIVEN" -eq 0 ] || die_usage "--root given twice"
      [ -n "$2" ] || die_usage "--root needs a non-empty value"
      [ -d "$2" ] || die_usage "--root is not a directory"
      ROOT_GIVEN=1
      JENGA_PROJECT_ROOT="$2"
      export JENGA_PROJECT_ROOT
      shift 2
      ;;
    -*)
      flag="${1%%=*}"
      die_usage "unknown option $flag"
      ;;
    *)
      [ -z "$ID" ] || die_usage "only one task id may be given"
      ID="$1"
      shift
      ;;
  esac
done

[ -n "$ID" ] || die_usage "a task id (E##_S##_T##) is required"
# The id is used as a file name below: only A-Za-z0-9_ is allowed through, then the exact shape.
case "$ID" in
  *[!A-Za-z0-9_]*) die_usage "the task id must look like E##_S##_T##" ;;
esac
TASK_RE='^E[0-9]+_S[0-9]+_T[0-9]+$'
[[ "$ID" =~ $TASK_RE ]] || die_usage "the task id must look like E##_S##_T##"

for dep in "$SETTINGS" "$RESOLVE" "$ROOTR"; do
  [ -f "$dep" ] || fail 5 "a required script is missing: $(basename "$dep")"
done

# --- step 1: settings and the opt-in gate (no board access before this point is passed) ------------------------------

if [ -n "$CONV" ]; then
  SHOW="$(bash "$SETTINGS" --conventions "$CONV" show </dev/null)"
else
  SHOW="$(bash "$SETTINGS" show </dev/null)"
fi
SRC=$?
case "$SRC" in
  0) ;;
  3) fail 3 "the commit settings cannot be used (commit-settings.sh exit 3)" ;;
  *) fail 5 "the commit settings could not be loaded (commit-settings.sh exit $SRC)" ;;
esac

# Not opted in: the legacy path. Nothing is printed, nothing is resolved, no board file is opened.
if [ -z "$SHOW" ]; then
  exit 0
fi

# --- step 2: the effective policy -------------------------------------------------------------------------------------

POLICY="$(kv_get "$SHOW" on_unresolved)" || POLICY=""
if [ "$POLICY" != "fail" ]; then
  if [ -z "$POLICY" ]; then
    fail 7 "the effective on_unresolved policy is missing; only 'fail' is supported in Phase 1"
  fi
  case "$POLICY" in
    *[!A-Za-z0-9_-]*) fail 7 "the effective on_unresolved policy is not 'fail' (and not a plain word); only 'fail' is supported in Phase 1" ;;
  esac
  fail 7 "the effective on_unresolved policy is '$POLICY'; only 'fail' is supported in Phase 1"
fi

# --- step 3: resolve and map the outcome ------------------------------------------------------------------------------

if [ -n "$CONV" ]; then
  OUT="$(bash "$RESOLVE" "$ID" --conventions "$CONV" </dev/null)"
else
  OUT="$(bash "$RESOLVE" "$ID" </dev/null)"
fi
RRC=$?

# branch_name: the branch recorded by the store when the worktree was created, or none / unprintable. Reads only.
branch_name() {
  local q f b
  if ! command -v jq >/dev/null 2>&1; then
    printf 'none'
    return 0
  fi
  q="$(bash "$ROOTR" --strict get queue 2>/dev/null </dev/null)" || q=""
  if [ -z "$q" ] || [ -L "$q/commit-refs" ]; then
    printf 'none'
    return 0
  fi
  f="$q/commit-refs/$ID.json"
  if [ ! -f "$f" ] || [ -L "$f" ]; then
    printf 'none'
    return 0
  fi
  b="$(jq -r 'if (.branch | type) == "string" then .branch else "" end' "$f" 2>/dev/null </dev/null)" || b=""
  if [ -z "$b" ]; then
    printf 'none'
    return 0
  fi
  if [ "${#b}" -gt 200 ]; then
    printf 'unprintable'
    return 0
  fi
  case "$b" in
    *[!A-Za-z0-9._/@+-]*) printf 'unprintable' ;;
    *) printf '%s' "$b" ;;
  esac
}

# in_linked_worktree: true when the current directory belongs to a linked git worktree (not the main working tree).
in_linked_worktree() {
  local gd gc
  command -v git >/dev/null 2>&1 || return 1
  gd="$(git rev-parse --git-dir 2>/dev/null </dev/null)" || return 1
  gc="$(git rev-parse --git-common-dir 2>/dev/null </dev/null)" || return 1
  gd="$(cd "$gd" 2>/dev/null && pwd -P)" || return 1
  gc="$(cd "$gc" 2>/dev/null && pwd -P)" || return 1
  [ "$gd" != "$gc" ]
}

case "$RRC" in
  0)
    printf '%s\n' "$OUT"
    exit 0
    ;;
  10)
    exit 0
    ;;
  2|3|5)
    exit "$RRC"
    ;;
  1)
    TRIED="$(kv_get "$OUT" tried)" || fail 5 "the resolver reported no ref but no tried= line (its contract was broken)"
    LIST=""
    REST="$TRIED"
    while [ -n "$REST" ]; do
      case "$REST" in
        *,*)
          lvl="${REST%%,*}"
          REST="${REST#*,}"
          ;;
        *)
          lvl="$REST"
          REST=""
          ;;
      esac
      case "$lvl" in
        task) name="task external_refs" ;;
        story) name="story external_refs" ;;
        epic) name="epic external_refs" ;;
        branch) name="captured branch candidate ($(branch_name))" ;;
        *) fail 5 "the resolver listed an unknown source level in tried= (its contract was broken)" ;;
      esac
      LIST="${LIST:+$LIST, }$name"
    done
    [ -n "$LIST" ] || fail 5 "the resolver listed no source level in tried= (its contract was broken)"
    printf '%s: no commit ref could be resolved for %s; sources tried: %s; on_unresolved=fail\n' "$PROG" "$ID" "$LIST" >&2
    printf '%s: fix: link a Jira key with scripts/link-external-ref.sh, or create the task from a branch that carries one\n' "$PROG" >&2
    if [ "$ROOT_GIVEN" -eq 0 ] && [ -z "${JENGA_PROJECT_ROOT:-}" ] && in_linked_worktree; then
      printf '%s: note: this is a linked git worktree; the captured branch candidate is stored under the main working tree, so pass --root <main working tree> (or set JENGA_PROJECT_ROOT) to consult it\n' "$PROG" >&2
    fi
    exit 6
    ;;
  *)
    fail 5 "the resolver ended with an unexpected exit status ($RRC)"
    ;;
esac
