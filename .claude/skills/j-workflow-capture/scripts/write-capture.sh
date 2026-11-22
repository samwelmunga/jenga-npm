#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# skills/j-workflow-capture/scripts/write-capture.sh - capture's own writer (epic E103, task E103_S02_T03)
#
# Turns a reviewed candidate-steps file into a captured recording, seals it and emits the workflow definition. It is
# the script-driven writer epic E103's decision 1 promised: capture does not need the recorder's hook, because it has
# every step up front, so this script appends them itself and the agent never calls `recording-file.sh append` by
# hand. Every write goes through the recorder's own scripts, unchanged (skills/j-workflow-recorder/scripts/):
#
#   recording-path.sh    where the recording goes (the same place a live recording goes)
#   recording-file.sh    create (with --source/--source-ref) and append, one call per candidate
#   close-recording.sh   the seal, explicit-path form only
#   emit-workflow.sh     the definition, validated by scripts/workflow/validate-workflow.sh
#
# THE POINTER IS NEVER READ OR WRITTEN (epic E103, decision 6). Every path here is explicit; nothing names, sets or
# clears the recorder's active-recording pointer, so a captured recording can never become the session's active
# recording and the UserPromptSubmit hook can never append the review conversation into it. One reused script
# does consult the pointer: close-recording.sh, even given a path, reads the pointer to decide whether to clear it.
# The seal therefore runs it with the pointer's documented directory override (JENGA_RECORDING_STATE_DIR) aimed at a
# private, empty directory created for that one call and removed afterwards, and a fixed session key, so it finds
# no pointer, clears nothing, and the session's real pointer is not even read. That is the whole of this script's
# contact with the pointer machinery, and it is why no recorder script had to change.
#
# ---------------------------------------------------------------------------
# USAGE
# ---------------------------------------------------------------------------
#   write-capture.sh create --source <kind> [--source-ref <ref>] [--dir <dir>] <candidates-file> <name...>
#   write-capture.sh seal <recording> <candidates-file>
#   write-capture.sh emit [--answer <step-id>=<type>]... <recording>
#   write-capture.sh -h | --help | help          this usage on stdout, exit 0
#
# create   Writes a new recording and prints its absolute path, one line, nothing else.
#          --source       session-transcript, external-url or pasted (from resolve-source.sh). `live` is refused:
#                         a live recording is j.workflow-recorder's, never capture's.
#          --source-ref   the resolver's source_ref; validated by recording-file.sh (a credential-shaped
#                         reference is refused, exit 2).
#          --dir          write the recording here instead of the documentation root (recording-path.sh --dir).
#          <name...>      the process name; it becomes the recording's title and, slugged, its file name and the
#                         emitted workflow's id.
#          The candidates file (render-review-table.sh's header is the contract) is checked first; an empty list
#          is refused. One step is appended per row, ordered by `n`, with the row's `text` verbatim, so row n is
#          step `step-%03d` of n - the contract record-review.sh relies on. The step ids are verified before the
#          recording is put in place.
#          WHOLE OR NOTHING: the recording is built in a hidden staging directory inside the destination
#          directory and moved into place with one mv only when every step is written and verified. A failure
#          leaves nothing at the recording's path. An existing file at the path is never overwritten (exit 8).
#
# seal     Seals a captured recording after the review and prints its path. Refused while
#          `record-review.sh pending <recording> <candidates-file>` lists a row (the rows are on stderr), and for a
#          recording whose source is `live`. An already-closed recording is a success that writes nothing (a
#          re-run after a failed emit is safe).
#
# emit     Runs emit-workflow.sh on a sealed captured recording, forwarding every --answer. Its stdout and exit
#          code are passed through UNCHANGED, so emit-workflow.sh's header is the contract: 0 prints the
#          definition's path, 4 the recording is not closed, 9 steps without a type (listed on stdout), 10 a type
#          that cannot be filled from the step's text, 8 the candidate failed validation. Refused (exit 11) for a
#          recording whose source is `live`.
#
# ---------------------------------------------------------------------------
# EXIT CODES (create and seal; emit passes emit-workflow.sh's through - including its 12, a confirmed parameter
# that cannot be applied (E103_S02_T04) - plus 2, 3, 6 and 11 below)
# ---------------------------------------------------------------------------
#   0   success; the recording's path on stdout (emit: the definition's path).
#   2   usage error: unknown sub-command or option, a missing argument, `--source live`, or a value
#       recording-file.sh refused (an unknown source, a credential-shaped source_ref). Nothing written.
#   3   the candidates file or the recording does not exist or is not readable.
#   4   the candidates file is not valid (render-review-table.sh's problems are on stderr). Nothing written.
#   5   the candidates file has no steps: there is nothing to record. Nothing written.
#   6   the environment is incomplete: jq or a sibling script is missing, or recording-path.sh could not
#       resolve the destination. Nothing written.
#   7   a write failed: the staging directory, create, an append, the step-id check or the final mv. Nothing is
#       left at the recording's path.
#   8   create: a file already exists at the recording's path (it is never overwritten). Nothing written.
#   9   seal: the review is not finished; the pending rows are on stderr. Nothing written.
#   10  seal: close-recording.sh refused or failed; its message is on stderr. The recording is unchanged.
#   11  seal/emit: the recording's source is `live`, so it is not a captured recording. Nothing written.
#
# ENVIRONMENT
#   JENGA_RECORDER_NOW    honoured by the recorder scripts (stamps); this script writes no time itself.
#   JENGA_RECORDING_DIR   honoured by recording-path.sh when --dir is not given.
#
# Compatible with macOS bash 3.2 (no associative arrays, mapfile or case-modifying expansions) and safe under
# `set -u`. Never uses the `LC_ALL=C <cmd>` prefix form (Homebrew bash 5.3 segfaults on it on some hosts).
# ---------------------------------------------------------------------------

set -u
export LC_ALL=C

SELF="$(basename "$0")"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RECORDER_DIR="$SCRIPT_DIR/../../j-workflow-recorder/scripts"
PATH_SCRIPT="$RECORDER_DIR/recording-path.sh"
FILE_SCRIPT="$RECORDER_DIR/recording-file.sh"
CLOSE_SCRIPT="$RECORDER_DIR/close-recording.sh"
EMIT_SCRIPT="$RECORDER_DIR/emit-workflow.sh"
FORMAT_LIB="$RECORDER_DIR/recording-format.sh"
RENDER="$SCRIPT_DIR/render-review-table.sh"
REVIEW="$SCRIPT_DIR/record-review.sh"

# The session key handed to close-recording.sh inside the private pointer directory. Any well-formed key works:
# the directory is empty, so no key can name a pointer there.
SEAL_SESSION_KEY='workflow-capture-seal'

STAGE_DIR=""

err() { printf '%s: %s\n' "$SELF" "$*" >&2; }
die() { local code="$1"; shift; err "$*"; exit "$code"; }

usage() {
  cat <<'USAGE'
usage:
  write-capture.sh create --source <kind> [--source-ref <ref>] [--dir <dir>] <candidates-file> <name...>
  write-capture.sh seal <recording> <candidates-file>
  write-capture.sh emit [--answer <step-id>=<type>]... <recording>
  write-capture.sh -h | --help | help

create  write a captured recording from a candidate-steps file (one step per row, in row order) and print its path
seal    seal it by explicit path once the review has nothing pending, and print its path
emit    emit the workflow definition (emit-workflow.sh, exit codes passed through) and print its path

<kind> is session-transcript, external-url or pasted. The session's active-recording pointer is never read or
written. Exit codes are in this script's header.
USAGE
}

cleanup_stage() {
  if [ -n "$STAGE_DIR" ] && [ -d "$STAGE_DIR" ]; then
    rm -rf "$STAGE_DIR"
  fi
  STAGE_DIR=""
}

require_scripts() {
  local f
  command -v jq >/dev/null 2>&1 || die 6 "jq is required but was not found"
  for f in "$@"; do
    [ -f "$f" ] || die 6 "a sibling script is missing: $f"
  done
}

require_readable() {
  [ -f "$1" ] || die 3 "no such $2: $1"
  [ -r "$1" ] || die 3 "$2 is not readable: $1"
}

# Refuses (exit 11) a recording whose source is live: seal and emit act on captured recordings only.
require_captured() {
  local src
  # shellcheck source=/dev/null
  . "$FORMAT_LIB"
  src="$(rec_source "$1")"
  if [ "$src" = "live" ]; then
    die 11 "$1 is a live recording (source: live), not a captured one; seal and emit it with j.workflow-recorder"
  fi
}

# ---------------------------------------------------------------------------
# create
# ---------------------------------------------------------------------------
cmd_create() {
  local source="" source_ref="" ref_given=0 dir="" cands="" name="" path="" destdir base staged
  local count i rc want got

  while [ "$#" -gt 0 ]; do
    case "$1" in
      --source) [ "$#" -ge 2 ] || die 2 "--source needs a value"; source="$2"; shift 2 ;;
      --source=*) source="${1#--source=}"; shift ;;
      --source-ref) [ "$#" -ge 2 ] || die 2 "--source-ref needs a value"; source_ref="$2"; ref_given=1; shift 2 ;;
      --source-ref=*) source_ref="${1#--source-ref=}"; ref_given=1; shift ;;
      --dir) [ "$#" -ge 2 ] || die 2 "--dir needs a value"; dir="$2"; shift 2 ;;
      --dir=*) dir="${1#--dir=}"; shift ;;
      --) shift; break ;;
      -*) usage >&2; die 2 "unknown option for create: $1" ;;
      *) break ;;
    esac
  done
  [ -n "$source" ] || { usage >&2; die 2 "create needs --source (session-transcript, external-url or pasted)"; }
  if [ "$source" = "live" ]; then
    die 2 "--source live is refused: a live recording belongs to j.workflow-recorder, not to capture"
  fi
  [ "$#" -ge 1 ] || { usage >&2; die 2 "create needs a candidates file"; }
  cands="$1"; shift
  [ "$#" -ge 1 ] || { usage >&2; die 2 "create needs a name for the recording"; }
  name="$*"

  require_scripts "$PATH_SCRIPT" "$FILE_SCRIPT" "$RENDER"
  require_readable "$cands" "candidates file"

  # The candidates file is checked in full before anything is derived or written.
  if ! bash "$RENDER" --check "$cands" >/dev/null; then
    die 4 "the candidates file is not valid: $cands; nothing was written"
  fi
  count="$(jq '.steps | length' "$cands")" || die 4 "could not count the candidate steps in $cands"
  [ "$count" -gt 0 ] || die 5 "the candidates file has no steps, so there is nothing to record; nothing was written"

  if [ -n "$dir" ]; then
    path="$(bash "$PATH_SCRIPT" --dir "$dir" "$name")"; rc=$?
  else
    path="$(bash "$PATH_SCRIPT" "$name")"; rc=$?
  fi
  if [ "$rc" -eq 2 ]; then
    die 2 "the name gives no usable recording file name: $name"
  elif [ "$rc" -ne 0 ] || [ -z "$path" ]; then
    die 6 "could not derive the recording's path (recording-path.sh exit $rc); nothing was written"
  fi
  destdir="$(dirname "$path")"
  base="$(basename "$path")"

  mkdir -p "$destdir" 2>/dev/null || die 7 "could not create the directory $destdir; nothing was written"
  STAGE_DIR="$(mktemp -d "$destdir/.capture-stage.XXXXXX" 2>/dev/null)" || {
    STAGE_DIR=""
    die 7 "could not create a staging directory in $destdir; nothing was written"
  }
  trap cleanup_stage EXIT INT TERM
  staged="$STAGE_DIR/$base"

  if [ "$ref_given" -eq 1 ]; then
    bash "$FILE_SCRIPT" create --source "$source" --source-ref "$source_ref" -- "$staged" "$name" >/dev/null; rc=$?
  else
    bash "$FILE_SCRIPT" create --source "$source" -- "$staged" "$name" >/dev/null; rc=$?
  fi
  if [ "$rc" -eq 2 ]; then
    die 2 "recording-file.sh refused the provenance (see its message above); nothing was written"
  elif [ "$rc" -ne 0 ]; then
    die 7 "recording-file.sh create failed (exit $rc); nothing was written"
  fi

  # One append per row, in `n` order, the row's text verbatim on stdin (multi-line text stays one step).
  i=0
  while [ "$i" -lt "$count" ]; do
    jq -j --argjson i "$i" '.steps | sort_by(.n) | .[$i].text' "$cands" \
      | bash "$FILE_SCRIPT" append "$staged" - >/dev/null
    rc=$?
    [ "$rc" -eq 0 ] || die 7 "appending candidate row $((i + 1)) failed (recording-file.sh exit $rc); nothing was written"
    i=$((i + 1))
  done

  # Row n must be step-%03d of n; anything else would send review answers to the wrong step.
  want="$(i=1; while [ "$i" -le "$count" ]; do printf 'step-%03d\n' "$i"; i=$((i + 1)); done)"
  got="$(bash "$FILE_SCRIPT" steps "$staged")" || die 7 "could not read the step ids back; nothing was written"
  [ "$got" = "$want" ] || die 7 "the written step ids are not step-001..step-$(printf '%03d' "$count"); nothing was written"

  if [ -e "$path" ]; then
    die 8 "refusing to overwrite an existing file: $path; nothing was written"
  fi
  mv "$staged" "$path" 2>/dev/null || die 7 "could not move the recording into place at $path; nothing was written"
  cleanup_stage
  trap - EXIT INT TERM

  printf '%s\n' "$path"
}

# ---------------------------------------------------------------------------
# seal
# ---------------------------------------------------------------------------
cmd_seal() {
  local rec cands state pending rc iso out

  [ "$#" -eq 2 ] || { usage >&2; die 2 "seal needs <recording> <candidates-file>"; }
  rec="$1"; cands="$2"
  require_scripts "$CLOSE_SCRIPT" "$REVIEW" "$FORMAT_LIB"
  require_readable "$rec" "recording"
  require_readable "$cands" "candidates file"
  require_captured "$rec"

  state="$(rec_frontmatter_value "$rec" status)"
  if [ "$state" = "closed" ]; then
    err "$rec is already sealed; nothing was written"
    printf '%s\n' "$rec"
    return 0
  fi

  pending="$(bash "$REVIEW" pending "$rec" "$cands")"; rc=$?
  if [ "$rc" -eq 1 ]; then
    err "the review is not finished; these rows still need a decision (row, what is missing):"
    printf '%s\n' "$pending" >&2
    exit 9
  elif [ "$rc" -ne 0 ]; then
    die 10 "record-review.sh pending failed (exit $rc); nothing was written"
  fi

  # The private pointer directory: see "THE POINTER IS NEVER READ OR WRITTEN" in the header.
  iso="$(mktemp -d "${TMPDIR:-/tmp}/workflow-capture-seal.XXXXXX" 2>/dev/null)" \
    || die 7 "could not create a private directory for the seal; nothing was written"
  out="$(env JENGA_RECORDING_STATE_DIR="$iso" JENGA_RECORDING_SESSION_ID="$SEAL_SESSION_KEY" \
    bash "$CLOSE_SCRIPT" "$rec" --session "$SEAL_SESSION_KEY")"; rc=$?
  rm -rf "$iso"
  if [ "$rc" -ne 0 ]; then
    die 10 "close-recording.sh failed (exit $rc); see its message above"
  fi
  [ -n "$out" ] || die 10 "close-recording.sh printed no path"
  printf '%s\n' "$rec"
}

# ---------------------------------------------------------------------------
# emit
# ---------------------------------------------------------------------------
cmd_emit() {
  local rec="" args=() rc

  while [ "$#" -gt 0 ]; do
    case "$1" in
      --answer) [ "$#" -ge 2 ] || die 2 "--answer needs <step-id>=<type>"; args+=("--answer" "$2"); shift 2 ;;
      --answer=*) args+=("--answer" "${1#--answer=}"); shift ;;
      -*) usage >&2; die 2 "unknown option for emit: $1" ;;
      *) [ -z "$rec" ] || die 2 "emit takes one recording"; rec="$1"; shift ;;
    esac
  done
  [ -n "$rec" ] || { usage >&2; die 2 "emit needs a recording"; }
  require_scripts "$EMIT_SCRIPT" "$FORMAT_LIB"
  require_readable "$rec" "recording"
  require_captured "$rec"

  if [ "${#args[@]}" -gt 0 ]; then
    bash "$EMIT_SCRIPT" "${args[@]}" "$rec"; rc=$?
  else
    bash "$EMIT_SCRIPT" "$rec"; rc=$?
  fi
  return "$rc"
}

main() {
  [ "$#" -ge 1 ] || { usage >&2; die 2 "no sub-command given"; }
  local sub="$1"; shift
  case "$sub" in
    -h|--help|help) usage; exit 0 ;;
    create) cmd_create "$@" ;;
    seal) cmd_seal "$@" ;;
    emit) cmd_emit "$@" ;;
    *) usage >&2; die 2 "unknown sub-command: $sub" ;;
  esac
}

main "$@"
exit $?
