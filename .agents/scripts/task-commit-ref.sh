#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# scripts/task-commit-ref.sh - the per-task commit ref store  (epic E79, story E79_S04, task E79_S04_T05)
#
# Commits 1..n of one task must carry the same ref even when the sources it was resolved from (a board file, the user's
# branch) change mid-task (solution assessment Problem 9, Solution A). The developer's sender object cannot be the only
# carrier: the agent composes it per call. This script keeps one small JSON file per task that the sender field and the
# commit composer both read:
#
#   * the ref found on the user's (perceived) branch is CAPTURED once, when the worktree is created, because the task
#     branch itself (E##_S##_T##-slug) never carries it;
#   * the ref the resolver settles on is FROZEN write-once, so a later call can only agree with it, never replace it.
#
# The store is neutral to precedence and to the unresolved-ref policy. The resolver decides which ref wins and what a
# disagreement means (it passes `--source` and `--conflict`); this script only stores that outcome.
#
# ---------------------------------------------------------------------------
# USAGE
# ---------------------------------------------------------------------------
#   task-commit-ref.sh capture-branch <task-id> --branch <name> [--candidate <ref>]
#   task-commit-ref.sh freeze         <task-id> --ref <value> --source task|story|epic|branch [--conflict <text>]...
#   task-commit-ref.sh get            <task-id> [--field ref|source|candidate]
#   task-commit-ref.sh clear          <task-id>
#   task-commit-ref.sh -h | --help    print this usage on stdout, exit 0
#
#   <task-id>   E##_S##_T##. It becomes a file name, so anything else is a usage error (exit 2) and nothing is created.
#
#   capture-branch  records the ref found in --branch (the branch NAME, passed as a value, never a command). The candidate
#                   comes from `commit-ref.sh extract` (the branch is sent on its stdin) unless --candidate supplies an
#                   already-extracted value. Either way it must pass `commit-ref.sh validate` before it is written. A
#                   branch with no key records branch_candidate: null and still exits 0 (the unresolved decision is
#                   made later, not here). Idempotent: once a task has captured, a second call changes nothing, exit 0.
#   freeze          validates --ref through `commit-ref.sh validate` BEFORE anything is written, then stores it with its
#                   --source and any --conflict texts. Write-once: the same ref again is exit 0 and changes nothing; a
#                   different ref is exit 4 and leaves the file untouched.
#   get             prints the frozen ref (default), its source, or the captured branch candidate. The value is
#                   re-validated on EVERY read, so a hand-edited or corrupted file yields exit 3 and prints nothing.
#   clear           removes the task's file. Exit 0 even when it is absent.
#
# ---------------------------------------------------------------------------
# THE STORE
# ---------------------------------------------------------------------------
#   <queue>/commit-refs/<task-id>.json, where <queue> is `scripts/resolve-root.sh --strict get queue` (never a
#   hardcoded project/ path; JENGA_PROJECT_ROOT redirects it). Fields: task_id, branch_candidate (string or null),
#   branch, captured_at, ref, source, frozen_at, conflicts (array). Fields not yet known are null (conflicts: []).
#   The directory is created on demand with mode 700, the file is 600. It is per-machine working state and git-ignored.
#   The location follows the working directory's project tree (or JENGA_PROJECT_ROOT): a developer inside a task
#   worktree reads and writes a worktree-local store, so every call for one task must run from the same place.
#
# SAFETY
#   * The ref and the branch name travel through argv and stdin only, never through a shell string. This file has no
#     dynamic-execution builtin, no shell-string invocation and no file inclusion (a bats case greps for them). The ref
#     is JSON-encoded by jq (--arg), never interpolated.
#   * `commit-ref.sh validate` is the only validator. Its output must equal its input byte for byte, so the one trailing
#     line feed it tolerates cannot enter the store.
#   * Writes are atomic (temp file in the same directory, jq check, then mv) and run under scripts/with-lock.sh, so the
#     compare-then-write of `freeze` is one critical section: of two concurrent freezes with different refs exactly one
#     wins and the other exits 4.
#   * A symlinked commit-refs directory or store file is refused (exit 6).
#
# ENVIRONMENT
#   JENGA_PROJECT_ROOT                   redirects the store (tests, and callers that hold a root).
#   JENGA_COMMIT_REF_EXTRACT_SCRIPT      replaces ONLY the script `capture-branch` asks to extract a candidate (default:
#                                        commit-ref.sh next to this file). Its result is validated by the real gate anyway.
#
# EXIT CODES
#   0  success (capture-branch, freeze incl. the identical repeat, get with a value, clear)
#   1  get: nothing is frozen / captured (not an error in itself)
#   2  usage error (unknown verb or option, a missing value, a task id that is not E##_S##_T##)
#   3  rejected: the ref (or candidate) fails the safety gate, or the store file is corrupted or hand-edited
#   4  freeze: a different ref is already frozen; the file is untouched
#   5  a dependency is unavailable: jq, the working-file root, the safety gate, or an extractor for capture-branch
#   6  the store could not be written, was refused (symlink), or the lock could not be taken
#   On any non-zero exit stdout is empty.
#
# Compatible with macOS bash 3.2 (no associative arrays, mapfile, ${var,,} or `&>>`). Requires jq.
# ---------------------------------------------------------------------------

set -u
export LC_ALL=C
umask 077

PROG="task-commit-ref"
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SELF="$here/task-commit-ref.sh"
GATE="$here/commit-ref.sh"
LOCKER="$here/with-lock.sh"
RESOLVER="$here/resolve-root.sh"

LOCKED=0
USAGE_RC=2
TMP=""
trap 'if [ -n "$TMP" ]; then rm -f "$TMP"; fi' EXIT

usage() {
  cat <<'EOF'
Usage:
  task-commit-ref.sh capture-branch <task-id> --branch <name> [--candidate <ref>]
  task-commit-ref.sh freeze         <task-id> --ref <value> --source task|story|epic|branch [--conflict <text>]...
  task-commit-ref.sh get            <task-id> [--field ref|source|candidate]
  task-commit-ref.sh clear          <task-id>
  task-commit-ref.sh -h | --help

Exit codes: 0 ok, 1 get: nothing frozen, 2 usage error, 3 rejected or corrupted, 4 freeze conflict (a different ref is
already frozen), 5 a dependency is unavailable, 6 the store could not be written or locked. See the header of this
script for the full contract.
EOF
}

die_usage() {
  printf '%s: usage error: %s\n' "$PROG" "$1" >&2
  [ "$LOCKED" -eq 1 ] || printf "Try '%s --help'.\n" "$PROG" >&2
  exit "$USAGE_RC"
}

fail() { # fail <exit-code> <message>
  printf '%s: %s\n' "$PROG" "$2" >&2
  exit "$1"
}

# --- arguments -------------------------------------------------------------------------------------------------

[ "$#" -ge 1 ] || die_usage "a verb is required (capture-branch, freeze, get, clear)"
case "$1" in
  -h|--help|help) usage; exit 0 ;;
  __locked) LOCKED=1; USAGE_RC=64; shift ;;
esac
[ "$#" -ge 1 ] || die_usage "a verb is required (capture-branch, freeze, get, clear)"
OP="$1"
shift
case "$OP" in
  capture-branch|freeze|get|clear) ;;
  *) die_usage "unknown verb (expected capture-branch, freeze, get or clear)" ;;
esac
[ "$#" -ge 1 ] || die_usage "$OP needs a task id (E##_S##_T##)"
ID="$1"
shift
REST=("$@")

# The task id becomes a file name: nothing outside A-Za-z0-9_ is allowed through, then the exact shape.
case "$ID" in
  ''|*[!A-Za-z0-9_]*) die_usage "the task id must look like E##_S##_T##" ;;
esac
idre='^E[0-9]+_S[0-9]+_T[0-9]+$'
[[ "$ID" =~ $idre ]] || die_usage "the task id must look like E##_S##_T##"

BRANCH=""; GOT_BRANCH=0
CANDIDATE=""; GOT_CANDIDATE=0
REF=""; GOT_REF=0
SOURCE=""; GOT_SOURCE=0
FIELD="ref"; GOT_FIELD=0
CONFLICTS=()

# Free text that is stored but never run: bounded and free of control characters.
check_text() { # check_text <what> <max-bytes> <value>
  case "$3" in
    *[[:cntrl:]]*) die_usage "$1 must not contain a control character" ;;
  esac
  [ "${#3}" -le "$2" ] || die_usage "$1 is longer than $2 characters"
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --branch)
      [ "$OP" = "capture-branch" ] || die_usage "--branch is only for capture-branch"
      [ "$#" -ge 2 ] || die_usage "--branch needs a value"
      [ "$GOT_BRANCH" -eq 0 ] || die_usage "--branch given twice"
      GOT_BRANCH=1; BRANCH="$2"; shift 2
      ;;
    --candidate)
      [ "$OP" = "capture-branch" ] || die_usage "--candidate is only for capture-branch"
      [ "$#" -ge 2 ] || die_usage "--candidate needs a value"
      [ "$GOT_CANDIDATE" -eq 0 ] || die_usage "--candidate given twice"
      GOT_CANDIDATE=1; CANDIDATE="$2"; shift 2
      ;;
    --ref)
      [ "$OP" = "freeze" ] || die_usage "--ref is only for freeze"
      [ "$#" -ge 2 ] || die_usage "--ref needs a value"
      [ "$GOT_REF" -eq 0 ] || die_usage "--ref given twice"
      GOT_REF=1; REF="$2"; shift 2
      ;;
    --source)
      [ "$OP" = "freeze" ] || die_usage "--source is only for freeze"
      [ "$#" -ge 2 ] || die_usage "--source needs a value"
      [ "$GOT_SOURCE" -eq 0 ] || die_usage "--source given twice"
      GOT_SOURCE=1; SOURCE="$2"; shift 2
      ;;
    --conflict)
      [ "$OP" = "freeze" ] || die_usage "--conflict is only for freeze"
      [ "$#" -ge 2 ] || die_usage "--conflict needs a value"
      [ "${#CONFLICTS[@]}" -lt 20 ] || die_usage "more than 20 --conflict values"
      check_text "--conflict" 300 "$2"
      CONFLICTS[${#CONFLICTS[@]}]="$2"; shift 2
      ;;
    --field)
      [ "$OP" = "get" ] || die_usage "--field is only for get"
      [ "$#" -ge 2 ] || die_usage "--field needs a value"
      [ "$GOT_FIELD" -eq 0 ] || die_usage "--field given twice"
      GOT_FIELD=1; FIELD="$2"; shift 2
      ;;
    *)
      die_usage "unknown option or unexpected argument for $OP"
      ;;
  esac
done

case "$OP" in
  capture-branch)
    [ "$GOT_BRANCH" -eq 1 ] || die_usage "capture-branch needs --branch <name>"
    [ -n "$BRANCH" ] || die_usage "--branch must not be empty"
    check_text "--branch" 255 "$BRANCH"
    ;;
  freeze)
    [ "$GOT_REF" -eq 1 ] || die_usage "freeze needs --ref <value>"
    [ "$GOT_SOURCE" -eq 1 ] || die_usage "freeze needs --source task|story|epic|branch"
    case "$SOURCE" in
      task|story|epic|branch) ;;
      *) die_usage "--source must be task, story, epic or branch" ;;
    esac
    ;;
  get)
    case "$FIELD" in
      ref|source|candidate) ;;
      *) die_usage "--field must be ref, source or candidate" ;;
    esac
    ;;
esac

# --- the store -------------------------------------------------------------------------------------------------

command -v jq >/dev/null 2>&1 || fail 5 "jq is required and was not found"
[ -f "$GATE" ] || fail 5 "the ref safety gate (commit-ref.sh) is missing"

QUEUE="$(bash "$RESOLVER" --strict get queue 2>/dev/null)" || fail 5 "cannot resolve the working-file queue directory (run inside a project or set JENGA_PROJECT_ROOT)"
[ -n "$QUEUE" ] || fail 5 "cannot resolve the working-file queue directory"
DIR="$QUEUE/commit-refs"
FILE="$DIR/$ID.json"
if [ -L "$DIR" ] || [ -L "$FILE" ]; then
  fail 6 "refusing a symbolic link in the commit ref store"
fi

# gate_check <value>: runs the one validator on the value (stdin) and sets VALIDATED. Returns 0 pass, 3 rejected, 5 the
# gate could not run. The output must equal the input, so a tolerated trailing line feed is not accepted here.
VALIDATED=""
gate_check() {
  local out rc
  out="$(printf '%s' "$1" | bash "$GATE" validate 2>/dev/null)"
  rc=$?
  case "$rc" in
    0) ;;
    3) return 3 ;;
    *) return 5 ;;
  esac
  [ "$out" = "$1" ] || return 3
  VALIDATED="$out"
  return 0
}

need_valid() { # need_valid <what> <value>: exits on a rejected value
  gate_check "$2"
  case "$?" in
    0) return 0 ;;
    3) fail 3 "$1 was rejected by the commit ref safety gate; nothing was written" ;;
    *) fail 5 "the commit ref safety gate could not run; nothing was written" ;;
  esac
}

# store_write: stdin becomes the file, atomically (temp file next to it, a jq check, then mv). Call it with a here-string,
# never at the end of a pipe: a pipe would run it in a subshell and swallow its exit status.
store_write() {
  TMP="$(mktemp "$DIR/.$ID.XXXXXX")" || fail 6 "cannot create a temporary file in the commit ref store"
  cat > "$TMP" || fail 6 "cannot write the commit ref store"
  jq -e 'type == "object"' "$TMP" >/dev/null 2>&1 || fail 6 "the new store content is not a JSON object; nothing was changed"
  mv -f "$TMP" "$FILE" || fail 6 "cannot replace the commit ref store file"
  TMP=""
}

# load_store: the existing file must be a JSON object that belongs to this task.
load_store() {
  jq -e --arg id "$ID" 'type == "object" and .task_id == $id' "$FILE" >/dev/null 2>&1 \
    || fail 3 "the store file is corrupted or does not belong to this task; run 'clear' to discard it"
}

now_utc() { date -u +%Y-%m-%dT%H:%M:%SZ; }

skeleton() {
  jq -n --arg id "$ID" '{task_id: $id, branch_candidate: null, branch: null, captured_at: null, ref: null, source: null, frozen_at: null, conflicts: []}'
}

# --- get (read only) -------------------------------------------------------------------------------------------

if [ "$OP" = "get" ]; then
  [ -e "$FILE" ] || exit 1
  load_store
  case "$FIELD" in
    candidate)
      state="$(jq -r 'if .branch_candidate == null then "none" elif (.branch_candidate | type) == "string" and (.branch_candidate | endswith("\n") | not) then "set" else "bad" end' "$FILE")"
      case "$state" in
        none) exit 1 ;;
        set) ;;
        *) fail 3 "the stored branch candidate is not a valid ref" ;;
      esac
      out="$(jq -j '.branch_candidate' "$FILE" | bash "$GATE" validate 2>/dev/null)" || fail 3 "the stored branch candidate failed the commit ref safety gate"
      printf '%s\n' "$out"
      exit 0
      ;;
    *)
      state="$(jq -r 'if .ref == null then "none" elif (.ref | type) == "string" and (.ref | endswith("\n") | not) then "set" else "bad" end' "$FILE")"
      case "$state" in
        none) exit 1 ;;
        set) ;;
        *) fail 3 "the stored ref is not a valid ref" ;;
      esac
      out="$(jq -j '.ref' "$FILE" | bash "$GATE" validate 2>/dev/null)" || fail 3 "the stored ref failed the commit ref safety gate"
      src="$(jq -r '.source' "$FILE")"
      case "$src" in
        task|story|epic|branch) ;;
        *) fail 3 "the stored source is not one of task, story, epic, branch" ;;
      esac
      if [ "$FIELD" = "source" ]; then
        printf '%s\n' "$src"
      else
        printf '%s\n' "$out"
      fi
      exit 0
      ;;
  esac
fi

# --- clear -----------------------------------------------------------------------------------------------------

if [ "$OP" = "clear" ] && [ "$LOCKED" -eq 0 ]; then
  [ -d "$DIR" ] || exit 0
fi

# --- run the mutating verbs under the lock ----------------------------------------------------------------------

if [ "$LOCKED" -eq 0 ]; then
  # Cheap rejections first, so a bad ref never creates a directory or takes a lock.
  case "$OP" in
    freeze) need_valid "the ref" "$REF" ;;
    capture-branch) [ "$GOT_CANDIDATE" -eq 0 ] || need_valid "the candidate" "$CANDIDATE" ;;
  esac
  [ -d "$DIR" ] || mkdir -p "$DIR" || fail 6 "cannot create the commit ref store directory"
  [ ! -L "$DIR" ] || fail 6 "refusing a symbolic link in the commit ref store"
  bash "$LOCKER" "$FILE" -- bash "$SELF" __locked "$OP" "$ID" ${REST[@]+"${REST[@]}"}
  rc=$?
  case "$rc" in
    2) fail 6 "could not take the lock on the commit ref store" ;;
    64) fail 2 "usage error" ;;
    *) exit "$rc" ;;
  esac
fi

# From here on this process holds the lock on $FILE.

case "$OP" in
  clear)
    rm -f "$FILE" || fail 6 "cannot remove the store file"
    exit 0
    ;;

  capture-branch)
    if [ -e "$FILE" ]; then
      load_store
      done_already="$(jq -r 'if (.captured_at | type) == "string" then "yes" else "no" end' "$FILE")"
      [ "$done_already" = "yes" ] && exit 0
    fi
    HAS=false
    CAND=""
    if [ "$GOT_CANDIDATE" -eq 1 ]; then
      need_valid "the candidate" "$CANDIDATE"
      CAND="$VALIDATED"
      HAS=true
    else
      extractor="${JENGA_COMMIT_REF_EXTRACT_SCRIPT:-$GATE}"
      [ -f "$extractor" ] || fail 5 "the extractor script is missing"
      out="$(printf '%s\n' "$BRANCH" | bash "$extractor" extract 2>/dev/null)"
      erc=$?
      case "$erc" in
        0)
          need_valid "the extracted candidate" "$out"
          CAND="$VALIDATED"
          HAS=true
          ;;
        1) ;;
        3) fail 3 "the extractor rejected the branch name; nothing was written" ;;
        *) fail 5 "cannot extract a candidate (commit-ref.sh has no usable 'extract' yet); pass --candidate <ref> instead" ;;
      esac
    fi
    if [ -e "$FILE" ]; then
      base="$(cat "$FILE")" || fail 6 "cannot read the store file"
    else
      base="$(skeleton)" || fail 6 "cannot build the store content"
    fi
    new="$(printf '%s' "$base" | jq --arg branch "$BRANCH" --arg cand "$CAND" --argjson has "$HAS" --arg now "$(now_utc)" \
      '.branch = $branch | .branch_candidate = (if $has then $cand else null end) | .captured_at = $now')" \
      || fail 6 "cannot build the store content"
    store_write <<< "$new"
    exit 0
    ;;

  freeze)
    need_valid "the ref" "$REF"
    if [ -e "$FILE" ]; then
      load_store
      if jq -e --arg r "$VALIDATED" '.ref == $r' "$FILE" >/dev/null 2>&1; then
        exit 0
      fi
      if jq -e '.ref != null' "$FILE" >/dev/null 2>&1; then
        fail 4 "a different ref is already frozen for this task; the store was not changed"
      fi
      base="$(cat "$FILE")" || fail 6 "cannot read the store file"
    else
      base="$(skeleton)" || fail 6 "cannot build the store content"
    fi
    conf='[]'
    for c in ${CONFLICTS[@]+"${CONFLICTS[@]}"}; do
      conf="$(printf '%s' "$conf" | jq -c --arg c "$c" '. + [$c]')" || fail 6 "cannot build the store content"
    done
    new="$(printf '%s' "$base" | jq --arg ref "$VALIDATED" --arg src "$SOURCE" --arg now "$(now_utc)" --argjson conf "$conf" \
      '.ref = $ref | .source = $src | .frozen_at = $now | .conflicts = $conf')" \
      || fail 6 "cannot build the store content"
    store_write <<< "$new"
    exit 0
    ;;
esac
