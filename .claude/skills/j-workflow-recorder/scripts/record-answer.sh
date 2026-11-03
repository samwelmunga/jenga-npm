#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# skills/j-workflow-recorder/scripts/record-answer.sh - the annotation layer (epic E89)
#
# Attaches meaning to a step that was already captured verbatim. This is tier 2 of the recorder's
# two-tier split: a hook appends the step with no agent in the loop, and the Scrum Master annotates
# what that step MEANT in the process being recorded. Capture and interpretation are different
# writers to the same document, and this script is the whole of the second one.
#
# Like recording-file.sh, it works against a recording path SUPPLIED BY THE CALLER: it derives no
# paths and resolves no roots.
#
# Its ONE runtime dependency is recording-format.sh, the parse contract, sourced from the same
# directory. That is deliberate: the alternative is two scripts each carrying their own copy of the
# format, which is what E89_S06_T15 removed. A missing library is exit 6 rather than a best-effort
# parse.
#
# ---------------------------------------------------------------------------
# USAGE
# ---------------------------------------------------------------------------
#   record-answer.sh <path> <step-id> <kind> <answer...>
#   record-answer.sh <path> <step-id> <kind> -            read the answer from stdin (multi-line)
#   record-answer.sh --list  <path> <step-id>             print "<kind><TAB><value>" per annotation
#   record-answer.sh --value <path> <step-id> <kind>      print one annotation's machine value
#   record-answer.sh --text  <path> <step-id> <kind>      print one annotation's verbatim answer text
#   record-answer.sh -h | --help | help                   print this usage on stdout, exit 0
#
#   --replace        replace an existing annotation of the same kind on that step. Without it, a
#                    second annotation of the same kind is REFUSED (exit 7) and nothing is written.
#   --note <text>    extra verbatim prose to record under the answer, for the free-text option of a
#                    numbered prompt. `--note -` reads it from stdin. Only one of <answer> and --note
#                    may be `-`.
#
#   <answer...> is one or more arguments joined with single spaces, so an unquoted phrase works.
#
# ---------------------------------------------------------------------------
# THE ANNOTATION FORMAT
# ---------------------------------------------------------------------------
# NOT DEFINED HERE. The annotation block's exact shape, the step entry format it deliberately mirrors,
# the body escape rule, the column-1 matching rule and the format-version contract all live in ONE
# place, the header of skills/j-workflow-recorder/scripts/recording-format.sh, which this script
# sources. It used to be restated in this header and again in recording-file.sh's; E89_S06_T15
# converged both onto that file so a change to the format is a change to exactly one document.
#
# Read it before changing anything below. What this script adds on top of it is the four KINDS and
# their vocabularies, which it owns and which are documented in the next block.
#
# Three properties of that contract matter most to the code here:
#
#   - A body is written VERBATIM except for one rule: a body line that would itself be read as a
#     marker (`^ *<!-- jenga-recorder:`) is written with one extra leading space. --text reverses it,
#     so an answer still round trips byte for byte.
#   - Every marker match here is anchored at COLUMN 1, and the insertion point is the step's UNIQUE
#     step-end marker. A lookup that resolves to more than one line is exit 8, never a pick: this is
#     the defect E89_S06_T15 closed, where `head -n 1` selected an INJECTED step-end over the real one
#     and --text then returned a neighbouring block's markup while exiting 0.
#   - A recording that predates the escape rule (recording_format_version below 2, or absent) is
#     LEGACY: it is checked for ambiguity on every read and write, and a body containing a would-be
#     marker is refused there (exit 9) rather than written unsafely. recording-file.sh migrate
#     promotes a clean one.
#
# ---------------------------------------------------------------------------
# THE FOUR KINDS AND THEIR VOCABULARIES
# ---------------------------------------------------------------------------
#   kind="deviation"        value="in-process" | "out-of-process"
#       The verdict on "is this in fact a deviation from the process?".
#       out-of-process  the user confirmed it is a deviation: the step is EXCLUDED from an emitted
#                       workflow definition.
#       in-process      the user said it is not a deviation: NO effect on the process model. This is
#                       also the meaning of no deviation annotation at all, so recording it changes
#                       nothing a consumer does - see "WHY in-process IS NOT A NEGATIVE MARKER".
#       Accepted inputs: in-process, no, n, false, not-a-deviation / out-of-process, yes, y, true,
#       deviation. Case-insensitive.
#
#   kind="end-of-process"   value="ended" | "continuing"
#       The verdict on "has the process reached its end?".
#       Accepted inputs: ended, end, yes, y, true / continuing, continue, no, n, false.
#
#   kind="relevance"        value="stated"
#       The step's stated relevance in the process. Asked of an INCLUDED step (deviation in-process) and
#       of a detour inside a continuing process (deviation out-of-process, end-of-process continuing);
#       never of a step the user said ended the process. A step may therefore carry deviation in-process
#       AND relevance, and this script accepts that pair without --replace (uniqueness is per step and
#       kind). Departure from the user's original question order, ruled 2026-11-02 (E89_S06_T17): see
#       SKILL.md, "Why the ladder asks relevance for an included step".
#       There is nothing to choose from here, so the token is always "stated" and the PAYLOAD IS THE
#       BODY: an emitter uses that body text as the emitted step's description, so for an included step
#       it describes a step that exists; on an excluded (out-of-process) step it is context only and is
#       never emitted. Any non-empty answer is accepted.
#
#   kind="step-type"        value="skill" | "playbook" | "confirm" | "compute" | "render"
#       The Scrum Master's judgment of which workflow step type this step is. The judgment is a
#       judgment, not a lookup on which tool ran, so it is not reproducible - which is exactly why it
#       is written down here. An emitter reuses a persisted step-type annotation VERBATIM and never
#       re-judges, so re-emitting a fully annotated recording is deterministic.
#       Accepted inputs: the five tokens only. Nothing is inferred.
#
# Any other kind is refused with a message listing these four. Any value outside a kind's vocabulary
# is refused. Nothing is guessed: a verdict that cannot be mapped is a usage error, never a default.
#
# ---------------------------------------------------------------------------
# WHY in-process IS NOT A NEGATIVE MARKER
# ---------------------------------------------------------------------------
# "Answering 'not a deviation' leaves the recorded process model unchanged - no spurious branch" is
# an acceptance criterion, and the obvious way to violate it is to write a `deviation: false` marker
# that every consumer then has to special-case. The vocabulary above removes the possibility rather
# than relying on the consumer:
#
#   - The exclusion rule is a SINGLE POSITIVE MEMBERSHIP TEST: exclude the step if and only if an
#     annotation exists with kind="deviation" and value="out-of-process".
#   - There is no boolean to negate and no false-y marker to interpret. A consumer that implements
#     only that one test is already correct for every case.
#   - in-process is the semantic identity: a step annotated in-process and a step with no deviation
#     annotation at all produce byte-identical emission. The answer is still part of the record -
#     which the story requires - without being part of the process model.
#
# No section, branch, heading or marker other than the annotation block itself is ever created, for
# any kind. There is nothing in this format that an emitter must subtract.
#
# ---------------------------------------------------------------------------
# WHAT THIS DOES TO recording-file.sh's APPEND PREFIX PROPERTY
# ---------------------------------------------------------------------------
# recording-file.sh guarantees the strong property that the bytes of a recording before an APPEND are
# a byte-for-byte prefix of the bytes after it, and its suite asserts exactly that. Annotating is an
# INSERTION, not an append - the step being annotated is usually not the last thing in the file - so
# that property cannot hold for this script in general, and it is not claimed. Stated precisely:
#
#   1. The append property is UNAFFECTED, because it is a property of append. This script never
#      appends a step, and after an annotation a subsequent `recording-file.sh append` is still a
#      plain >> of a fresh step onto the end of the file. Sequence numbers are derived by counting
#      open markers, which an annotation does not add.
#   2. Everything outside the annotated step is byte-identical: the frontmatter, the heading prose,
#      the steps anchor, and every other step entry in full. This is asserted in the suite, not left
#      to review.
#   3. Inside the annotated step, everything up to and including the step's text is byte-identical.
#      The only change is an insertion in the gap before that step's step-end marker.
#   4. For the case the interrogation points actually produce - annotating the step that was just
#      captured, i.e. the LAST step in the file - the pre-annotation file is still a byte-for-byte
#      prefix of the post-annotation file up to and including the last blank line before the final
#      step-end marker. The degradation is one line: the final close marker moves down.
#
# The write itself is whole-or-nothing for the same reason create is: the modified document is built
# in a same-directory temporary file and mv'd into place, so an interrupted annotation leaves the
# recording exactly as it was rather than half-rewritten. There is no window in which the recording
# path holds a partially rewritten document.
#
# ---------------------------------------------------------------------------
# WHY A SECOND ANNOTATION OF THE SAME KIND IS REFUSED BY DEFAULT
# ---------------------------------------------------------------------------
# One step must never carry two conflicting annotations of the same kind - a consumer would have no
# defensible rule for choosing between them. Both ways of preventing that are sound; this script
# refuses by default and replaces only on --replace, because refusal is the option that writes
# nothing, and because the normal flow only ever annotates a kind that is absent (an emitter asks
# for a step type precisely when there is no persisted one). --replace deletes the existing block of
# that kind in full, including the blank line that preceded it, and writes the new one in the usual
# position, so a replacement cannot leave a residue of the answer it superseded.
#
# Different kinds on one step are not a conflict and are expected: any step, included or deviating,
# typically carries a deviation annotation, a relevance annotation and a step-type annotation.
#
# ---------------------------------------------------------------------------
# ENVIRONMENT
# ---------------------------------------------------------------------------
#   JENGA_RECORDER_NOW   the current time for stamps, UTC, as 2026-11-02T00:10:12Z. A test seam, in
#                        the style of recording-file.sh's seam of the same name; nothing should set
#                        it in use.
#
# ---------------------------------------------------------------------------
# EXIT CODES
# ---------------------------------------------------------------------------
#   0   success. A write prints the annotated step's id; a reader prints what it was asked for.
#   1   --value / --text: there is no annotation of that kind on that step. Prints nothing on stdout.
#   2   usage error: no arguments, a missing path, step id, kind or answer, an unknown kind, a value
#       outside the kind's vocabulary, an unknown option, both the answer and --note reading stdin,
#       or a bad JENGA_RECORDER_NOW.
#   3   the recording does not exist, or is not readable.
#   4   no step with that id in the recording. Nothing was written.
#   5   the recording has no steps section, or the named step has no step-end marker, so there is no
#       defensible insertion point. Deliberately an error rather than writing somewhere plausible.
#   6   the write failed, or the recording is not writable. Nothing partial was left at the path.
#   7   an annotation of that kind already exists on that step and --replace was not given. Nothing
#       was written and the existing annotation was not touched.
#   8   the recording's markers are AMBIGUOUS - a duplicated step, step-end or (id, kind) marker, a
#       marker nested inside an unclosed block, a seq that does not match its position, an unknown
#       marker name - so it cannot be parsed safely. Applies to the READERS too: a lookup that cannot
#       resolve unambiguously fails here rather than returning a neighbouring block with exit 0.
#       Nothing was written. See recording-format.sh.
#   9   the answer or --note text contains a line that would be read as a marker, and the recording is
#       LEGACY (recording_format_version below 2), so it cannot hold one safely. Nothing was written;
#       promote the recording with `recording-file.sh migrate` first.
#
# Compatible with macOS bash 3.2 (no associative arrays, mapfile or case-modifying expansions) and
# safe under `set -u`.
# ---------------------------------------------------------------------------

set -u
export LC_ALL=C

SELF="$(basename "$0")"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# The parse contract - the marker vocabulary, the body escape, the frontmatter read and every
# structural lookup - lives in recording-format.sh. It is sourced, never restated here.
FORMAT_LIB="$SCRIPT_DIR/recording-format.sh"
if [ ! -r "$FORMAT_LIB" ]; then
  printf '%s: cannot read the parse contract library %s; refusing to parse a recording without it\n' \
    "$(basename "$0")" "$FORMAT_LIB" >&2
  exit 6
fi
# shellcheck source=recording-format.sh
. "$FORMAT_LIB"

ANSWER_MARKER_PREFIX="$REC_ANSWER_MARKER_PREFIX"
ANSWER_END_PREFIX="$REC_ANSWER_END_PREFIX"
# Owned by recording-file.sh's layer; read, never written, by this script.
STEPS_ANCHOR="$REC_STEPS_ANCHOR"
STEP_MARKER_PREFIX="$REC_STEP_MARKER_PREFIX"
STEP_END_PREFIX="$REC_STEP_END_PREFIX"

VALID_KINDS='deviation, end-of-process, relevance, step-type'

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
  record-answer.sh <path> <step-id> <kind> <answer...>
  record-answer.sh <path> <step-id> <kind> -          read the answer from stdin
  record-answer.sh --list  <path> <step-id>
  record-answer.sh --value <path> <step-id> <kind>
  record-answer.sh --text  <path> <step-id> <kind>
  record-answer.sh -h | --help | help

  --replace       replace an existing annotation of the same kind (default: refuse, exit 7)
  --note <text>   extra verbatim prose to record under the answer; - reads it from stdin

kinds and their machine values:
  deviation        in-process | out-of-process   (out-of-process excludes the step from emission)
  end-of-process   ended | continuing
  relevance        stated                        (the answer text is the payload)
  step-type        skill | playbook | confirm | compute | render

Attaches a user's answer, and the Scrum Master's step-type judgment, to a step already captured in a
recording. The annotation is inserted inside the step, before its step-end marker, so it stays with
the step it concerns. Every other step entry is left byte-identical, and the write is whole or not at
all (same-directory temp file, then an atomic mv).
Full contract, including the machine-readable annotation format every consumer parses: the header of
recording-format.sh, which this script sources. The four kinds are documented in this script's header.
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

lower() {
  printf '%s' "$1" | tr 'ABCDEFGHIJKLMNOPQRSTUVWXYZ' 'abcdefghijklmnopqrstuvwxyz'
}

# Prints the normalised machine value for <kind> <raw answer>, or returns 1 when the answer is
# outside that kind's vocabulary. Nothing is guessed: an unmappable verdict is an error.
normalise_value() {
  local kind="$1" raw="$2" lc
  lc="$(lower "$raw")"
  case "$kind" in
    deviation)
      case "$lc" in
        in-process|in_process|no|n|false|not-a-deviation) printf 'in-process'; return 0 ;;
        out-of-process|out_of_process|yes|y|true|deviation) printf 'out-of-process'; return 0 ;;
      esac
      return 1
      ;;
    end-of-process)
      case "$lc" in
        ended|end|yes|y|true) printf 'ended'; return 0 ;;
        continuing|continue|no|n|false) printf 'continuing'; return 0 ;;
      esac
      return 1
      ;;
    relevance)
      [ -n "$raw" ] || return 1
      printf 'stated'
      return 0
      ;;
    step-type)
      case "$lc" in
        skill|playbook|confirm|compute|render) printf '%s' "$lc"; return 0 ;;
      esac
      return 1
      ;;
  esac
  return 1
}

# Prints the accepted-values message for <kind>, for a usage error that must be actionable.
vocabulary_of() {
  case "$1" in
    deviation)      printf 'in-process (also: no, n, false, not-a-deviation) or out-of-process (also: yes, y, true, deviation)' ;;
    end-of-process) printf 'ended (also: end, yes, y, true) or continuing (also: continue, no, n, false)' ;;
    relevance)      printf 'any non-empty text' ;;
    step-type)      printf 'skill, playbook, confirm, compute or render' ;;
  esac
}

is_valid_kind() {
  case "$1" in
    deviation|end-of-process|relevance|step-type) return 0 ;;
  esac
  return 1
}

# True when $1 has a steps section. Delegates to the contract, so this script holds no second parse:
# the machine anchor at column 1, or a literal "## Steps" heading for a file a human has tidied by hand.
has_steps_section() {
  rec_has_steps_section "$1"
}

# Exits 8 unless $1's markers resolve unambiguously. Every mode of this script runs it, READERS
# INCLUDED: returning a neighbouring block with exit 0 from a corrupted recording is the defect
# E89_S06_T15 closed, and a loud failure is the only honest answer when the document cannot say which
# marker is real. The check itself is rec_check in recording-format.sh.
require_unambiguous() {
  local out
  out="$(rec_check "$1")" && return 0
  die 8 "$1 has ambiguous recording markers, so it cannot be parsed safely and nothing was changed: $(printf '%s' "$out" | tr '\n' ';')  A recording written before the body-escape rule can carry a marker inside a step body; see the parse contract in recording-format.sh, and recording-file.sh migrate."
}

# True when step $2 in $1 already carries exactly one annotation of kind $3. Column-1 anchored, so an
# annotation marker quoted inside a step body is not one.
has_annotation() {
  rec_answer_open_line "$1" "$2" "$3" >/dev/null
}

# Common argument checks for every mode. Sets PATH_ARG; exits on failure.
require_readable_recording() {
  [ -f "$1" ] || die 3 "no such recording: $1"
  [ -r "$1" ] || die 3 "recording is not readable: $1"
}

# Exits unless <path> contains a step with id <step-id> that has both markers, each resolving to
# exactly one line at column 1. Ambiguity is exit 8 (it should already have been caught by
# require_unambiguous; this is the belt to that braces), absence keeps its existing 4 and 5.
require_step() {
  local path="$1" id="$2" rc=0
  if ! has_steps_section "$path"; then
    die 5 "$path has no steps section (expected $STEPS_ANCHOR or a '## Steps' heading); refusing to guess where to write"
  fi
  rec_step_open_line "$path" "$id" >/dev/null || rc=$?
  if [ "$rc" -eq 2 ]; then
    die 8 "step \"$id\" in $path has more than one open marker at column 1, so \"the step with that id\" is not a single place; refusing to guess which one is real"
  fi
  if [ "$rc" -ne 0 ]; then
    if [ -z "$(rec_step_ids "$path")" ]; then
      die 4 "no step \"$id\" in $path: the recording has no steps at all yet"
    fi
    die 4 "no step \"$id\" in $path (known ids: $(rec_step_ids "$path" | tr '\n' ' '))"
  fi
  rc=0
  rec_step_end_line "$path" "$id" >/dev/null || rc=$?
  if [ "$rc" -eq 2 ]; then
    die 8 "step \"$id\" in $path has more than one step-end marker at column 1, so the insertion point inside it is ambiguous; refusing to guess which one is real"
  fi
  if [ "$rc" -ne 0 ]; then
    die 5 "step \"$id\" in $path has no step-end marker, so there is no insertion point inside it; refusing to guess where to write"
  fi
}

# ---------------------------------------------------------------------------
# Readers
# ---------------------------------------------------------------------------

cmd_list() {
  local path="" id=""
  [ "$#" -ge 1 ] || { usage >&2; die 2 "--list needs a path"; }
  path="$1"; shift
  [ "$#" -ge 1 ] || { usage >&2; die 2 "--list needs a step id"; }
  id="$1"
  require_readable_recording "$path"
  require_unambiguous "$path"
  awk -v pfx="${ANSWER_MARKER_PREFIX}id=\"$id\" " '
      index($0, pfx) != 1 { next }
      {
        k=""; v="";
        if (match($0, /kind="[^"]*"/)) { k=substr($0, RSTART+6, RLENGTH-7) }
        if (match($0, /value="[^"]*"/)) { v=substr($0, RSTART+7, RLENGTH-8) }
        if (k != "") { printf "%s\t%s\n", k, v }
      }' "$path"
  return 0
}

cmd_value() {
  local path="" id="" kind="" line
  [ "$#" -ge 3 ] || { usage >&2; die 2 "--value needs a path, a step id and a kind"; }
  path="$1"; id="$2"; kind="$3"
  is_valid_kind "$kind" || { die 2 "unknown kind \"$kind\"; valid kinds are: $VALID_KINDS"; }
  require_readable_recording "$path"
  require_unambiguous "$path"
  # One match is guaranteed by require_unambiguous, so taking the first is a read of the only one
  # rather than a choice between several - which is what tail -n 1 used to be.
  line="$(awk -v pfx="${ANSWER_MARKER_PREFIX}id=\"$id\" kind=\"$kind\" " \
    'index($0, pfx) == 1 { print; exit }' "$path" 2>/dev/null)"
  [ -n "$line" ] || return 1
  printf '%s' "$line" | sed -n 's/.*value="\([^"]*\)".*/\1/p'
  return 0
}

cmd_text() {
  local path="" id="" kind="" openpfx endmark out rc
  [ "$#" -ge 3 ] || { usage >&2; die 2 "--text needs a path, a step id and a kind"; }
  path="$1"; id="$2"; kind="$3"
  is_valid_kind "$kind" || { die 2 "unknown kind \"$kind\"; valid kinds are: $VALID_KINDS"; }
  require_readable_recording "$path"
  require_unambiguous "$path"
  openpfx="${ANSWER_MARKER_PREFIX}id=\"$id\" kind=\"$kind\" "
  endmark="${ANSWER_END_PREFIX}id=\"$id\" kind=\"$kind\" -->"
  out="$(awk -v open="$openpfx" -v endmark="$endmark" '
    index($0, open) == 1 { inblk = 1; n = 0; next }
    inblk == 1 && index($0, endmark) == 1 { inblk = 0; done = 1; next }
    inblk == 1 { n++; lines[n] = $0; next }
    END {
      if (done != 1) { exit 1 }
      # Line 1 of a block is the human-facing heading; skip it and the blank line under it, the same
      # skip a consumer already applies to a step entry.
      s = 2
      while (s <= n && lines[s] == "") { s++ }
      e = n
      while (e >= s && lines[e] == "") { e-- }
      for (i = s; i <= e; i++) { print lines[i] }
    }
  ' "$path")"
  rc=$?
  [ "$rc" -eq 0 ] || return "$rc"
  [ -n "$out" ] || return 0
  # The body comes back out exactly as it went in: rec_unescape_body is the inverse of the escape the
  # writer applied, so a verbatim answer round trips even when it contains marker text.
  if rec_is_escaped_format "$path"; then
    printf '%s\n' "$out" | rec_unescape_body
  else
    printf '%s\n' "$out"
  fi
  return 0
}

# ---------------------------------------------------------------------------
# Writer
# ---------------------------------------------------------------------------

cmd_record() {
  local path="" id="" kind="" raw="" note="" note_given=0 replace=0 answer_stdin=0 note_stdin=0
  local value stamp openpfx endmark dir base tmp blk endln rc src prepared

  # Options may appear before or after the positionals.
  local -a pos
  pos=()
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --replace) replace=1; shift ;;
      --note)
        shift
        [ "$#" -ge 1 ] || { usage >&2; die 2 "--note needs a value"; }
        note="$1"; note_given=1
        if [ "$note" = "-" ]; then note_stdin=1; fi
        shift
        ;;
      --note=*) note="${1#--note=}"; note_given=1; shift ;;
      --) shift; while [ "$#" -gt 0 ]; do pos[${#pos[@]}]="$1"; shift; done ;;
      -) pos[${#pos[@]}]="$1"; shift ;;
      -*) usage >&2; die 2 "unknown option \"$1\"" ;;
      *) pos[${#pos[@]}]="$1"; shift ;;
    esac
  done

  [ "${#pos[@]}" -ge 1 ] || { usage >&2; die 2 "needs a path"; }
  [ "${#pos[@]}" -ge 2 ] || { usage >&2; die 2 "needs a step id"; }
  [ "${#pos[@]}" -ge 3 ] || { usage >&2; die 2 "needs a kind; valid kinds are: $VALID_KINDS"; }
  [ "${#pos[@]}" -ge 4 ] || { usage >&2; die 2 "needs an answer (or - to read it from stdin)"; }

  path="${pos[0]}"
  id="${pos[1]}"
  kind="${pos[2]}"

  is_valid_kind "$kind" || die 2 "unknown kind \"$kind\"; valid kinds are: $VALID_KINDS"

  if [ "${#pos[@]}" -eq 4 ] && [ "${pos[3]}" = "-" ]; then
    answer_stdin=1
  else
    # Join the remaining positionals with single spaces.
    local i=3
    while [ "$i" -lt "${#pos[@]}" ]; do
      if [ -z "$raw" ]; then raw="${pos[$i]}"; else raw="$raw ${pos[$i]}"; fi
      i=$(( i + 1 ))
    done
  fi

  if [ "$answer_stdin" -eq 1 ] && [ "$note_stdin" -eq 1 ]; then
    die 2 "only one of the answer and --note may be - (both would read the same stdin)"
  fi
  if [ "$answer_stdin" -eq 1 ]; then raw="$(cat)"; fi
  if [ "$note_stdin" -eq 1 ]; then note="$(cat)"; fi

  [ -n "$raw" ] || die 2 "needs a non-empty answer"

  if ! value="$(normalise_value "$kind" "$raw")"; then
    die 2 "answer \"$raw\" is not a valid $kind value; accepted: $(vocabulary_of "$kind")"
  fi

  require_readable_recording "$path"
  require_unambiguous "$path"
  require_step "$path" "$id"
  [ -w "$path" ] || die 6 "recording is not writable: $path"

  openpfx="${ANSWER_MARKER_PREFIX}id=\"$id\" kind=\"$kind\" "
  endmark="${ANSWER_END_PREFIX}id=\"$id\" kind=\"$kind\" -->"

  if has_annotation "$path" "$id" "$kind"; then
    if [ "$replace" -eq 0 ]; then
      die 7 "step \"$id\" already carries a $kind annotation ($(cmd_value "$path" "$id" "$kind")); pass --replace to supersede it. Nothing was written."
    fi
  fi

  stamp="$(now_utc)" || exit 2

  # The body and the note must be representable in this document before anything is written. In a
  # current-format recording that means escaping a line that would be read as a marker; in a legacy one
  # there is no safe representation, so it is refused rather than written.
  if ! prepared="$(rec_prepare_body "$path" "$raw")"; then
    die 9 "the answer has a line that would be read as a recording marker (line $(rec_body_marker_lines "$raw")), and $path declares recording_format_version $(rec_format_version "$path"), which cannot hold one safely. Nothing was written. Promote it first with: recording-file.sh migrate $path"
  fi
  raw="$prepared"
  if [ "$note_given" -eq 1 ] && [ -n "$note" ]; then
    if ! prepared="$(rec_prepare_body "$path" "$note")"; then
      die 9 "the --note text has a line that would be read as a recording marker (line $(rec_body_marker_lines "$note")), and $path declares recording_format_version $(rec_format_version "$path"), which cannot hold one safely. Nothing was written. Promote it first with: recording-file.sh migrate $path"
    fi
    note="$prepared"
  fi

  dir="$(dirname "$path")"
  base="$(basename "$path")"
  tmp="$dir/.tmp-$base.answer.$$"
  src="$dir/.tmp-$base.src.$$"
  blk="$dir/.tmp-$base.blk.$$"
  rm -f "$tmp" "$src" "$blk"
  trap 'rm -f "$tmp" "$src" "$blk"' EXIT INT TERM

  # The block to insert. The blank line goes at the END, not the start: the step's own text already
  # ends with one, so a trailing blank separates this block from whatever follows it - the step-end
  # marker, or the next annotation - without ever doubling up.
  {
    printf '%sid="%s" kind="%s" value="%s" at="%s" -->\n' "$ANSWER_MARKER_PREFIX" "$id" "$kind" "$value" "$stamp"
    printf '#### Answer - %s: %s\n' "$kind" "$value"
    printf '\n'
    printf '%s\n' "$raw"
    if [ "$note_given" -eq 1 ] && [ -n "$note" ]; then
      printf '\n'
      printf '%s\n' "$note"
    fi
    printf '\n'
    printf '%sid="%s" kind="%s" -->\n' "$ANSWER_END_PREFIX" "$id" "$kind"
    printf '\n'
  } > "$blk" || die 6 "could not write the temporary file $blk; nothing was written to $path"

  # Replacing: strip the superseded block (and the blank line that preceded it) first, so a
  # replacement leaves no residue and no growing run of blank lines.
  if [ "$replace" -eq 1 ] && has_annotation "$path" "$id" "$kind"; then
    awk -v open="$openpfx" -v endmark="$endmark" '
      BEGIN { skipping = 0; eat = 0 }
      {
        if (skipping == 1) { if (index($0, endmark) == 1) { skipping = 0; eat = 1 } ; next }
        if (eat == 1) { eat = 0; if ($0 == "") { next } }
        if (index($0, open) == 1) { skipping = 1; next }
        print
      }
    ' "$path" > "$src" || die 6 "could not rewrite $path; nothing was changed"
  else
    cat "$path" > "$src" || die 6 "could not read $path for rewriting; nothing was changed"
  fi

  # The step's UNIQUE step-end marker at column 1. This is the line the whole task turns on: the old
  # `grep -n -F ... | head -n 1` picked the first match, so an injected step-end sitting above the real
  # one was selected and the annotation landed inside the previous block. tail -n 1 is no better - a
  # later step's body can inject a marker for an earlier id - so a lookup that resolves to more than one
  # line fails here instead of choosing.
  rc=0
  endln="$(rec_step_end_line "$src" "$id")" || rc=$?
  if [ "$rc" -eq 2 ]; then
    die 8 "step \"$id\" has more than one step-end marker at column 1, so the insertion point is ambiguous; nothing was changed"
  fi
  case "${endln:-}" in
    ''|*[!0-9]*) die 5 "step \"$id\" has no step-end marker after the rewrite; nothing was changed" ;;
  esac

  awk -v endline="$endln" -v blockfile="$blk" '
    NR == endline { while ((getline l < blockfile) > 0) { print l } ; close(blockfile) }
    { print }
  ' "$src" > "$tmp"
  rc=$?
  if [ "$rc" -ne 0 ]; then
    die 6 "could not build the annotated document; nothing was written to $path"
  fi

  if ! mv "$tmp" "$path" 2>/dev/null; then
    die 6 "could not move $tmp into place at $path; nothing partial was left at the target"
  fi

  rm -f "$src" "$blk"
  trap - EXIT INT TERM
  printf '%s\n' "$id"
  return 0
}

main() {
  [ "$#" -ge 1 ] || { usage >&2; die 2 "no arguments given"; }
  case "$1" in
    -h|--help|help) usage; return 0 ;;
    --list)  shift; cmd_list "$@" ;;
    --value) shift; cmd_value "$@" ;;
    --text)  shift; cmd_text "$@" ;;
    *) cmd_record "$@" ;;
  esac
}

main "$@"
exit $?
