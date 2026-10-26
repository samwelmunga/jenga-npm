#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# scripts/prepare-task-commit-ref.sh - the single developer entry point that resolves and freezes a task's commit ref
# (epic E79, story E79_S04, task E79_S04_T10; solution assessment Problems 9 and 10)
#
# agents/developer.md only calls scripts, so "resolve the ref, apply the unresolved-ref policy, freeze the result" lives here as one
# deterministic sequence. This script adds NO resolution logic of its own: it composes
#   scripts/commit-settings.sh      is the project opted in?                        (E79_S03)
#   scripts/task-commit-ref.sh      the per-task store: get a frozen ref, freeze    (T05)
#   scripts/apply-ref-policy.sh     the resolution chain (T06, T07) + on_unresolved=fail (T08)
# and decides only what to do with their outcomes. It is called ONCE per task, before the task's first commit; commits 1..n then
# read the frozen ref (`task-commit-ref.sh get`), so they agree even when the sources change mid-task.
#
# ---------------------------------------------------------------------------
# USAGE
# ---------------------------------------------------------------------------
#   prepare-task-commit-ref.sh [--on-conflict warn|fail] [--conventions <file>] [--root <dir>] <task-id>
#   prepare-task-commit-ref.sh -h | --help       print this usage on stdout, exit 0
#
#   <task-id>             E##_S##_T##. Anything else is a usage error (exit 2).
#   --on-conflict <p>     what to do when the sources carry different keys (epic E79 decision 8): warn (the default; continue
#                         with the precedence winner task, story, epic, branch, and record the others) or fail (stop, freeze
#                         nothing, exit 8). Phase 1 default is warn.
#   --conventions <file>  handed to commit-settings.sh and apply-ref-policy.sh unchanged (tests, and callers holding the path).
#   --root <dir>          the project root to use, exactly as if JENGA_PROJECT_ROOT=<dir> were set (see TASK WORKTREES).
#
# ---------------------------------------------------------------------------
# WHAT IT DOES
# ---------------------------------------------------------------------------
#   1. NOT OPTED IN. `commit-settings.sh opted-in` exits 1: print nothing, create nothing (no store directory, no file, no lock),
#      exit 0. This is the default-off guarantee in one place; a project that has not opted in never reaches the rest.
#   2. ALREADY FROZEN. `task-commit-ref.sh get <task-id>` has a ref: print `commit_ref=` and `source=` for it and exit 0 without
#      resolving, so a second call in the same task is a no-op (and --on-conflict is not consulted). The conflict lines are
#      printed only by the call that froze; the frozen path prints just these two lines.
#   3. RESOLVE. Otherwise `apply-ref-policy.sh <task-id>` runs (resolution chain + the unresolved policy). Unresolved is exit 6
#      with ITS message on stderr passed through unchanged and an empty stdout; nothing is written.
#   4. DISAGREEMENT. The resolver reports a disagreement as `conflict=<level>:<key>` lines next to the winner. Under warn they are
#      kept and recorded; under --on-conflict fail any such line stops the run (exit 8, nothing frozen, every level and key named).
#      This script does not compare keys itself: a `conflict=` line from the resolver IS the disagreement.
#   5. FREEZE. `task-commit-ref.sh freeze <task-id> --ref .. --source .. [--conflict ..]...` (write-once; validation of the ref by
#      the safety gate happens inside the store before anything is written), then print the result.
#
# ---------------------------------------------------------------------------
# OUTPUT (stdout; key=value lines, read with `read` or jq and NEVER sourced; a value never holds a newline)
# ---------------------------------------------------------------------------
#   commit_ref=<ref>          the frozen ref, for example ASD-001
#   source=<level>            task, story, epic or branch: where the ref came from
#   conflict=<level>:<key>    one line per recorded disagreement (only from the call that froze it, only under warn)
# Not opted in: nothing at all. On any non-zero exit stdout is empty; messages are on stderr and are not parsed by a caller.
# Note the key is `commit_ref=`, not the resolver's `ref=`: the two outputs are different contracts.
#
# ---------------------------------------------------------------------------
# EXIT CODES
# ---------------------------------------------------------------------------
# Most codes are passed on from the script that produced them. Two of them are not, because passing them on would give one number
# two meanings for the developer who reads it; both are marked NEW. (The task text had 5 for a disagreement under fail, but 5
# already means "dependency unavailable" in all three scripts called here, and the resolver's own disagreement code since T07 is 7,
# which apply-ref-policy.sh uses for "on_unresolved is not fail". The task text also said to pass the store's exit codes through,
# but its 6 means "store not writable" while apply-ref-policy.sh's 6 means "unresolved".)
#   0   ready (the three kinds of line above are on stdout), or not opted in (nothing on stdout)
#   2   usage error (unknown option, a missing value, a task id that is not E##_S##_T##)
#   3   rejected: the settings cannot be used (invalid conventions file), or the safety gate or the store rejected the ref or
#       its file (passed on from commit-settings.sh, apply-ref-policy.sh or task-commit-ref.sh)
#   4   freeze conflict: a different ref is already frozen for the task; the store is untouched (passed on from the store)
#   5   a dependency is unavailable (jq, a sibling script, the working-file root), or a called script broke its contract
#   6   unresolved under on_unresolved=fail: no source gave a ref; empty stdout, apply-ref-policy.sh's message on stderr
#   7   the effective on_unresolved is not `fail` (passed on from apply-ref-policy.sh)
#   8   NEW: the sources disagree and --on-conflict fail was given; nothing was frozen
#   9   NEW: the store could not be read, written or locked (a symbolic link in the store, a lock that could not be taken, a
#       write failure); this is the store's own exit 6, renamed so 6 stays "unresolved"
#   Any other status of a called script is exit 5.
#
# ---------------------------------------------------------------------------
# NEVER INTERACTIVE
# ---------------------------------------------------------------------------
# No prompt, no `read`, no terminal device: stdin is never consulted and every child runs with stdin from /dev/null, so the
# result is identical with stdin closed, from /dev/null or from an open pipe. There is no EST fallback anywhere: on exit 6 no
# alternative subject, ref or placeholder is produced.
#
# ---------------------------------------------------------------------------
# TASK WORKTREES (the one place a caller must be deliberate)
# ---------------------------------------------------------------------------
# The branch candidate is captured when the task worktree is created, by a process running in the MAIN working tree, so it lives
# under the MAIN tree's queue directory. Settings, board and store follow scripts/resolve-root.sh, so a developer running this from
# inside the task worktree would otherwise look at the worktree's own project tree and its own (empty) queue. The caller names
# the main working tree deliberately, and the same way every time:
#     prepare-task-commit-ref.sh --root <main working tree> <task-id>        (or JENGA_PROJECT_ROOT=<main working tree>)
# Capture, resolve, freeze and every later read then use one store. There is no automatic redirection. A caller that gives a root
# for one call and none for the next would freeze into two places; `task-commit-ref.sh get` must also be given the same root.
#
# SAFETY
#   * The ref is handed to the store as the value of `--ref` (argv), after the resolver and the store's gate both validated it; it
#     is never alone as an argv word and never goes through a shell string or a command substitution that is executed. The
#     conflict texts are re-checked against a character allowlist before they are passed on or printed.
#   * The output of the called scripts is data: it is split with parameter expansion, never executed or sourced.
#   * Nothing is written on any path except the store's own freeze; this script creates no file and no directory of its own.
#
# ENVIRONMENT
#   JENGA_PROJECT_ROOT   redirects the settings, the board and the store (tests, and callers holding a root).
#
# Compatible with macOS bash 3.2 (no associative arrays, mapfile, case-modifying expansions or `&>>`). It has no dynamic-execution
# builtin, no shell-string invocation and no file inclusion (a bats case greps for them) and no `read` builtin.
# ---------------------------------------------------------------------------

set -u
export LC_ALL=C

PROG="prepare-task-commit-ref"
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SETTINGS="$here/commit-settings.sh"
STORE="$here/task-commit-ref.sh"
APPLY="$here/apply-ref-policy.sh"

NL='
'

usage() {
  cat <<'EOF'
Usage:
  prepare-task-commit-ref.sh [--on-conflict warn|fail] [--conventions <file>] [--root <dir>] <task-id>
  prepare-task-commit-ref.sh -h | --help

Resolves the commit ref for a task once, applies the unresolved-ref policy, freezes it and prints key=value lines
(commit_ref, source, conflict). Prints nothing and exits 0 for a project that is not opted in; a second call returns the frozen ref.
Exit codes: 0 ready or not opted in, 2 usage, 3 rejected, 4 freeze conflict, 5 dependency or broken contract, 6 unresolved,
7 on_unresolved is not fail, 8 disagreement under --on-conflict fail, 9 store unusable (symlink, lock or write failure).
From a task worktree pass --root <main working tree>. See the header of this script for the contract.
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

# kv_get <text> <key>: prints the value of the first "key=value" line of <text> (split at the first "="). Returns 1 when the key
# is absent. Plain parameter expansion: no line is ever executed and no input is read.
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

# store_fail <rc> <what>: exits with the status of a task-commit-ref.sh call that is not a success, mapped for this script (the
# message the store printed on stderr has already been shown). 1 (nothing frozen) is handled by the callers, not here.
store_fail() {
  case "$1" in
    3) exit 3 ;;
    4) exit 4 ;;
    5) exit 5 ;;
    6) exit 9 ;;
    *) fail 5 "$2 ended with an unexpected exit status ($1)" ;;
  esac
}

# --- arguments -------------------------------------------------------------------------------------------------

ID=""
CONV=""
GOT_CONV=0
ROOT_GIVEN=0
CONFLICT_POLICY="warn"
GOT_POLICY=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --on-conflict)
      [ "$#" -ge 2 ] || die_usage "--on-conflict needs a value (warn or fail)"
      [ "$GOT_POLICY" -eq 0 ] || die_usage "--on-conflict given twice"
      GOT_POLICY=1
      case "$2" in
        warn|fail) CONFLICT_POLICY="$2" ;;
        *) die_usage "--on-conflict must be warn or fail" ;;
      esac
      shift 2
      ;;
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
# The id becomes a file name in the store: only A-Za-z0-9_ is allowed through, then the exact shape.
case "$ID" in
  *[!A-Za-z0-9_]*) die_usage "the task id must look like E##_S##_T##" ;;
esac
TASK_RE='^E[0-9]+_S[0-9]+_T[0-9]+$'
[[ "$ID" =~ $TASK_RE ]] || die_usage "the task id must look like E##_S##_T##"

for dep in "$SETTINGS" "$STORE" "$APPLY"; do
  [ -f "$dep" ] || fail 5 "a required script is missing: $(basename "$dep")"
done

# --- step 1: the opt-in gate (nothing is created or opened before this point is passed) -----------------------------

if [ -n "$CONV" ]; then
  bash "$SETTINGS" --conventions "$CONV" opted-in </dev/null >/dev/null
else
  bash "$SETTINGS" opted-in </dev/null >/dev/null
fi
OPT=$?
case "$OPT" in
  0) ;;
  1) exit 0 ;;
  3) fail 3 "the commit settings cannot be used (commit-settings.sh exit 3)" ;;
  *) fail 5 "the commit settings could not be loaded (commit-settings.sh exit $OPT)" ;;
esac

# --- step 2: an already frozen ref is returned as it is (no re-resolution) ---------------------------------------------

FROZEN="$(bash "$STORE" get "$ID" </dev/null)"
GRC=$?
case "$GRC" in
  0)
    FSRC="$(bash "$STORE" get "$ID" --field source </dev/null)"
    SRC_RC=$?
    [ "$SRC_RC" -eq 0 ] || store_fail "$SRC_RC" "reading the frozen source"
    [ -n "$FROZEN" ] || fail 5 "the store reported a frozen ref but printed none (its contract was broken)"
    case "$FSRC" in
      task|story|epic|branch) ;;
      *) fail 5 "the store printed an unknown source level (its contract was broken)" ;;
    esac
    printf 'commit_ref=%s\nsource=%s\n' "$FROZEN" "$FSRC"
    exit 0
    ;;
  1) ;;
  *) store_fail "$GRC" "reading the store" ;;
esac

# --- step 3: resolve and apply the unresolved-ref policy ---------------------------------------------------------------

# stdout is captured, so no failure path ever prints anything on stdout. stderr is inherited: the resolver's notices and the
# policy message (exit 6) reach the caller unchanged.
if [ -n "$CONV" ]; then
  OUT="$(bash "$APPLY" --conventions "$CONV" "$ID" </dev/null)"
else
  OUT="$(bash "$APPLY" "$ID" </dev/null)"
fi
ARC=$?
case "$ARC" in
  0) ;;
  2|3|5|6|7) exit "$ARC" ;;
  *) fail 5 "apply-ref-policy.sh ended with an unexpected exit status ($ARC)" ;;
esac

REF="$(kv_get "$OUT" ref)" || REF=""
RSRC="$(kv_get "$OUT" source)" || RSRC=""
[ -n "$REF" ] || fail 5 "the resolver reported success but no ref= line (its contract was broken); nothing was frozen"
case "$RSRC" in
  task|story|epic|branch) ;;
  *) fail 5 "the resolver reported an unknown source level (its contract was broken); nothing was frozen" ;;
esac

# --- step 4: disagreements (the resolver's own conflict= lines) --------------------------------------------------------

CONFLICTS=()
CLIST=""
REST="$OUT"
while [ -n "$REST" ]; do
  case "$REST" in
    *"$NL"*)
      line="${REST%%"$NL"*}"
      REST="${REST#*"$NL"}"
      ;;
    *)
      line="$REST"
      REST=""
      ;;
  esac
  case "$line" in
    conflict=*)
      val="${line#conflict=}"
      case "$val" in
        ''|*[!A-Za-z0-9._:/@+-]*) fail 5 "the resolver printed a conflict line with unexpected characters (its contract was broken); nothing was frozen" ;;
      esac
      CONFLICTS[${#CONFLICTS[@]}]="$val"
      CLIST="${CLIST:+$CLIST, }$val"
      ;;
  esac
done

if [ "$CONFLICT_POLICY" = "fail" ] && [ "${#CONFLICTS[@]}" -gt 0 ]; then
  case "$REF" in
    *[!A-Za-z0-9._:/@+-]*) REFTXT="(unprintable)" ;;
    *) REFTXT="$REF" ;;
  esac
  printf '%s: the sources disagree for %s: precedence winner %s from %s, also found %s; --on-conflict fail: nothing was frozen\n' "$PROG" "$ID" "$REFTXT" "$RSRC" "$CLIST" >&2
  printf '%s: note: a "continuing with" notice from the resolver above is its default warn text; it was not acted on\n' "$PROG" >&2
  printf '%s: fix: make the task, story, epic and branch carry the same key, or run without --on-conflict fail to continue with the precedence winner\n' "$PROG" >&2
  exit 8
fi

# --- step 5: freeze (write-once; the store validates the ref before it writes) ----------------------------------------

FARGS=(freeze "$ID" --ref "$REF" --source "$RSRC")
for c in ${CONFLICTS[@]+"${CONFLICTS[@]}"}; do
  FARGS[${#FARGS[@]}]="--conflict"
  FARGS[${#FARGS[@]}]="$c"
done
bash "$STORE" "${FARGS[@]}" </dev/null >/dev/null
FRC=$?
case "$FRC" in
  0) ;;
  2) exit 2 ;;
  *) store_fail "$FRC" "freezing the ref" ;;
esac

printf 'commit_ref=%s\nsource=%s\n' "$REF" "$RSRC"
for c in ${CONFLICTS[@]+"${CONFLICTS[@]}"}; do
  printf 'conflict=%s\n' "$c"
done
exit 0
