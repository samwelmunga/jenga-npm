#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# skills/j-workflow-recorder/scripts/recording-format.sh - THE RECORDING PARSE CONTRACT
# (epic E89, task E89_S06_T15)
#
# This file is the single source of truth for the recording document's machine-readable format: the
# prose contract below, and the functions that implement it. It is SOURCED, not executed:
# recording-file.sh (the write layer) and record-answer.sh (the annotation layer) both source it and
# both cite it instead of restating the format in their own headers. A change to the format is a
# change to THIS file first.
#
# It derives no paths, resolves no roots and reads no environment beyond what its callers pass it.
#
# ---------------------------------------------------------------------------
# THE DOCUMENT
# ---------------------------------------------------------------------------
# A recording is a Markdown document with a leading `---` frontmatter block, a human-facing heading,
# and a steps section that is THE LAST SECTION IN THE FILE (so appending a step is a plain >>; see
# recording-file.sh's header for why that matters). The steps section begins at the anchor
#
#     <!-- jenga-recorder:steps-begin -->
#
# and every step and every annotation lives below it.
#
# One STEP is exactly this, appended to the end of the file, preceded by one blank line:
#
#     <!-- jenga-recorder:step id="step-003" seq="3" at="2026-11-01T13:40:12Z" -->
#     ### Step 3 - 2026-11-01T13:40:12Z
#
#     <step text, verbatim, possibly several lines>
#
#     <!-- jenga-recorder:step-end id="step-003" -->
#
# One ANNOTATION is exactly this, inserted IMMEDIATELY BEFORE the annotated step's own step-end
# marker, and followed by one blank line:
#
#     <!-- jenga-recorder:answer id="step-003" kind="deviation" value="out-of-process" at="2026-11-02T00:10:12Z" -->
#     #### Answer - deviation: out-of-process
#
#     <answer text, verbatim, possibly several lines>
#
#     <!-- jenga-recorder:answer-end id="step-003" kind="deviation" -->
#
# The annotation block is DELIBERATELY the same shape as a step entry - open marker, one heading line,
# a blank line, verbatim body, a blank line, close marker - so a consumer that already parses steps
# applies the same skip rule here and needs no second parsing strategy. Nothing below changes that
# symmetry: the escape rule applies to bodies in both shapes identically, and the marker syntax is
# untouched.
#
#   - The OPEN marker is the parse anchor in both shapes. It is one line; a step marker always carries
#     id, seq and at in that order, an answer marker always carries id, kind, value and at in that
#     order. Match on the marker, never on the "### Step" / "#### Answer" heading: those are for the
#     human reader and nothing should depend on their wording.
#   - A step's id is "step-" plus its sequence number zero-padded to three digits (step-001 ...
#     step-999, then widening naturally to step-1000). Padded so a plain lexical sort of the ids
#     matches call order for any realistic recording, and STABLE: once written, a step's id never
#     changes, which is what lets the annotation layer come back later and annotate "the step the user
#     just answered about".
#   - seq is the same number unpadded, for a consumer that wants an integer without stripping zeros.
#   - at is an ISO 8601 UTC timestamp, seconds precision, Z-suffixed.
#   - A step's id is unique in the document, so for an annotation the pair (id, kind) is unique too,
#     and that is the annotation's key.
#   - value is a NORMALISED TOKEN from the kind's fixed vocabulary (see record-answer.sh's header,
#     which owns the four kinds). Consumers switch on this and never parse prose to decide anything.
#   - The CLOSE markers exist so the end of a block is unambiguous without counting, and so an
#     annotator has an unambiguous insertion point INSIDE a step.
#
# ---------------------------------------------------------------------------
# THE TWO RULES THAT MAKE THE PARSE SOUND (E89_S06_T15)
# ---------------------------------------------------------------------------
# Bodies are written verbatim and the document is parsed by matching marker prefixes, so before this
# task a body line that WAS a marker was indistinguishable from a real one. That is reachable by
# typing a marker into a prompt, not only by malice - the likeliest trigger is self-hosting, recording
# a session that edits the recorder itself, where marker strings appear in ordinary diffs and output.
# Two confirmed silent misreads followed, both recorded in
# project/rapports/problems/E89_S03_T01-marker-injection-in-verbatim-bodies.md: an injected step-end
# was selected over the real one (so --text returned a NEIGHBOURING block while exiting 0), and a raw
# `grep -Fc` step count was inflated, skipping a sequence number and breaking the stable-id guarantee.
#
# The fix is two rules which are only sound TOGETHER. Either one alone leaves the gap open.
#
#   RULE 1 - THE WRITER ESCAPES A BODY LINE THAT WOULD LOOK LIKE A MARKER.
#     A body line matching `^ *<!-- jenga-recorder:` is written with ONE EXTRA LEADING SPACE.
#     That transform is bijective on exactly that set of lines (n leading spaces become n+1, and
#     nothing else is touched), and rec_unescape_body is its inverse on the same set.
#
#     THE DOMAIN IS WHAT MAKES THE ROUND TRIP HOLD, AND IT IS THE SAME ON BOTH SIDES BY CONSTRUCTION.
#     The set is `^ *<!-- jenga-recorder:` - ANY number of leading spaces, zero included - on the write
#     side AND on the read side. It has to be wider than "at column 1" on the read side, because an
#     escaped line IS an indented line and unescape cannot otherwise tell it from a line the user
#     indented themselves; so it has to be just as wide on the write side, or an indented line gets
#     reversed without ever having been escaped. rec_prepare_body therefore applies the escape
#     UNCONDITIONALLY to a version-2 body rather than behind a "does this body need escaping?" test:
#     the transform is its own trigger, so the two cannot drift apart. A gated version of it was the one
#     real defect found in this contract - see rec_prepare_body's own comment for what it did.
#     Composed, write-then-read is the identity on EVERY body: a body round trips verbatim through the
#     document, whatever marker text it contains and however that text is indented.
#
#     The escape only ever touches lines that are HTML comments in this namespace, so no human-visible
#     rendering changes, and one leading space is far short of the four that would make a Markdown code
#     block.
#     The invariant it buys is the whole point: IN A VERSION-2 DOCUMENT, EVERY LINE IN THIS NAMESPACE
#     AT COLUMN 1 IS A REAL MARKER.
#
#   RULE 2 - EVERY READER MATCHES AT COLUMN 1, AND FAILS RATHER THAN CHOOSING.
#     A marker match is `index($0, prefix) == 1`, never an unanchored substring search. This is not
#     optional decoration on rule 1: AN ESCAPED LINE STILL MATCHES AN UNANCHORED `grep -F`, so a
#     consumer that substring-matches is fooled no matter how carefully the writer escaped. A consumer
#     of this format - including the workflow-definition emitter - MUST anchor at column 1.
#     And where a lookup can still resolve to more than one line (a hand-edited document, or a legacy
#     one), it is an ERROR (exit 8), never a pick. `head -n 1` and `tail -n 1` are both wrong answers:
#     an injected marker can sit above or below the real one depending on which step's body carries
#     it, so no positional heuristic is defensible.
#
# FRONTMATTER IS READ FROM THE LEADING `---` BLOCK ONLY (rec_frontmatter_value). A body line reading
# `status: closed` or `recording_format_version: 1` is step text, not frontmatter, and changes nothing
# about the document - a step ABOUT closing a recording must not close it. That distinction predates
# this task (it is why the closed-recording guard scans the frontmatter rather than the file) and is
# untouched by the rules above: the escape only ever rewrites lines in the marker namespace, so a
# `status:`-shaped body line is still written and still read byte-verbatim.
#
# ---------------------------------------------------------------------------
# FORMAT VERSIONS, AND WHAT HAPPENS TO A RECORDING WRITTEN BEFORE THIS CHANGE
# ---------------------------------------------------------------------------
# `recording_format_version` in the frontmatter says which representation a document uses, and is the
# ONLY thing that may decide it - never a guess from the body.
#
#   version 2  bodies are escaped per rule 1, so the column-1 invariant holds and readers may rely on
#              it. Written by every `recording-file.sh create` from E89_S06_T15 onward.
#   version 1  (and a document with no such key at all, including a hand-made one) is LEGACY: its
#              bodies are unescaped, so the invariant does NOT hold and it must never be assumed.
#
# A legacy document is handled explicitly, never silently misread, in three ways:
#
#   1. Every read and every write runs rec_check first. A legacy document whose markers are genuinely
#      ambiguous - a duplicated step or step-end id, a duplicated (id, kind) annotation, a marker
#      nested inside an unclosed block, a seq that does not match its position, an unknown marker name
#      - is REFUSED with exit 8 and the offending line numbers. That is the case the rapport found, and
#      it now fails loudly instead of returning a neighbouring block with exit 0.
#   2. A write of a body that contains a namespace line AT COLUMN 1 is refused with exit 9, because a
#      legacy document has no safe representation for it and escaping it there would make the document
#      self-inconsistent. The refusal names the migration. Note the predicate: an INDENTED namespace
#      line in a legacy body is accepted and written verbatim, because it is misparsed by nobody and is
#      never unescaped either (rule 1's reverse is gated on the declared version), so it round trips
#      exactly as it did before this contract existed.
#   3. `recording-file.sh migrate <path>` promotes a legacy document to version 2 (atomically). It
#      requires rec_check to pass first: in a clean legacy document no body line is in the namespace at
#      column 1, so promotion is a pure frontmatter bump and no body byte changes. On an AMBIGUOUS
#      document it refuses and reports, because deciding which of two identical markers was the real
#      one is a judgment a script must not make silently.
#
# A clean legacy document therefore keeps working exactly as it did before this change.
#
# ---------------------------------------------------------------------------
# EXIT CODES THIS CONTRACT ADDS (both scripts, every mode)
# ---------------------------------------------------------------------------
#   8   the recording's markers are AMBIGUOUS, so it cannot be parsed safely. Nothing was written. The
#       message names the offending line numbers. Typically a legacy document carrying an injected
#       marker, or a hand edit that duplicated one.
#   9   the body being written contains a line that would be mistaken for a marker, and the target
#       document is legacy (version < 2) so it cannot represent one safely. Nothing was written.
#       Migrate the document to version 2 and retry.
#
# ---------------------------------------------------------------------------
# API
# ---------------------------------------------------------------------------
#   rec_escape_body            stdin -> stdout, rule 1 forward
#   rec_unescape_body          stdin -> stdout, rule 1 reverse
#   rec_body_has_marker_line   <text>            0 when a namespace line sits at COLUMN 1 in it
#   rec_body_marker_lines      <text>            prints the 1-based line numbers of those lines
#   rec_prepare_body           <path> <text>     the body as it must be written there; 9 when it cannot be
#   rec_frontmatter_value      <path> <key>      the key's value from the leading --- block only
#   rec_format_version         <path>            the declared version as an integer, 0 when absent
#   rec_is_escaped_format      <path>            0 when the document is version >= 2
#   rec_has_steps_section      <path>            0 when the anchor or a '## Steps' heading is present
#   rec_step_ids               <path>            step ids in file order, one per line
#   rec_max_seq                <path>            the highest step sequence number present, 0 when none
#   rec_check                  <path>            0 when unambiguous; else prints diagnostics, returns 1
#   rec_step_open_line         <path> <id>        the line number of that step's open marker
#   rec_step_end_line          <path> <id>        the line number of that step's step-end marker
#   rec_answer_open_line       <path> <id> <kind> the line number of that annotation's open marker
#
# The three *_line functions return 0 and print the line number for a UNIQUE match, 1 when there is no
# match, and 2 when there is more than one - which callers must treat as exit 8, never as a pick.
#
# Compatible with macOS bash 3.2 (no associative arrays, mapfile or case-modifying expansions) and
# safe under `set -u`.
# ---------------------------------------------------------------------------

# The marker vocabulary. The namespace prefix is what makes a line a candidate marker at all; the five
# names below are the whole format. Changing any of them is a format change; see the contract above.
REC_NAMESPACE='<!-- jenga-recorder:'
REC_STEPS_ANCHOR='<!-- jenga-recorder:steps-begin -->'
REC_STEP_MARKER_PREFIX='<!-- jenga-recorder:step '
REC_STEP_END_PREFIX='<!-- jenga-recorder:step-end '
REC_ANSWER_MARKER_PREFIX='<!-- jenga-recorder:answer '
REC_ANSWER_END_PREFIX='<!-- jenga-recorder:answer-end '

# The version `create` writes, and the first version whose bodies are escaped per rule 1.
REC_FORMAT_VERSION=2
REC_ESCAPED_FROM_VERSION=2

# ---------------------------------------------------------------------------
# Rule 1: the body escape
# ---------------------------------------------------------------------------

# stdin -> stdout. Adds one leading space to any line matching `^ *<!-- jenga-recorder:`.
rec_escape_body() {
  awk -v ns="$REC_NAMESPACE" '
    { t = $0; sub(/^ +/, "", t)
      if (index(t, ns) == 1) { print " " $0 } else { print } }
  '
}

# stdin -> stdout. The exact inverse: removes one leading space from any line that has at least one
# leading space and is in the namespace once they are stripped.
rec_unescape_body() {
  awk -v ns="$REC_NAMESPACE" '
    { if (substr($0, 1, 1) == " ") {
        t = $0; sub(/^ +/, "", t)
        if (index(t, ns) == 1) { print substr($0, 2); next }
      }
      print }
  '
}

# 0 when <text> has a line that would be read as a marker (in the namespace, at column 1).
rec_body_has_marker_line() {
  printf '%s\n' "$1" | awk -v ns="$REC_NAMESPACE" '
    index($0, ns) == 1 { found = 1; exit }
    END { exit (found == 1 ? 0 : 1) }
  '
}

# The 1-based line numbers of those lines in <text>, for an actionable refusal message.
rec_body_marker_lines() {
  printf '%s\n' "$1" | awk -v ns="$REC_NAMESPACE" '
    index($0, ns) == 1 { printf "%s%d", (n++ ? ", " : ""), NR }
    END { if (n) printf "\n" }
  '
}

# Prints <text> ($2) as it must be written into recording <path> ($1), and returns 0; returns 9 and prints
# nothing when the body carries a namespace line at column 1 and the document is legacy, which has no safe
# representation for one. The caller turns a 9 into its own exit 9 with an actionable message - this function
# deliberately does not depend on the caller's die().
#
# THE ESCAPE RUNS UNCONDITIONALLY ON A CURRENT-FORMAT DOCUMENT. There is deliberately no "does this body need
# escaping?" test in front of it. rec_escape_body is already a per-line filter and a no-op on a body with no
# namespace line, so a trigger would buy nothing but the chance for the trigger and the transform to disagree
# about their domain - and that disagreement is a real bug, not a hypothetical one: an earlier revision of this
# function gated the escape on rec_body_has_marker_line (COLUMN 1 only) while the reverse, rec_unescape_body,
# reverses any namespace line with at least one leading space. A body whose namespace lines were all INDENTED
# was then written unescaped and read back one space short, silently and with exit 0, and the same line survived
# intact if some unrelated line in the same body happened to sit at column 1 - content-dependent corruption of
# exactly the kind this contract exists to remove. Found by E89_S06_T15's Tester; see
# project/rapports/problems/E89_S06_T15-escape-domain-mismatch-breaks-body-round-trip.md. Having no trigger at
# all makes that class of defect unreachable rather than merely fixed.
rec_prepare_body() {
  if rec_is_escaped_format "$1"; then
    printf '%s\n' "$2" | rec_escape_body
    return 0
  fi
  # Legacy. The refusal is keyed to a COLUMN-1 namespace line, and that narrower predicate is correct HERE for
  # the reason the wider one is correct above: exit 9 exists because an unescaped document cannot hold a line
  # that would be MISPARSED, and only a column-1 line is. An indented namespace line in a legacy document is
  # read by nobody as a marker and is never unescaped either (rec_unescape_body is gated on the declared
  # version), so it round trips verbatim today and must keep being accepted. Refusing it would turn a safe body
  # into an error.
  if rec_body_has_marker_line "$2"; then
    return 9
  fi
  printf '%s' "$2"
  return 0
}

# ---------------------------------------------------------------------------
# The frontmatter, read from the leading --- block ONLY
# ---------------------------------------------------------------------------

# Prints <key>'s value from <path>'s frontmatter, or nothing. Stops at the closing ---, so a body line
# of the same shape is never frontmatter; see the contract above.
rec_frontmatter_value() {
  awk -v key="$2" '
    NR == 1 { if ($0 != "---") { exit } ; infm = 1; next }
    infm == 1 && $0 == "---" { exit }
    infm == 1 && index($0, key ":") == 1 {
      v = substr($0, length(key) + 2)
      sub(/^[ \t]+/, "", v)
      sub(/[ \t\r]+$/, "", v)
      print v
      exit
    }
  ' "$1"
}

# Prints the declared format version as an integer; 0 when absent or unparseable.
rec_format_version() {
  local v
  v="$(rec_frontmatter_value "$1" recording_format_version 2>/dev/null)"
  case "${v:-}" in
    ''|*[!0-9]*) printf '0' ;;
    *) printf '%s' "$v" ;;
  esac
}

# 0 when <path> is a version whose bodies are escaped, so the column-1 invariant may be relied on.
rec_is_escaped_format() {
  local v
  v="$(rec_format_version "$1")"
  [ "$v" -ge "$REC_ESCAPED_FROM_VERSION" ]
}

# ---------------------------------------------------------------------------
# Structural lookups - rule 2
# ---------------------------------------------------------------------------

# 0 when <path> has a steps section: the machine anchor at column 1, or a literal "## Steps" heading
# for a document a human has tidied by hand.
rec_has_steps_section() {
  awk -v anchor="$REC_STEPS_ANCHOR" '
    index($0, anchor) == 1 { found = 1; exit }
    /^##[[:space:]]+Steps[[:space:]]*$/ { found = 1; exit }
    END { exit (found == 1 ? 0 : 1) }
  ' "$1"
}

# The step ids in file order, one per line, from the open markers at column 1.
rec_step_ids() {
  awk -v pfx="$REC_STEP_MARKER_PREFIX" '
    index($0, pfx) != 1 { next }
    { if (match($0, /id="[^"]*"/)) { print substr($0, RSTART + 4, RLENGTH - 5) } }
  ' "$1"
}

# The highest step sequence number in <path>, 0 when there are no steps. Derived from the seq attribute
# of the open markers at column 1, floored by how many there are so a marker written by hand without a
# seq attribute still advances the count. This is what makes the next id unaffected by body content.
rec_max_seq() {
  awk -v pfx="$REC_STEP_MARKER_PREFIX" '
    index($0, pfx) != 1 { next }
    { n++
      if (match($0, /seq="[0-9]+"/)) {
        s = substr($0, RSTART + 5, RLENGTH - 6) + 0
        if (s > m) { m = s }
      } }
    END { if (n > m) { m = n } ; printf "%d", m + 0 }
  ' "$1"
}

# Internal: prints the line numbers of lines in <path> ($1) beginning with the exact marker <$2>.
_rec_marker_lines() {
  awk -v m="$2" 'index($0, m) == 1 { print NR }' "$1"
}

# Internal: given the line numbers on stdin, print the single one and return 0; return 1 for none and
# 2 for more than one. Ambiguity is never resolved by picking.
_rec_unique_line() {
  local lines n
  lines="$(cat)"
  [ -n "$lines" ] || return 1
  n="$(printf '%s\n' "$lines" | wc -l | tr -d ' ')"
  [ "$n" -eq 1 ] || return 2
  printf '%s' "$lines"
  return 0
}

rec_step_open_line() {
  _rec_marker_lines "$1" "${REC_STEP_MARKER_PREFIX}id=\"$2\" " | _rec_unique_line
}

rec_step_end_line() {
  _rec_marker_lines "$1" "${REC_STEP_END_PREFIX}id=\"$2\" -->" | _rec_unique_line
}

rec_answer_open_line() {
  _rec_marker_lines "$1" "${REC_ANSWER_MARKER_PREFIX}id=\"$2\" kind=\"$3\" " | _rec_unique_line
}

rec_answer_end_line() {
  _rec_marker_lines "$1" "${REC_ANSWER_END_PREFIX}id=\"$2\" kind=\"$3\" -->" | _rec_unique_line
}

# ---------------------------------------------------------------------------
# rec_check - the one structural integrity pass
# ---------------------------------------------------------------------------
# 0 when <path>'s markers resolve unambiguously. Otherwise prints one "line N: <problem>" per finding
# on stdout and returns 1; the caller turns that into exit 8.
#
# It checks only what can cause a WRONG READ, not general well-formedness. In particular a step with no
# step-end marker is NOT a finding here: that case has its own exit 5 ("no insertion point; refusing to
# guess"), and folding it in would replace a precise refusal with a coarse one.
rec_check() {
  awk -v ns="$REC_NAMESPACE" \
      -v sp="$REC_STEP_MARKER_PREFIX" -v se="$REC_STEP_END_PREFIX" \
      -v ap="$REC_ANSWER_MARKER_PREFIX" -v ae="$REC_ANSWER_END_PREFIX" \
      -v sa="$REC_STEPS_ANCHOR" '
    function bad(msg) { printf "line %d: %s\n", NR, msg ; problems++ }
    function attr(line, name,   re, v) {
      re = name "=\"[^\"]*\""
      if (match(line, re)) { return substr(line, RSTART + length(name) + 2, RLENGTH - length(name) - 3) }
      return ""
    }
    index($0, ns) != 1 { next }

    index($0, sp) == 1 {
      id = attr($0, "id"); sq = attr($0, "seq")
      if (id == "") { bad("step marker with no id attribute") }
      else if (id in stepopen) { bad("a second step open marker for id \"" id "\" (first at line " stepopen[id] ")") }
      else { stepopen[id] = NR }
      if (instep) { bad("step open marker inside the unclosed step \"" curstep "\" (opened at line " stepopen[curstep] ")") }
      nsteps++
      if (sq != "" && sq + 0 != nsteps) { bad("step \"" id "\" has seq=\"" sq "\" but is step number " nsteps " in the document") }
      instep = 1; curstep = id
      next
    }

    index($0, se) == 1 {
      id = attr($0, "id")
      if (id == "") { bad("step-end marker with no id attribute") }
      else if (id in stepended) { bad("a second step-end marker for id \"" id "\" (first at line " stepended[id] ")") }
      else if (!(id in stepopen)) { bad("step-end marker for \"" id "\", which has no step open marker above it") }
      else { stepended[id] = NR }
      if (inanswer) { bad("step-end marker inside the unclosed annotation \"" curanswer "\" (opened at line " answeropen[curanswer] ")") }
      instep = 0; curstep = ""
      next
    }

    index($0, ap) == 1 {
      id = attr($0, "id"); k = attr($0, "kind"); key = id SUBSEP k
      if (id == "" || k == "") { bad("answer marker missing an id or kind attribute") }
      else if (key in answeropen) { bad("a second answer open marker for \"" id "\" kind \"" k "\" (first at line " answeropen[key] ")") }
      else if (!(id in stepopen)) { bad("answer marker for \"" id "\", which has no step open marker above it") }
      else { answeropen[key] = NR }
      if (inanswer) { bad("answer open marker inside the unclosed annotation already open at line " answeropen[curanswer]) }
      inanswer = 1; curanswer = key
      next
    }

    index($0, ae) == 1 {
      id = attr($0, "id"); k = attr($0, "kind"); key = id SUBSEP k
      if (id == "" || k == "") { bad("answer-end marker missing an id or kind attribute") }
      else if (key in answerended) { bad("a second answer-end marker for \"" id "\" kind \"" k "\" (first at line " answerended[key] ")") }
      else if (!(key in answeropen)) { bad("answer-end marker for \"" id "\" kind \"" k "\", which has no answer open marker above it") }
      else { answerended[key] = NR }
      inanswer = 0; curanswer = ""
      next
    }

    index($0, sa) == 1 {
      if (anchorseen) { bad("a second steps-begin anchor (first at line " anchorseen ")") }
      anchorseen = NR
      next
    }

    {
      rest = substr($0, length(ns) + 1)
      name = rest
      if (match(name, / /)) { name = substr(name, 1, RSTART - 1) }
      if (match(name, /-->/)) { name = substr(name, 1, RSTART - 1) }
      bad("unknown marker \"" name "\" in the jenga-recorder namespace at column 1")
    }

    END { exit (problems ? 1 : 0) }
  ' "$1"
}
