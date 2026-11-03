#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# skills/j-workflow-recorder/scripts/close-recording.sh - the sealing layer (epic E89, task E89_S03_T03)
#
# Seals a recording once the user has confirmed that the process being recorded has ENDED. Deciding that it has
# ended is judgment and lives in the skill body's interrogation points; everything that happens afterwards is
# deterministic and is the whole of this script:
#
#   1. mark the recording closed in its frontmatter, with the closing timestamp;
#   2. then clear the active-recording pointer;
#   3. then print the closed recording's path on stdout, and nothing else, so the workflow-definition emitter
#      can be invoked on it.
#
# THE ORDER IN THAT LIST IS THE POINT OF THE SCRIPT, not an implementation detail. The pointer is cleared only
# after the frontmatter write has landed. Clearing first and then failing the write would leave the session with
# an UNCLOSED recording that nothing points at any more - a document still open for appends that no later turn
# can find. The reverse failure (closed document, pointer still set) is recoverable and visible, and it is also
# guarded against directly: see "WHAT STOPS A SEALED RECORDING BEING APPENDED TO" below.
#
# Like recording-file.sh and record-answer.sh, this script DERIVES NO PATHS AND RESOLVES NO ROOTS. The recording
# path is either an argument or comes from the pointer, and the two sibling scripts it calls are located relative
# to this file. There is no working-tree literal anywhere in it.
#
# ---------------------------------------------------------------------------
# USAGE - THE INTERFACE OTHER WORK CODES AGAINST
# ---------------------------------------------------------------------------
#   close-recording.sh [<path>] [--reason <text>] [--session <key>] [--if-open]
#   close-recording.sh --state [<path>] [--session <key>]
#   close-recording.sh -h | --help | help          print this usage on stdout, exit 0
#
# THE BARE FORM IS THE CONTRACT. `close-recording.sh` with no arguments closes the recording named by the active
# pointer and prints its path. That is the form SKILL.md's `stop` route documents and the form the end-of-process
# handoff calls; it does not change. Everything else below is ADDITIVE and optional.
#
#   <path>            the recording to seal. Omitted, it is read from the active pointer
#                     (active-recording.sh get). Given, it is sealed whether or not it is the active one - see
#                     "WHEN THE POINTER NAMES A DIFFERENT RECORDING" below for what happens to the pointer then.
#
#   --reason <text>   record WHY the recording was closed, as `closed_reason: "<text>"` in the frontmatter.
#                     Free text, one line. Omitted, no closed_reason key is written at all - an absent key means
#                     "closed the ordinary way, on a confirmed end of process", so the ordinary case carries no
#                     marker to interpret. Intended for a caller that is NOT a confirmed end of process, such as
#                     a session-end close-out (`--reason session-end`), so the record distinguishes the two.
#
#   --session <key>   the session key for the pointer operations, forwarded verbatim to active-recording.sh.
#                     For a caller that knows the session it is acting for rather than inheriting it from the
#                     environment - a hook reading a session id out of its stdin payload, for instance.
#
#   --if-open         make an already-closed recording a SUCCESS instead of a refusal: exit 0, print the path,
#                     write nothing. For a caller that may run more than once over the same recording and has
#                     no way to know whether an earlier run already sealed it. Without it, a second close is
#                     refused (exit 6) - which is the default precisely because a user asking to stop twice has
#                     almost certainly lost track of which recording is live, and a silent second success would
#                     hide that.
#
#   --state           read-only. Print `open` or `closed` for the recording and exit 0. Does not write, does not
#                     touch the pointer. For a caller deciding whether there is anything to do before it asks
#                     the user anything.
#
# STDOUT, exactly:
#   - a successful close (and a `--if-open` no-op close): the sealed recording's path, one line, nothing else.
#   - `--state`: the single word `open` or `closed`.
#   - `--help`: this usage block.
#   - every refusal and every failure: NOTHING. Diagnostics go to stderr.
#   The one deliberate exception is exit 8, where the path IS printed - see the exit code table.
#
# The path printed is the path as RESOLVED, verbatim: the argument exactly as given, or exactly what the pointer
# stored. It is never rewritten into an absolute form, for the same reason active-recording.sh's `get` prints
# back exactly what `set` was given - a caller that wants an absolute path passes one (recording-path.sh always
# produces one). Path comparison for the pointer is a separate matter and does resolve directories, so the two
# spellings of one recording are still recognised as the same recording.
#
# ---------------------------------------------------------------------------
# WHAT STOPS A SEALED RECORDING BEING APPENDED TO
# ---------------------------------------------------------------------------
# Two independent mechanisms, and NEITHER of them is the pointer's TTL:
#
#   1. THE POINTER IS CLEARED, explicitly, by this script. The capture hook asks active-recording.sh `get` where
#      to write on every append; after a close that exits non-zero and the hook has nowhere to write, so it
#      writes nowhere. This is why sealing does not wait for `recording_ttl_minutes` to expire - that key is 90
#      minutes in the shipped configuration, so a seal that relied on expiry would leave the recording
#      appendable for up to an hour and a half after the user said it had ended.
#   2. recording-file.sh `append` REFUSES A CLOSED RECORDING outright (exit 7), on the frontmatter this script
#      writes. That is the mechanism that makes the first one sufficient rather than merely likely: a caller
#      holding the path directly - a stale variable, a re-run of an earlier command, a hook that cached it -
#      cannot append to a sealed document even with the pointer out of the picture.
#
# The clear is UNCONDITIONAL (no --token): this script seals recordings it did not start, so it never holds the
# token that `set` returned. The path comparison below is what takes the place of token matching.
#
# ---------------------------------------------------------------------------
# WHEN THE POINTER NAMES A DIFFERENT RECORDING THAN THE PATH GIVEN
# ---------------------------------------------------------------------------
# With an explicit <path> that is not the active recording, the named path is sealed and THE POINTER IS LEFT
# INTACT, with a warning on stderr. Exit 0: sealing the document the caller named is a complete success, and the
# emitter can be run on it.
#
# Clearing would be the wrong move, and this is the case the comparison exists for. A pointer that names
# something else is most likely a live second recording (`set --force` is the documented way to get one), and
# dropping its pointer would silently orphan a recording nobody asked to close - exactly the failure the
# write-then-clear ordering above is built to avoid, arrived at from the other direction. Paths are compared
# literally first and then with their directories resolved, so an absolute path and a relative path to the same
# file are recognised as the same recording and the pointer IS cleared for them.
#
# ---------------------------------------------------------------------------
# WHY A RECORDING WITH NO STEPS IS STILL SEALED
# ---------------------------------------------------------------------------
# Sealing a zero-step recording succeeds, with a warning on stderr. Refusing would be worse in every direction:
# the document could never be closed, the pointer could never be cleared through the supported route, and the
# user would be pushed towards hand-editing the frontmatter - which SKILL.md's `stop` route tells them not to do
# for good reason. An empty recording is a real outcome (the recorder was started and the user did nothing worth
# capturing), and the warning is there because the emitter will have nothing to emit from it.
#
# The step count is read by delegating to `recording-file.sh steps`, so there is exactly one implementation of
# "where are the steps in this file" and this script adds no second parse of its own. It therefore INHERITS that
# script's known marker-injection weakness (a step body containing a literal marker line at column 1 is
# indistinguishable from a real marker; filed as E89_S06_T15) and adds nothing to it. That is tolerable here and
# nowhere near load-bearing: the count drives a WARNING ONLY. No decision in this script - not whether to seal,
# not whether to clear the pointer, not the exit code - reads it. A wrong count prints a wrong warning; it cannot
# produce a wrong seal. If recording-file.sh is missing or the count cannot be read, the warning is skipped and
# the seal proceeds.
#
# ---------------------------------------------------------------------------
# WHAT SEALING DOES TO recording-file.sh's APPEND PREFIX PROPERTY
# ---------------------------------------------------------------------------
# recording-file.sh guarantees the strong property that the bytes of a recording before an APPEND are a
# byte-for-byte prefix of the bytes after it, and its suite asserts exactly that. The frontmatter is the FIRST
# thing in the document, so sealing cannot be an append and that property cannot hold for this script. It is not
# claimed. Following the precedent record-answer.sh set for insertions, it is replaced by three narrower
# guarantees, each asserted in tests/workflow-recorder-close.bats rather than left to review:
#
#   1. EVERYTHING BELOW THE FRONTMATTER IS BYTE-IDENTICAL. The heading, the prose, the steps anchor, and every
#      step entry with all of its annotations, in full. A seal cannot touch a recorded step.
#   2. INSIDE THE FRONTMATTER, ONLY TWO LINES CHANGE (three with --reason): the `status:` line becomes
#      `status: closed` and the `date_ended:` line gains the stamp. Key order is preserved, every other key is
#      left exactly as it was, and the result still parses as YAML.
#   3. THE WRITE IS WHOLE OR NOTHING. The modified document is built in a same-directory temporary file and
#      mv'd into place, as `create` and record-answer.sh do, so an interrupted seal leaves the recording exactly
#      as it was rather than half-rewritten. There is no window in which the recording path holds a partially
#      rewritten document, and no failure path in which the pointer has been cleared.
#
# The append property itself is UNAFFECTED as a property of append: this script never appends. (A closed
# recording refuses appends, but that is the guard above, not a change to how appending works.)
#
# ---------------------------------------------------------------------------
# ENVIRONMENT
# ---------------------------------------------------------------------------
#   JENGA_RECORDER_NOW   the closing time, UTC, as 2026-11-02T00:10:12Z. A test seam, in the style of
#                        recording-file.sh's and record-answer.sh's seam of the same name; nothing should set it
#                        in use.
# The pointer's own seams (JENGA_RECORDING_STATE_DIR, JENGA_RECORDING_SESSION_ID, ...) belong to
# active-recording.sh and are simply inherited by the sub-process; this script neither reads nor validates them.
#
# ---------------------------------------------------------------------------
# EXIT CODES
# ---------------------------------------------------------------------------
#   0   success. The sealed recording's path is on stdout. Also: --state, --help, and --if-open against an
#       already-closed recording (which writes nothing).
#   2   usage error: an unknown option, a missing option argument, more than one path, a multi-line or empty
#       --reason, or a bad JENGA_RECORDER_NOW. Nothing was read or written.
#   3   no path was given and no active recording could be read from the pointer. Nothing was changed. The
#       pointer's own diagnostics, if any, are on stderr.
#   4   the recording does not exist, or is not readable.
#   5   the recording has no frontmatter block, its frontmatter is unterminated, or it has no `status:` key -
#       so there is no defensible place to record the closed state. Deliberately an error rather than writing
#       a frontmatter the document did not have.
#   6   the recording is ALREADY CLOSED. Nothing was written and the pointer was NOT cleared, so a double close
#       cannot undo a pointer that a later `set` has legitimately taken over. Pass --if-open to make this a
#       success instead.
#   7   the write failed: the recording or its directory is not writable, the temporary file could not be
#       written, or the mv did not complete. The recording is unchanged, nothing partial was left at its path,
#       AND THE POINTER IS INTACT - which is the ordering guarantee this script exists to provide.
#   8   the recording WAS sealed but the pointer could not be cleared. The path IS printed on stdout, because
#       the seal is the primary fact and the emitter can legitimately be run; the non-zero exit is there so a
#       caller notices the stale pointer, whose whole cost is that the next `set` refuses until it is cleared or
#       forced. A sealed recording cannot be appended to in this state either way (guard 2 above).
# This table is not parallel to recording-file.sh's or active-recording.sh's, which give some of the same numbers
# different meanings. Read this one.
#
# Compatible with macOS bash 3.2 (no associative arrays, mapfile or case-modifying expansions) and safe under
# `set -u`.
# ---------------------------------------------------------------------------

set -u
export LC_ALL=C

SELF="$(basename "$0")"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
POINTER_SCRIPT="$SCRIPT_DIR/active-recording.sh"
FILE_SCRIPT="$SCRIPT_DIR/recording-file.sh"

# The frontmatter keys this script writes. The block itself is owned by recording-file.sh's create; these are
# read and rewritten, never invented.
CLOSED_STATUS='closed'

OPT_REASON=""
OPT_REASON_GIVEN=0
OPT_SESSION=""
OPT_IF_OPEN=0
OPT_STATE=0
ARG_PATH=""
ARG_PATH_GIVEN=0

err() {
  printf '%s: %s\n' "$SELF" "$*" >&2
}

die() {
  local code="$1"; shift
  err "$*"
  exit "$code"
}

usage() {
  cat <<'USAGE'
usage:
  close-recording.sh [<path>] [--reason <text>] [--session <key>] [--if-open]
  close-recording.sh --state [<path>] [--session <key>]
  close-recording.sh -h | --help | help

  <path>           the recording to seal; omitted, it is read from the active pointer
  --reason <text>  record why it was closed, as closed_reason in the frontmatter (one line)
  --session <key>  session key for the pointer operations, forwarded to active-recording.sh
  --if-open        an already-closed recording is a success (exit 0, nothing written) rather than a refusal
  --state          read-only: print "open" or "closed" and exit 0

Seals a recording once the user has confirmed the process ended: marks it closed in its frontmatter with the
closing timestamp, THEN clears the active-recording pointer, THEN prints the closed path on stdout and nothing
else, so the workflow-definition emitter can be run on it. The order is the guarantee - the pointer is never
cleared before the write has landed. Closing an already-closed recording is refused, and a closed recording
refuses further appends.
Full contract, including every exit code and what sealing does to the append prefix property: the header of
this script.
USAGE
}

# Prints the current UTC timestamp, honouring the test seam. Returns 2 on a malformed override.
now_utc() {
  if [ -n "${JENGA_RECORDER_NOW:-}" ]; then
    if ! printf '%s' "$JENGA_RECORDER_NOW" | grep -Eq '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$'; then
      err "bad JENGA_RECORDER_NOW \"$JENGA_RECORDER_NOW\" (expected a UTC time like 2026-11-02T00:10:12Z)"
      return 2
    fi
    printf '%s' "$JENGA_RECORDER_NOW"
    return 0
  fi
  date -u +%Y-%m-%dT%H:%M:%SZ
}

# Escapes $1 for a double-quoted YAML scalar: backslash first, then the quote. Mirrors recording-file.sh.
yaml_escape() {
  printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'
}

# Prints $1 with its directory resolved, for comparing two spellings of one path. Falls back to the input
# unchanged when the directory cannot be entered, so this never fails and never invents a path.
canonical_path() {
  (
    d="$(dirname "$1")"
    b="$(basename "$1")"
    if cd "$d" 2>/dev/null; then
      printf '%s/%s' "$(pwd -P)" "$b"
    else
      printf '%s' "$1"
    fi
  )
}

# True when $1 and $2 name the same recording, literally or after resolving their directories.
same_recording() {
  [ "$1" = "$2" ] && return 0
  [ "$(canonical_path "$1")" = "$(canonical_path "$2")" ] && return 0
  return 1
}

# Prints the recording's frontmatter status: the value of the first `status:` key inside the leading `---` block.
# Prints one of the sentinels "nofm" (no leading ---), "unterminated" (no closing ---), "nostatus" (no status
# key), or "empty" (the key is present with no value) instead, so the caller branches on a word rather than on
# a parse of its own. Only the frontmatter is scanned: a `status:` line in a step body is not frontmatter.
#
# THE STATUS VALUE IS REMEMBERED, NOT PRINTED ON SIGHT, and the verdict is reached in END. An earlier version
# exited the moment it matched `status:`, which meant it could never afterwards discover that the block has no
# closing `---`: a document with both a status key and no terminator was reported as an ordinary open recording
# and went on to be SEALED WITHOUT A CLOSING TIMESTAMP, because the rewrite below only emits date_ended when it
# reaches that terminator. Termination has to be established before the status value can be trusted, so the
# scan always runs to the terminator or to end of input.
frontmatter_status() {
  awk '
    NR == 1 {
      if ($0 != "---") { print "nofm"; done = 1; exit }
      infm = 1
      next
    }
    infm == 1 && $0 == "---" { term = 1; exit }
    infm == 1 && index($0, "status:") == 1 && got != 1 {
      v = substr($0, 8)
      sub(/^[ \t]+/, "", v)
      sub(/[ \t\r]+$/, "", v)
      val = (v == "" ? "empty" : v)
      got = 1
      next
    }
    END {
      if (done == 1) { exit }
      if (term != 1) { print "unterminated"; exit }
      print (got == 1 ? val : "nostatus")
    }
  ' "$1"
}

# Prints the value of frontmatter key $2 in $1, or nothing. Same scanning rule as frontmatter_status: only the
# leading, TERMINATED `---` block is consulted.
frontmatter_value() {
  awk -v key="$2:" '
    NR == 1 { if ($0 != "---") { exit } ; infm = 1; next }
    infm == 1 && $0 == "---" { term = 1; exit }
    infm == 1 && index($0, key) == 1 && got != 1 {
      v = substr($0, length(key) + 1)
      sub(/^[ \t]+/, "", v)
      sub(/[ \t\r]+$/, "", v)
      val = v
      got = 1
      next
    }
    END { if (term == 1 && got == 1) { print val } }
  ' "$1"
}

# Prints the number of steps in recording $1, by delegating to recording-file.sh. Prints nothing when the count
# cannot be read; see the step-count note in the header for why that is survivable.
step_count_of() {
  local out
  [ -f "$FILE_SCRIPT" ] || return 1
  out="$(bash "$FILE_SCRIPT" steps "$1" 2>/dev/null)" || return 1
  if [ -z "$out" ]; then
    printf '0'
  else
    printf '%s' "$out" | grep -c '' | tr -d ' \n'
  fi
  return 0
}

# Prints the active recording's path, or returns non-zero when there is none. The pointer's own stderr is left
# to pass through: it is more specific than anything this script could say about it.
pointer_path() {
  if [ ! -f "$POINTER_SCRIPT" ]; then
    err "the active-recording pointer script is missing at $POINTER_SCRIPT"
    return 1
  fi
  if [ -n "$OPT_SESSION" ]; then
    bash "$POINTER_SCRIPT" get --session "$OPT_SESSION"
  else
    bash "$POINTER_SCRIPT" get
  fi
}

parse_args() {
  while [ "$#" -gt 0 ]; do
    case "$1" in
      -h|--help|help) usage; exit 0 ;;
      --state) OPT_STATE=1; shift ;;
      --if-open) OPT_IF_OPEN=1; shift ;;
      --reason)
        shift
        [ "$#" -ge 1 ] || { usage >&2; die 2 "--reason needs a value"; }
        OPT_REASON="$1"; OPT_REASON_GIVEN=1; shift
        ;;
      --reason=*) OPT_REASON="${1#--reason=}"; OPT_REASON_GIVEN=1; shift ;;
      --session)
        shift
        [ "$#" -ge 1 ] || { usage >&2; die 2 "--session needs a value"; }
        OPT_SESSION="$1"; shift
        ;;
      --session=*) OPT_SESSION="${1#--session=}"; shift ;;
      --) shift
          while [ "$#" -gt 0 ]; do
            [ "$ARG_PATH_GIVEN" -eq 0 ] || { usage >&2; die 2 "takes at most one path"; }
            ARG_PATH="$1"; ARG_PATH_GIVEN=1; shift
          done
          ;;
      -*) usage >&2; die 2 "unknown option \"$1\"" ;;
      *)
        [ "$ARG_PATH_GIVEN" -eq 0 ] || { usage >&2; die 2 "takes at most one path (got \"$ARG_PATH\" and \"$1\")"; }
        ARG_PATH="$1"; ARG_PATH_GIVEN=1; shift
        ;;
    esac
  done

  if [ "$OPT_REASON_GIVEN" -eq 1 ]; then
    [ -n "$OPT_REASON" ] || die 2 "--reason needs non-empty text"
    case "$OPT_REASON" in
      *"
"*) die 2 "--reason must be a single line (it is written as one frontmatter value)" ;;
    esac
  fi
}

main() {
  local path="" state stamp reasonline dir base tmp count pointer clear_rc

  parse_args "$@"

  # ---- resolve the recording ------------------------------------------------
  if [ "$ARG_PATH_GIVEN" -eq 1 ]; then
    path="$ARG_PATH"
  else
    path="$(pointer_path)" || die 3 "no active recording, and no path was given; nothing was changed"
    [ -n "$path" ] || die 3 "the active-recording pointer named no path; nothing was changed"
  fi

  [ -f "$path" ] || die 4 "no such recording: $path"
  [ -r "$path" ] || die 4 "recording is not readable: $path"

  # ---- read its current state ----------------------------------------------
  state="$(frontmatter_status "$path")"
  case "$state" in
    nofm)
      die 5 "$path has no frontmatter block (expected --- on its first line); refusing to write a frontmatter the document does not have"
      ;;
    unterminated)
      die 5 "$path has an unterminated frontmatter block (no closing ---); refusing to guess where it ends"
      ;;
    nostatus)
      die 5 "$path has no status: key in its frontmatter; refusing to guess where to record the closed state"
      ;;
  esac

  if [ "$OPT_STATE" -eq 1 ]; then
    if [ "$state" = "$CLOSED_STATUS" ]; then printf 'closed\n'; else printf 'open\n'; fi
    return 0
  fi

  if [ "$state" = "$CLOSED_STATUS" ]; then
    if [ "$OPT_IF_OPEN" -eq 1 ]; then
      err "already closed: $path (--if-open, so this is a success; nothing was written)"
      printf '%s\n' "$path"
      return 0
    fi
    die 6 "already closed: $path; refusing to close it twice. Nothing was written and the pointer was not touched."
  fi

  stamp="$(now_utc)" || exit 2

  reasonline=""
  if [ "$OPT_REASON_GIVEN" -eq 1 ]; then
    reasonline="closed_reason: \"$(yaml_escape "$OPT_REASON")\""
  fi

  # ---- advisory: a recording with no steps is still sealed ------------------
  count="$(step_count_of "$path" 2>/dev/null)" || count=""
  if [ "$count" = "0" ]; then
    err "note: $path has no steps; sealing it anyway, but there is nothing in it for the workflow-definition emitter"
  fi

  # ---- 1. the frontmatter write, whole or nothing --------------------------
  [ -w "$path" ] || die 7 "recording is not writable: $path; nothing was changed and the pointer is intact"
  dir="$(dirname "$path")"
  base="$(basename "$path")"
  [ -w "$dir" ] || die 7 "the recording's directory is not writable: $dir; nothing was changed and the pointer is intact"

  tmp="$dir/.tmp-$base.close.$$"
  rm -f "$tmp"
  trap 'rm -f "$tmp"' EXIT INT TERM

  # Only the frontmatter is rewritten. Everything from the closing --- onwards is copied through verbatim, which
  # is what makes guarantee 1 in the header a property of the mechanism rather than something to verify.
  if ! awk -v stamp="$stamp" -v closed="$CLOSED_STATUS" -v reasonline="$reasonline" '
    NR == 1 { print; infm = 1; next }
    infm == 1 && $0 == "---" {
      if (done_ended != 1) { print "date_ended: " stamp }
      if (reasonline != "" && done_reason != 1) { print reasonline }
      print
      infm = 0
      next
    }
    infm == 1 && index($0, "status:") == 1 && done_status != 1 {
      print "status: " closed
      done_status = 1
      next
    }
    infm == 1 && index($0, "date_ended:") == 1 && done_ended != 1 {
      print "date_ended: " stamp
      done_ended = 1
      next
    }
    infm == 1 && index($0, "closed_reason:") == 1 {
      if (reasonline != "") { print reasonline; done_reason = 1 } else { print }
      next
    }
    { print }
  ' "$path" > "$tmp"; then
    die 7 "could not write the temporary file $tmp; $path is unchanged and the pointer is intact"
  fi

  # A sanity check on our own output before it replaces a real document: the rewrite must be non-empty and must
  # actually carry BOTH halves of the closed state, or the mv is not attempted. The closing timestamp is checked
  # as well as the status because the two are written by different rules of the awk above and a document can be
  # left carrying one without the other - which is exactly the shape of the defect this check now covers.
  if [ ! -s "$tmp" ]; then
    die 7 "the rewritten frontmatter came out empty; $path is unchanged and the pointer is intact"
  fi
  if [ "$(frontmatter_status "$tmp")" != "$CLOSED_STATUS" ]; then
    die 7 "the rewritten frontmatter does not record the closed state; $path is unchanged and the pointer is intact"
  fi
  if [ -z "$(frontmatter_value "$tmp" date_ended)" ]; then
    die 7 "the rewritten frontmatter records no closing timestamp; $path is unchanged and the pointer is intact"
  fi

  if ! mv "$tmp" "$path" 2>/dev/null; then
    die 7 "could not move $tmp into place at $path; nothing partial was left at the target and the pointer is intact"
  fi
  trap - EXIT INT TERM

  # ---- 2. only now, the pointer -------------------------------------------
  # Everything below this line runs with the recording already sealed. No failure here can un-seal it, and none
  # of them is allowed to suppress the path on stdout.
  if pointer="$(pointer_path 2>/dev/null)"; then
    if [ -n "$pointer" ] && ! same_recording "$pointer" "$path"; then
      err "the active pointer names a different recording ($pointer), so it was left intact; $path is sealed"
      printf '%s\n' "$path"
      return 0
    fi
    clear_rc=0
    if [ -n "$OPT_SESSION" ]; then
      bash "$POINTER_SCRIPT" clear --session "$OPT_SESSION" >/dev/null || clear_rc=$?
    else
      bash "$POINTER_SCRIPT" clear >/dev/null || clear_rc=$?
    fi
    if [ "$clear_rc" -ne 0 ]; then
      err "$path is sealed, but the active-recording pointer could not be cleared; clear it with active-recording.sh clear before starting another recording"
      printf '%s\n' "$path"
      return 8
    fi
  fi
  # No active pointer at all is not a problem: the recording is sealed and nothing points at it.

  # ---- 3. the path, and nothing else --------------------------------------
  printf '%s\n' "$path"
  return 0
}

main "$@"
exit $?
