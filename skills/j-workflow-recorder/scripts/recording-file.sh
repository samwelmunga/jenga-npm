#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# skills/j-workflow-recorder/scripts/recording-file.sh - the write layer (epic E89, task E89_S01_T02)
#
# Creates a session recording document, appends one step to it, reads its step ids back, and promotes a legacy
# document to the current format version. Every sub-command works against a recording path SUPPLIED BY THE
# CALLER: this script derives no paths and resolves no roots, so it has no runtime dependency on
# recording-path.sh (E89_S01_T01) - that script produces the paths this one is called with in practice, and the
# two were built in parallel.
#
# Its ONE runtime dependency is recording-format.sh, the parse contract, sourced from the same directory. That
# is deliberate: the alternative is two scripts each carrying their own copy of the format, which is what
# E89_S06_T15 removed. A missing library is exit 6 rather than a best-effort parse.
#
# ---------------------------------------------------------------------------
# USAGE
# ---------------------------------------------------------------------------
#   recording-file.sh create <path> <title...>
#   recording-file.sh append <path> <step-text...>
#   recording-file.sh append <path> -                 read the step text from stdin (multi-line)
#   recording-file.sh steps  <path>                   print the step ids in file order, one per line
#   recording-file.sh migrate <path>                  promote a legacy recording to the current format version
#   recording-file.sh -h | --help | help              print this usage on stdout, exit 0
#
#   <title...> / <step-text...>  one or more arguments, joined with single spaces, so an unquoted phrase works.
#
# ---------------------------------------------------------------------------
# THE STEP ENTRY FORMAT
# ---------------------------------------------------------------------------
# NOT DEFINED HERE. The step entry format, the annotation format, the body escape rule, the column-1
# matching rule and the format-version contract all live in ONE place, the header of
# skills/j-workflow-recorder/scripts/recording-format.sh, which this script sources. It used to be
# restated in this header and again in record-answer.sh's; E89_S06_T15 converged both onto that file
# so a change to the format is a change to exactly one document.
#
# Read it before changing anything below. In particular:
#
#   - A body is written VERBATIM except for one rule: a body line that would itself be read as a
#     marker (`^ *<!-- jenga-recorder:`) is written with one extra leading space, so that in a
#     version-2 document every namespace line at column 1 is a real marker. The transform is
#     reversible and only ever touches lines that are HTML comments.
#   - Every marker match in this script is anchored at COLUMN 1, and a lookup that cannot resolve to
#     exactly one line is an error (exit 8), never a pick. An escaped line still matches an unanchored
#     `grep -F`, which is why anchoring is not optional.
#   - A recording that predates the escape rule (`recording_format_version` below 2, or absent) is
#     LEGACY: it is checked for ambiguity on every read and write, a body containing a would-be marker
#     is refused there (exit 9) rather than written unsafely, and `migrate` promotes a clean one.
#
# ---------------------------------------------------------------------------
# WHY THE STEPS SECTION IS THE LAST THING IN THE FILE
# ---------------------------------------------------------------------------
# One decision does most of the work in this script: the steps section is the final section of the document, so
# "append one step" is a plain >> redirect. That makes E89_S01's criterion - an append leaves every earlier byte
# of the file unchanged - a property of the MECHANISM rather than something to get right on every call and then
# verify afterwards. Any layout with a section below the steps would turn each append into a whole-file rewrite,
# and the criterion would then rest on that rewrite being correct every single time.
#
# The same decision is why there is no step counter in the frontmatter. A step_count field would have to be
# rewritten on every append, which is precisely what the criterion forbids. The sequence number is therefore
# DERIVED, by counting the open markers already in the file, so the document stays strictly append-only after
# creation.
#
# "Append is safe to call repeatedly" means the earlier content is untouched, NOT that a repeated call is a
# no-op: a second identical step is a real second step, with its own id, and that is correct - a user who does
# the same thing twice did it twice.
#
# ---------------------------------------------------------------------------
# WHY create IS ATOMIC
# ---------------------------------------------------------------------------
# E89_S01's acceptance criteria require an interrupted session to leave a VALID, READABLE partial recording - no
# half-written frontmatter. So the whole document is written to a temporary file in the SAME directory and then
# mv'd into place. A crash before the mv leaves a stray .tmp-* file and NOTHING at the recording's own path;
# after the mv the document is complete. There is no window in which the recording path holds half a frontmatter
# block. The temp file is cleaned up on every error path.
#
# mv rather than ln: an atomic no-clobber create is more precisely expressed with ln (which fails outright when
# the target exists), but this task's acceptance criteria specify a same-directory temporary file and an atomic
# mv. Existence is therefore checked before the write and AGAIN immediately before the mv. The residual window
# between that second check and the mv is a genuine TOCTOU gap, recorded here rather than papered over; with one
# recorder per session it is not reachable in practice, and the cost if it ever were is one clobbered empty
# recording, not a lost one.
#
# ---------------------------------------------------------------------------
# WHY A CLOSED RECORDING REFUSES APPENDS
# ---------------------------------------------------------------------------
# close-recording.sh (E89_S03_T03) seals a recording by writing status: closed into the frontmatter this script
# creates, and it clears the active-recording pointer so the capture hook no longer knows where to write. That
# alone is not enough, and the gap is why this guard is here rather than only in that script: a caller holding
# the path DIRECTLY - a stale variable, a re-run of an earlier command, a hook that cached the path - would
# otherwise still be able to append to a sealed document. A recording that grows after the emitter has read it
# makes the emitted workflow definition disagree with its own source, which is exactly what sealing exists to
# prevent. So append refuses on the frontmatter itself (exit 7), independently of any pointer.
#
# Only the FRONTMATTER is consulted, by reading the first `status:` key inside the leading `---` block; a line
# reading `status: closed` inside a step body is step text, not frontmatter, and does not seal anything - a step
# ABOUT closing a recording must not close it. That read is now rec_frontmatter_value in recording-format.sh,
# which stops at the closing `---`, and the body escape deliberately does not touch a line of that shape, so the
# distinction is unchanged by E89_S06_T15. The status value is owned by close-recording.sh; this script only
# reads it.
#
# ---------------------------------------------------------------------------
# ENVIRONMENT
# ---------------------------------------------------------------------------
#   JENGA_RECORDER_NOW   the current time for stamps, UTC, as 2026-11-01T13:40:12Z. A test seam, in the style of
#                        JENGA_CHECKLIST_NOW in scripts/checklist-marker.sh; nothing should set it in use.
#
# ---------------------------------------------------------------------------
# EXIT CODES
# ---------------------------------------------------------------------------
#   0   success.
#   2   usage error: no sub-command, an unknown sub-command, a missing path, a missing title or step text, or a
#       bad JENGA_RECORDER_NOW.
#   3   append/steps: the file does not exist, or is not readable.
#   4   create: the path already exists. Nothing was written, and the existing file was not touched.
#   5   append: the file has no steps section, so there is no defensible place to write. Deliberately an error
#       rather than appending to the end of an arbitrary document.
#   6   the write failed: the directory could not be created, the temporary file could not be written, or the mv
#       did not complete. Nothing partial is left at the target path.
#   7   append: the recording is CLOSED (its frontmatter says status: closed), so it is sealed and no longer
#       accepts steps. Nothing was written. See "WHY A CLOSED RECORDING REFUSES APPENDS" below. `steps` is NOT
#       affected: a sealed recording must stay readable, since being read by the workflow-definition emitter is
#       the whole point of sealing it.
#   8   the recording's markers are AMBIGUOUS - a duplicated step or step-end id, a marker nested inside an
#       unclosed block, a seq that does not match its position, an unknown marker name - so it cannot be parsed
#       safely. The message names the offending lines. Nothing was written. Typically a legacy recording carrying
#       an injected marker, or a hand edit that duplicated one. See recording-format.sh.
#   9   append: the step text contains a line that would be read as a marker, and the recording is LEGACY
#       (recording_format_version below 2), so it cannot hold one safely. Nothing was written; `migrate` first.
#
# Compatible with macOS bash 3.2 (no associative arrays, mapfile or case-modifying expansions) and safe under
# `set -u`.
# ---------------------------------------------------------------------------

set -u
export LC_ALL=C

SELF="$(basename "$0")"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# The parse contract - the marker vocabulary, the body escape, the frontmatter read and every structural lookup
# - lives in recording-format.sh. It is sourced, never restated here.
FORMAT_LIB="$SCRIPT_DIR/recording-format.sh"
if [ ! -r "$FORMAT_LIB" ]; then
  printf '%s: cannot read the parse contract library %s; refusing to parse a recording without it\n' \
    "$(basename "$0")" "$FORMAT_LIB" >&2
  exit 6
fi
# shellcheck source=recording-format.sh
. "$FORMAT_LIB"

STEPS_ANCHOR="$REC_STEPS_ANCHOR"
STEP_MARKER_PREFIX="$REC_STEP_MARKER_PREFIX"
STEP_END_PREFIX="$REC_STEP_END_PREFIX"
RECORDING_FORMAT_VERSION="$REC_FORMAT_VERSION"

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
  recording-file.sh create <path> <title...>
  recording-file.sh append <path> <step-text...>
  recording-file.sh append <path> -            read the step text from stdin
  recording-file.sh steps  <path>
  recording-file.sh migrate <path>
  recording-file.sh -h | --help | help

Writes a session recording. create lays down frontmatter, an "# Recording: <title>" heading and an empty
steps section, whole or not at all (same-directory temp file, then an atomic mv), and refuses to clobber an
existing file. append adds exactly one step entry to the end of the steps section with a stable id and a
timestamp, leaving every earlier byte of the file unchanged, and refuses to guess when the file has no steps
section. A recording that close-recording.sh has sealed (status: closed) refuses further appends (exit 7), and
stays readable. Repeated appends are real repeated steps, in order. migrate promotes a recording written
before the body-escape rule to the current format version, and refuses one whose markers are ambiguous.
Full contract, including the step entry format every consumer parses: the header of recording-format.sh,
which this script sources.
USAGE
}

# Prints the current UTC timestamp, honouring the test seam. Returns 2 on a malformed override.
now_utc() {
  if [ -n "${JENGA_RECORDER_NOW:-}" ]; then
    if ! printf '%s' "$JENGA_RECORDER_NOW" | grep -Eq '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$'; then
      err "bad JENGA_RECORDER_NOW \"$JENGA_RECORDER_NOW\" (expected a UTC time like 2026-11-01T13:40:12Z)"
      return 2
    fi
    printf '%s' "$JENGA_RECORDER_NOW"
    return 0
  fi
  date -u +%Y-%m-%dT%H:%M:%SZ
}

# Escapes $1 for a double-quoted YAML scalar: backslash first, then the quote.
yaml_escape() {
  printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'
}

# True when $1 has a steps section: the machine anchor at column 1, or a literal "## Steps" heading for a file
# a human has edited by hand. The anchor is what this script writes; the heading is accepted so a hand-tidied
# recording does not stop accepting steps. Column-1 anchored, so a step body quoting the anchor is not one.
has_steps_section() {
  rec_has_steps_section "$1"
}

# True when $1's frontmatter marks the recording closed (status: closed inside the leading --- block). Only the
# frontmatter is scanned; see "WHY A CLOSED RECORDING REFUSES APPENDS" in the header.
is_closed() {
  [ "$(rec_frontmatter_value "$1" status)" = "closed" ]
}

# Exits 8 unless $1's markers resolve unambiguously. This is the guard that turns the silent misreads
# E89_S06_T15 closed into loud failures; the check itself is rec_check in recording-format.sh.
require_unambiguous() {
  local out
  out="$(rec_check "$1")" && return 0
  die 8 "$1 has ambiguous recording markers, so it cannot be parsed safely and nothing was changed: $(printf '%s' "$out" | tr '\n' ';')  A recording written before the body-escape rule can carry a marker inside a step body; see the parse contract in recording-format.sh, and $SELF migrate."
}

# Prints the zero-padded step id for sequence number $1 (step-001 ... step-999, then wider).
step_id_for() {
  local n="$1"
  if [ "$n" -lt 1000 ]; then
    printf 'step-%03d' "$n"
  else
    printf 'step-%d' "$n"
  fi
}

cmd_create() {
  local path="" title="" stamp dir base tmp rc

  [ "$#" -ge 1 ] || { usage >&2; die 2 "create needs a path"; }
  path="$1"; shift
  [ "$#" -ge 1 ] || { usage >&2; die 2 "create needs a title"; }
  title="$*"
  [ -n "$title" ] || die 2 "create needs a non-empty title"

  if [ -e "$path" ]; then
    die 4 "refusing to clobber an existing recording: $path"
  fi

  stamp="$(now_utc)" || exit 2

  dir="$(dirname "$path")"
  base="$(basename "$path")"
  if ! mkdir -p "$dir" 2>/dev/null; then
    die 6 "could not create the directory $dir; nothing was written"
  fi

  tmp="$dir/.tmp-$base.$$"
  rm -f "$tmp"
  trap 'rm -f "$tmp"' EXIT INT TERM

  {
    printf -- '---\n'
    printf 'recording_format_version: %s\n' "$RECORDING_FORMAT_VERSION"
    printf 'title: "%s"\n' "$(yaml_escape "$title")"
    printf 'status: in_progress\n'
    printf 'date_started: %s\n' "$stamp"
    printf 'date_ended:\n'
    printf -- '---\n'
    printf '\n'
    printf '# Recording: %s\n' "$title"
    printf '\n'
    printf 'Recorded by `j.workflow-recorder` as the session happened. Each step below was appended at the\n'
    printf 'time it occurred, so an interrupted session still leaves a complete record of everything up to\n'
    printf 'the interruption.\n'
    printf '\n'
    printf '## Steps\n'
    printf '\n'
    printf '%s\n' "$STEPS_ANCHOR"
  } > "$tmp"
  rc=$?
  if [ "$rc" -ne 0 ]; then
    die 6 "could not write the temporary file $tmp; nothing was written to $path"
  fi

  # Checked once before the write and once here: see "WHY create IS ATOMIC" in the header for the residual
  # window this leaves and why it is acceptable.
  if [ -e "$path" ]; then
    die 4 "refusing to clobber an existing recording: $path"
  fi
  if ! mv "$tmp" "$path" 2>/dev/null; then
    die 6 "could not move $tmp into place at $path; nothing partial was left at the target"
  fi

  trap - EXIT INT TERM
  printf '%s\n' "$path"
  return 0
}

cmd_append() {
  local path="" text="" prepared="" stamp count seq id

  [ "$#" -ge 1 ] || { usage >&2; die 2 "append needs a path"; }
  path="$1"; shift
  [ "$#" -ge 1 ] || { usage >&2; die 2 "append needs step text (or - to read it from stdin)"; }

  if [ "$#" -eq 1 ] && [ "$1" = "-" ]; then
    text="$(cat)"
  else
    text="$*"
  fi
  [ -n "$text" ] || die 2 "append needs non-empty step text"

  [ -f "$path" ] || die 3 "no such recording: $path"
  [ -r "$path" ] || die 3 "recording is not readable: $path"

  if is_closed "$path"; then
    die 7 "$path is closed (status: closed); a sealed recording does not accept further steps. Nothing was written."
  fi

  if ! has_steps_section "$path"; then
    die 5 "$path has no steps section (expected $STEPS_ANCHOR or a '## Steps' heading); refusing to guess where to write"
  fi

  [ -w "$path" ] || die 6 "recording is not writable: $path"

  # Before anything is written: the document must be parseable at all, and the step text must be
  # representable in it. Both are the E89_S06_T15 contract; see recording-format.sh.
  require_unambiguous "$path"
  if ! prepared="$(rec_prepare_body "$path" "$text")"; then
    die 9 "the step text has a line that would be read as a recording marker (line $(rec_body_marker_lines "$text")), and $path declares recording_format_version $(rec_format_version "$path"), which cannot hold one safely. Nothing was written. Promote it first with: $SELF migrate $path"
  fi
  text="$prepared"

  stamp="$(now_utc)" || exit 2

  # The next sequence number is derived from the highest seq already present on an open marker at column 1,
  # never from a raw count of marker-looking lines: that is what keeps a step's id unaffected by body content,
  # and so keeps "once written, a step's id never changes" true.
  count="$(rec_max_seq "$path")"
  case "$count" in
    ''|*[!0-9]*) count=0 ;;
  esac
  seq=$(( count + 1 ))
  id="$(step_id_for "$seq")"

  # A plain append. Nothing above this point in the file is read for rewriting and nothing is re-serialised,
  # which is what makes every earlier byte provably unchanged.
  {
    printf '\n'
    printf '%sid="%s" seq="%s" at="%s" -->\n' "$STEP_MARKER_PREFIX" "$id" "$seq" "$stamp"
    printf '### Step %s - %s\n' "$seq" "$stamp"
    printf '\n'
    printf '%s\n' "$text"
    printf '\n'
    printf '%sid="%s" -->\n' "$STEP_END_PREFIX" "$id"
  } >> "$path" || die 6 "could not append to $path"

  printf '%s\n' "$id"
  return 0
}

cmd_steps() {
  local path=""
  [ "$#" -ge 1 ] || { usage >&2; die 2 "steps needs a path"; }
  path="$1"
  [ -f "$path" ] || die 3 "no such recording: $path"
  [ -r "$path" ] || die 3 "recording is not readable: $path"
  require_unambiguous "$path"
  rec_step_ids "$path"
  return 0
}

# ---------------------------------------------------------------------------
# migrate: promote a recording written before the body-escape rule
# ---------------------------------------------------------------------------
# Prints the resulting format version. A document already at the current version is a no-op success, so this is
# safe to call unconditionally. It REQUIRES the document to be unambiguous first: in a clean legacy recording no
# body line is in the marker namespace at column 1, so the promotion is a pure frontmatter bump and not one body
# byte changes; in an ambiguous one, deciding which of two identical markers was the real one is a judgment this
# script must not make silently, so it refuses with exit 8 and reports the lines.
cmd_migrate() {
  local path="" ver dir base tmp
  [ "$#" -ge 1 ] || { usage >&2; die 2 "migrate needs a path"; }
  path="$1"
  [ -f "$path" ] || die 3 "no such recording: $path"
  [ -r "$path" ] || die 3 "recording is not readable: $path"

  ver="$(rec_format_version "$path")"
  if [ "$ver" -ge "$RECORDING_FORMAT_VERSION" ]; then
    printf '%s\n' "$ver"
    return 0
  fi

  require_unambiguous "$path"

  if ! head -n 1 "$path" | grep -q '^---$'; then
    die 5 "$path has no frontmatter block, so there is nowhere to record the format version; refusing to guess"
  fi
  [ -w "$path" ] || die 6 "recording is not writable: $path"

  dir="$(dirname "$path")"
  base="$(basename "$path")"
  tmp="$dir/.tmp-$base.migrate.$$"
  rm -f "$tmp"
  trap 'rm -f "$tmp"' EXIT INT TERM

  # Frontmatter only: the key is rewritten in place if it is there, inserted before the closing --- if it is
  # not, and a line of the same shape in a step body is never touched.
  awk -v version="$RECORDING_FORMAT_VERSION" '
    NR == 1 { print; next }
    done != 1 && index($0, "recording_format_version:") == 1 {
      printf "recording_format_version: %s\n", version; done = 1; next
    }
    done != 1 && $0 == "---" { printf "recording_format_version: %s\n", version; done = 1; print; next }
    { print }
  ' "$path" > "$tmp" || die 6 "could not write the temporary file $tmp; $path was not changed"

  if ! mv "$tmp" "$path" 2>/dev/null; then
    die 6 "could not move $tmp into place at $path; nothing partial was left at the target"
  fi

  trap - EXIT INT TERM
  printf '%s\n' "$RECORDING_FORMAT_VERSION"
  return 0
}

main() {
  local cmd=""
  [ "$#" -ge 1 ] || { usage >&2; die 2 "no sub-command given"; }
  cmd="$1"; shift
  case "$cmd" in
    -h|--help|help) usage; return 0 ;;
    create) cmd_create "$@" ;;
    append) cmd_append "$@" ;;
    steps)  cmd_steps "$@" ;;
    migrate) cmd_migrate "$@" ;;
    *) usage >&2; die 2 "unknown sub-command \"$cmd\"" ;;
  esac
}

main "$@"
exit $?
