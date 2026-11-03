#!/usr/bin/env bats
#
# skills/j-workflow-recorder/scripts/record-answer.sh — the annotation layer and its format
# (E89, this story's annotation task).
#
# What this suite pins, and why each one is here rather than left to review:
#
#   1. THE ANNOTATION FORMAT IS AN INTERFACE, NOT AN IMPLEMENTATION DETAIL. Three later pieces of
#      work read it: the two interrogation points write through it, and workflow emission reads it
#      for exclusion, for a step's description, and for the persisted step type. So the open
#      marker's exact shape — one line, `id`/`kind`/`value`/`at` in that order, a close marker that
#      repeats id and kind — is pinned here, as is the per-kind vocabulary of `value`. The
#      human-facing "#### Answer" heading is deliberately NOT pinned beyond its existence.
#   2. AN ANNOTATION LANDS INSIDE THE STEP IT CONCERNS. It is inserted before that step's own
#      step-end marker, which is the insertion point recording-file.sh's format defines for exactly
#      this purpose. Asserted positionally, not by "the text is in the file somewhere".
#   3. ANNOTATING ONE STEP LEAVES EVERY OTHER STEP BYTE-IDENTICAL. Asserted by extracting each
#      other step's entry before and after and comparing bytes, and by the stronger prefix property
#      that still survives when the annotated step is the last one — which is the case the
#      interrogation points actually produce.
#   4. "NOT A DEVIATION" PRODUCES NO EXCLUSION MARKER. This is the story's "no spurious branch"
#      criterion. It is asserted as an equivalence: a recording annotated `in-process` and the same
#      recording with no deviation annotation at all are indistinguishable to the single positive
#      test an emitter applies (kind="deviation" with value="out-of-process").
#   5. ONE STEP NEVER CARRIES TWO CONFLICTING ANNOTATIONS OF THE SAME KIND. A second annotation of
#      a kind is refused unless --replace is given, and --replace leaves exactly one.
#   6. NOTHING IS GUESSED. An unknown kind, a value outside a kind's vocabulary, an unknown step id
#      and a recording with no steps are all errors that change nothing on disk.
#
# Isolation: every test writes only inside $BATS_TEST_TMPDIR. Neither script under test resolves any
# root (the recording path is an argument), so there is nothing else to point away from the real
# project.

bats_require_minimum_version 1.5.0
load helpers/assertions

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
SCRIPT="$REPO_ROOT/skills/j-workflow-recorder/scripts/record-answer.sh"
FILE_SCRIPT="$REPO_ROOT/skills/j-workflow-recorder/scripts/recording-file.sh"

STEPS_ANCHOR='<!-- jenga-recorder:steps-begin -->'
CONTRACT="$REPO_ROOT/skills/j-workflow-recorder/scripts/recording-format.sh"

setup() {
  T="$BATS_TEST_TMPDIR"
  REC="$T/my-process_RECORDING.md"
  export JENGA_RECORDER_NOW=2026-11-02T00:10:12Z
}

# A recording with $1 steps, step N's text being "step N text".
make_recording() {
  local n="$1" i=1
  bash "$FILE_SCRIPT" create "$REC" "my process" >/dev/null
  while [ "$i" -le "$n" ]; do
    bash "$FILE_SCRIPT" append "$REC" "step $i text" >/dev/null
    i=$(( i + 1 ))
  done
}

# Prints the whole entry for step $1 from file $2, open marker through close marker inclusive.
step_entry() {
  awk -v id="$1" '
    index($0, "<!-- jenga-recorder:step id=\"" id "\" ") == 1 { inblk = 1 }
    inblk == 1 { print }
    inblk == 1 && index($0, "<!-- jenga-recorder:step-end id=\"" id "\" -->") == 1 { inblk = 0 }
  ' "$2"
}

# The single positive test an emitter applies to decide exclusion. Exits 0 when step $1 in file $2
# is excluded. Deliberately the WHOLE rule: if this needs a second clause, the format has failed.
#
# ANCHORED AT COLUMN 1 (E89_S06_T15). It used to be an unanchored `grep -Fq`, and that is exactly how a
# consumer gets fooled: the writer escaping a marker-looking body line does NOT rescue a substring
# search, because an escaped line still contains the marker text. The rule is still one positive
# membership test — the anchor is part of the test, not a second clause.
is_excluded() {
  awk -v pfx="<!-- jenga-recorder:answer id=\"$1\" kind=\"deviation\" value=\"out-of-process\"" '
    index($0, pfx) == 1 { found = 1; exit }
    END { exit (found == 1 ? 0 : 1) }
  ' "$2"
}

# -----------------------------------------------------------------------------
# Shape of the script itself
# -----------------------------------------------------------------------------

@test "record-answer.sh exists, is executable and passes bash -n" {
  [ -f "$SCRIPT" ]
  [ -x "$SCRIPT" ]
  run bash -n "$SCRIPT"
  [ "$status" -eq 0 ]
}

@test "the annotation format is documented in ONE place, which this script cites and sources" {
  # The format is the contract three later consumers parse. Until E89_S06_T15 it was restated in this
  # header AND in recording-file.sh's, which is how a two-script contract drifts; it now has exactly
  # one definition. What stays HERE is what this script owns: the four kinds and their vocabularies.
  local header contract
  header="$(sed -n '1,/^set -u$/p' "$SCRIPT")"
  assert_contains "$header" "THE ANNOTATION FORMAT"
  assert_contains "$header" "recording-format.sh"
  assert_contains "$header" 'THE FOUR KINDS AND THEIR VOCABULARIES'
  assert_contains "$header" 'out-of-process'
  assert_contains "$header" 'step-type'
  # The prefix-property consequence is stated rather than left for a reader to discover.
  assert_contains "$header" "APPEND PREFIX PROPERTY"
  # Sourced, not merely mentioned, so the citation cannot drift from the code.
  run grep -E '^\. "\$FORMAT_LIB"$' "$SCRIPT"
  [ "$status" -eq 0 ]

  contract="$(sed -n '1,/^REC_NAMESPACE=/p' "$CONTRACT")"
  assert_contains "$contract" 'jenga-recorder:answer id='
  assert_contains "$contract" 'jenga-recorder:answer-end'
  assert_contains "$contract" 'jenga-recorder:step id='

  # And it is NOT restated here any more. A second copy is the thing this case exists to prevent.
  run grep -Fc 'THE ANNOTATION FORMAT - THE SINGLE SOURCE OF TRUTH' "$SCRIPT"
  [ "$output" = "0" ]
}

@test "the marker-injection exit codes are documented in the script's header comment" {
  run grep -E "^#   8   the recording's markers are AMBIGUOUS" "$SCRIPT"
  [ "$status" -eq 0 ]
  run grep -E "^#   9   the answer or --note text contains a line that would be read as a marker" "$SCRIPT"
  [ "$status" -eq 0 ]
}

@test "--help prints usage on stdout and exits 0" {
  run bash "$SCRIPT" --help
  [ "$status" -eq 0 ]
  assert_output_contains "record-answer.sh <path> <step-id> <kind> <answer...>"
}

@test "no arguments is a usage error" {
  run bash "$SCRIPT"
  [ "$status" -eq 2 ]
}

# -----------------------------------------------------------------------------
# The four kinds
# -----------------------------------------------------------------------------

@test "kind deviation writes an out-of-process annotation inside the named step" {
  make_recording 2
  run bash "$SCRIPT" "$REC" step-002 deviation yes
  [ "$status" -eq 0 ]
  assert_output_contains "step-002"
  local entry
  entry="$(step_entry step-002 "$REC")"
  assert_contains "$entry" '<!-- jenga-recorder:answer id="step-002" kind="deviation" value="out-of-process" at="2026-11-02T00:10:12Z" -->'
  assert_contains "$entry" '<!-- jenga-recorder:answer-end id="step-002" kind="deviation" -->'
}

@test "kind deviation accepts the explicit vocabulary token as well as yes/no" {
  make_recording 2
  run bash "$SCRIPT" "$REC" step-001 deviation out-of-process
  [ "$status" -eq 0 ]
  run bash "$SCRIPT" "$REC" step-002 deviation in-process
  [ "$status" -eq 0 ]
  assert_contains "$(step_entry step-001 "$REC")" 'kind="deviation" value="out-of-process"'
  assert_contains "$(step_entry step-002 "$REC")" 'kind="deviation" value="in-process"'
}

@test "kind end-of-process writes ended or continuing" {
  make_recording 2
  run bash "$SCRIPT" "$REC" step-001 end-of-process no
  [ "$status" -eq 0 ]
  run bash "$SCRIPT" "$REC" step-002 end-of-process yes
  [ "$status" -eq 0 ]
  assert_contains "$(step_entry step-001 "$REC")" 'kind="end-of-process" value="continuing"'
  assert_contains "$(step_entry step-002 "$REC")" 'kind="end-of-process" value="ended"'
}

@test "kind relevance carries the prose as the payload and stated as the value" {
  make_recording 1
  run bash "$SCRIPT" "$REC" step-001 relevance "it unblocks the release by fixing the broken gate"
  [ "$status" -eq 0 ]
  local entry
  entry="$(step_entry step-001 "$REC")"
  assert_contains "$entry" 'kind="relevance" value="stated"'
  assert_contains "$entry" "it unblocks the release by fixing the broken gate"
  # The payload is retrievable verbatim, which is what an emitter uses as the step's description.
  run bash "$SCRIPT" --text "$REC" step-001 relevance
  [ "$status" -eq 0 ]
  [ "$output" = "it unblocks the release by fixing the broken gate" ]
}

@test "kind step-type persists one of the five workflow step types verbatim" {
  make_recording 5
  local i=1
  for t in skill playbook confirm compute render; do
    run bash "$SCRIPT" "$REC" "step-00$i" step-type "$t"
    [ "$status" -eq 0 ]
    run bash "$SCRIPT" --value "$REC" "step-00$i" step-type
    [ "$status" -eq 0 ]
    [ "$output" = "$t" ]
    i=$(( i + 1 ))
  done
}

@test "a step-type value outside the five workflow step types is refused and nothing is written" {
  make_recording 1
  local before
  before="$(cat "$REC")"
  run bash "$SCRIPT" "$REC" step-001 step-type wizard
  [ "$status" -eq 2 ]
  assert_output_contains "skill, playbook, confirm, compute or render"
  [ "$(cat "$REC")" = "$before" ]
}

@test "a deviation value outside its vocabulary is refused and nothing is written" {
  make_recording 1
  local before
  before="$(cat "$REC")"
  run bash "$SCRIPT" "$REC" step-001 deviation "maybe, hard to say"
  [ "$status" -eq 2 ]
  [ "$(cat "$REC")" = "$before" ]
}

@test "an unknown kind exits non-zero and the message lists the valid ones" {
  make_recording 1
  local before
  before="$(cat "$REC")"
  run bash "$SCRIPT" "$REC" step-001 vibe yes
  [ "$status" -ne 0 ]
  assert_output_contains "deviation"
  assert_output_contains "end-of-process"
  assert_output_contains "relevance"
  assert_output_contains "step-type"
  [ "$(cat "$REC")" = "$before" ]
}

@test "the answer can be read from stdin for a multi-line relevance" {
  make_recording 1
  printf 'first line of the reason\nsecond line of the reason\n' | bash "$SCRIPT" "$REC" step-001 relevance -
  run bash "$SCRIPT" --text "$REC" step-001 relevance
  [ "$status" -eq 0 ]
  assert_output_contains "first line of the reason"
  assert_output_contains "second line of the reason"
}

@test "--note records the free-text option alongside the verdict" {
  make_recording 1
  run bash "$SCRIPT" "$REC" step-001 deviation yes --note "the user typed their own answer here"
  [ "$status" -eq 0 ]
  assert_contains "$(step_entry step-001 "$REC")" "the user typed their own answer here"
}

# -----------------------------------------------------------------------------
# Attachment, isolation, and the prefix property
# -----------------------------------------------------------------------------

@test "an annotation attaches to the named step and to no other step" {
  make_recording 3
  run bash "$SCRIPT" "$REC" step-002 deviation yes
  [ "$status" -eq 0 ]
  assert_contains "$(step_entry step-002 "$REC")" 'jenga-recorder:answer id="step-002"'
  assert_not_contains "$(step_entry step-001 "$REC")" 'jenga-recorder:answer'
  assert_not_contains "$(step_entry step-003 "$REC")" 'jenga-recorder:answer'
  # Exactly one annotation in the whole document.
  [ "$(grep -Fc '<!-- jenga-recorder:answer ' "$REC")" -eq 1 ]
}

@test "the annotation sits inside the step, before that step's step-end marker" {
  make_recording 2
  bash "$SCRIPT" "$REC" step-001 deviation yes >/dev/null
  local a e
  a="$(grep -n -F '<!-- jenga-recorder:answer id="step-001"' "$REC" | cut -d: -f1)"
  e="$(grep -n -F '<!-- jenga-recorder:step-end id="step-001" -->' "$REC" | cut -d: -f1)"
  [ -n "$a" ]
  [ -n "$e" ]
  [ "$a" -lt "$e" ]
  # And after that step's own open marker, i.e. genuinely inside the entry.
  local o
  o="$(grep -n -F '<!-- jenga-recorder:step id="step-001"' "$REC" | cut -d: -f1)"
  [ "$o" -lt "$a" ]
}

@test "annotating one step leaves every other step entry byte-identical" {
  make_recording 3
  local before1 before3 after1 after3
  before1="$(step_entry step-001 "$REC")"
  before3="$(step_entry step-003 "$REC")"
  bash "$SCRIPT" "$REC" step-002 relevance "the middle step's reason" >/dev/null
  after1="$(step_entry step-001 "$REC")"
  after3="$(step_entry step-003 "$REC")"
  [ "$before1" = "$after1" ]
  [ "$before3" = "$after3" ]
}

@test "annotating leaves the frontmatter, the heading prose and the steps anchor untouched" {
  make_recording 2
  local before after
  before="$(sed -n "1,/$STEPS_ANCHOR/p" "$REC")"
  bash "$SCRIPT" "$REC" step-001 deviation yes >/dev/null
  after="$(sed -n "1,/$STEPS_ANCHOR/p" "$REC")"
  [ "$before" = "$after" ]
}

@test "annotating the last step preserves every byte up to its step-end marker" {
  # This is the case the interrogation points actually produce: annotate the step that was just
  # captured. The strong prefix property degrades by exactly one line — the final close marker moves
  # down — so the bytes up to that marker must be a byte-for-byte prefix of the annotated file.
  make_recording 2
  local before after
  before="$(sed -n '1,/<!-- jenga-recorder:step-end id="step-002" -->/p' "$REC" \
            | sed '$d')"
  bash "$SCRIPT" "$REC" step-002 step-type skill >/dev/null
  after="$(cat "$REC")"
  case "$after" in
    "$before"*) : ;;
    *) printf 'the pre-annotation prefix is not a prefix of the annotated file\n--- before ---\n%s\n--- after ---\n%s\n' "$before" "$after"; return 1 ;;
  esac
}

@test "a later recording-file.sh append still works, and still appends, after an annotation" {
  # The append prefix property is a property of append and must survive an annotation: a subsequent
  # append is still a plain >> and the sequence numbering, derived by counting open markers, is not
  # perturbed by the annotation markers.
  make_recording 2
  bash "$SCRIPT" "$REC" step-002 deviation yes >/dev/null
  local before
  before="$(cat "$REC")"
  run bash "$FILE_SCRIPT" append "$REC" "step 3 text"
  [ "$status" -eq 0 ]
  [ "$output" = "step-003" ]
  local after
  after="$(cat "$REC")"
  case "$after" in
    "$before"*) : ;;
    *) printf 'append after an annotation was not a pure append\n'; return 1 ;;
  esac
}

@test "annotating does not reorder or duplicate step entries" {
  make_recording 3
  bash "$SCRIPT" "$REC" step-002 deviation yes >/dev/null
  run bash "$FILE_SCRIPT" steps "$REC"
  [ "$status" -eq 0 ]
  [ "$output" = "step-001
step-002
step-003" ]
}

@test "no temporary file is left behind after a successful annotation" {
  make_recording 1
  bash "$SCRIPT" "$REC" step-001 deviation yes >/dev/null
  run bash -c "ls -A \"$T\" | grep -c '^\\.tmp-' || true"
  [ "$output" = "0" ]
}

# -----------------------------------------------------------------------------
# The "no spurious branch" criterion
# -----------------------------------------------------------------------------

@test "a deviation answer of no adds no marker that would exclude the step" {
  make_recording 2
  bash "$SCRIPT" "$REC" step-001 deviation no >/dev/null
  # The answer IS recorded — the story requires the answer to be part of the record.
  assert_contains "$(step_entry step-001 "$REC")" 'kind="deviation" value="in-process"'
  # And it is invisible to the one positive test an emitter applies.
  run is_excluded step-001 "$REC"
  [ "$status" -ne 0 ]
  # The affirmative case is visible to that same test, so the test is not vacuous.
  bash "$SCRIPT" "$REC" step-002 deviation yes >/dev/null
  run is_excluded step-002 "$REC"
  [ "$status" -eq 0 ]
}

@test "in-process is indistinguishable from no deviation annotation at all, to the exclusion rule" {
  # The equivalence is the actual criterion: answering "not a deviation" must leave the recorded
  # process model unchanged. A recording annotated in-process and one never asked must produce the
  # same exclusion verdict for every step.
  make_recording 2
  local untouched="$T/untouched_RECORDING.md"
  cp "$REC" "$untouched"
  bash "$SCRIPT" "$REC" step-001 deviation no >/dev/null
  bash "$SCRIPT" "$REC" step-002 deviation no >/dev/null
  local id
  for id in step-001 step-002; do
    run is_excluded "$id" "$REC"
    local annotated="$status"
    run is_excluded "$id" "$untouched"
    [ "$annotated" -eq "$status" ]
  done
}

@test "a negative answer introduces no new section, branch or heading beyond the annotation block" {
  make_recording 1
  local before_h after_h before_m after_m before_kinds after_kinds
  before_h="$(grep -c '^#' "$REC")"
  before_m="$(grep -c 'jenga-recorder:' "$REC")"
  before_kinds="$(grep -o 'jenga-recorder:[a-z-]*' "$REC" | sort -u | tr '\n' ' ')"
  bash "$SCRIPT" "$REC" step-001 deviation no >/dev/null
  after_h="$(grep -c '^#' "$REC")"
  after_m="$(grep -c 'jenga-recorder:' "$REC")"
  after_kinds="$(grep -o 'jenga-recorder:[a-z-]*' "$REC" | sort -u | tr '\n' ' ')"
  # Exactly one new heading line: the annotation block's own human-facing label.
  [ "$after_h" -eq $(( before_h + 1 )) ]
  # Exactly two new marker lines: the annotation's own open and close.
  [ "$after_m" -eq $(( before_m + 2 )) ]
  # And the only marker names added are the annotation pair — no third marker was invented for the
  # negative case, which is the shape the "no spurious branch" criterion forbids.
  [ "$before_kinds" = "jenga-recorder:step jenga-recorder:step-end jenga-recorder:steps-begin " ]
  [ "$after_kinds" = "jenga-recorder:answer jenga-recorder:answer-end jenga-recorder:step jenga-recorder:step-end jenga-recorder:steps-begin " ]
}

# -----------------------------------------------------------------------------
# Annotating twice
# -----------------------------------------------------------------------------

@test "a second annotation of the same kind is refused and changes nothing" {
  make_recording 1
  bash "$SCRIPT" "$REC" step-001 step-type skill >/dev/null
  local before
  before="$(cat "$REC")"
  run bash "$SCRIPT" "$REC" step-001 step-type confirm
  [ "$status" -eq 7 ]
  assert_output_contains "--replace"
  [ "$(cat "$REC")" = "$before" ]
}

@test "--replace supersedes the existing annotation and leaves exactly one of that kind" {
  make_recording 1
  bash "$SCRIPT" "$REC" step-001 step-type skill >/dev/null
  run bash "$SCRIPT" "$REC" step-001 step-type confirm --replace
  [ "$status" -eq 0 ]
  [ "$(grep -Fc '<!-- jenga-recorder:answer id="step-001" kind="step-type" ' "$REC")" -eq 1 ]
  run bash "$SCRIPT" --value "$REC" step-001 step-type
  [ "$status" -eq 0 ]
  [ "$output" = "confirm" ]
  # No residue of the superseded answer.
  assert_not_contains "$(cat "$REC")" 'value="skill"'
}

@test "--replace does not disturb a different kind on the same step" {
  make_recording 1
  bash "$SCRIPT" "$REC" step-001 deviation yes >/dev/null
  bash "$SCRIPT" "$REC" step-001 relevance "the stated reason" >/dev/null
  bash "$SCRIPT" "$REC" step-001 step-type skill >/dev/null
  run bash "$SCRIPT" "$REC" step-001 step-type render --replace
  [ "$status" -eq 0 ]
  run bash "$SCRIPT" --value "$REC" step-001 deviation
  [ "$output" = "out-of-process" ]
  run bash "$SCRIPT" --text "$REC" step-001 relevance
  [ "$output" = "the stated reason" ]
  run bash "$SCRIPT" --value "$REC" step-001 step-type
  [ "$output" = "render" ]
}

@test "an included step carries deviation in-process and relevance together, with no --replace" {
  # E89_S06_T17: the relevance question is asked even when the user says the step is part of the
  # process, so the pair must be accepted as two different kinds on one step.
  make_recording 1
  run bash "$SCRIPT" "$REC" step-001 deviation in-process
  [ "$status" -eq 0 ]
  run bash "$SCRIPT" "$REC" step-001 relevance "an ordinary part of the process that had not come up yet"
  [ "$status" -eq 0 ]
  run bash "$SCRIPT" --value "$REC" step-001 deviation
  [ "$output" = "in-process" ]
  run bash "$SCRIPT" --text "$REC" step-001 relevance
  [ "$output" = "an ordinary part of the process that had not come up yet" ]
  run bash "$SCRIPT" --value "$REC" step-001 relevance
  [ "$output" = "stated" ]
}

@test "three different kinds on one step are not a conflict and all three are readable" {
  make_recording 1
  bash "$SCRIPT" "$REC" step-001 deviation yes >/dev/null
  bash "$SCRIPT" "$REC" step-001 relevance "it repairs the gate" >/dev/null
  bash "$SCRIPT" "$REC" step-001 step-type compute >/dev/null
  run bash "$SCRIPT" --list "$REC" step-001
  [ "$status" -eq 0 ]
  assert_output_contains "deviation"
  assert_output_contains "relevance"
  assert_output_contains "step-type"
  [ "$(printf '%s\n' "$output" | wc -l | tr -d ' ')" = "3" ]
}

# -----------------------------------------------------------------------------
# Errors that must change nothing
# -----------------------------------------------------------------------------

@test "an unknown step id exits non-zero and modifies nothing" {
  make_recording 2
  local before
  before="$(cat "$REC")"
  run bash "$SCRIPT" "$REC" step-099 deviation yes
  [ "$status" -eq 4 ]
  assert_output_contains "step-099"
  [ "$(cat "$REC")" = "$before" ]
}

@test "a recording with no steps yet is an unknown-step error naming that condition" {
  bash "$FILE_SCRIPT" create "$REC" "my process" >/dev/null
  local before
  before="$(cat "$REC")"
  run bash "$SCRIPT" "$REC" step-001 deviation yes
  [ "$status" -eq 4 ]
  assert_output_contains "no steps at all"
  [ "$(cat "$REC")" = "$before" ]
}

@test "a document with no steps section is refused rather than guessed at" {
  printf 'just some prose, not a recording at all\n' > "$T/plain.md"
  local before
  before="$(cat "$T/plain.md")"
  run bash "$SCRIPT" "$T/plain.md" step-001 deviation yes
  [ "$status" -eq 5 ]
  [ "$(cat "$T/plain.md")" = "$before" ]
}

@test "a step with no step-end marker is refused rather than annotated somewhere plausible" {
  make_recording 1
  grep -v 'jenga-recorder:step-end' "$REC" > "$T/broken.md"
  local before
  before="$(cat "$T/broken.md")"
  run bash "$SCRIPT" "$T/broken.md" step-001 deviation yes
  [ "$status" -eq 5 ]
  assert_output_contains "step-end"
  [ "$(cat "$T/broken.md")" = "$before" ]
}

@test "a missing recording exits 3 and creates nothing" {
  run bash "$SCRIPT" "$T/absent_RECORDING.md" step-001 deviation yes
  [ "$status" -eq 3 ]
  [ ! -e "$T/absent_RECORDING.md" ]
}

@test "an empty answer is a usage error" {
  make_recording 1
  local before
  before="$(cat "$REC")"
  run bash "$SCRIPT" "$REC" step-001 relevance ""
  [ "$status" -eq 2 ]
  [ "$(cat "$REC")" = "$before" ]
}

@test "an unknown option is a usage error" {
  make_recording 1
  run bash "$SCRIPT" "$REC" step-001 deviation yes --loudly
  [ "$status" -eq 2 ]
  assert_output_contains "unknown option"
}

@test "a bad JENGA_RECORDER_NOW is a usage error and changes nothing" {
  make_recording 1
  local before
  before="$(cat "$REC")"
  JENGA_RECORDER_NOW="yesterday" run bash "$SCRIPT" "$REC" step-001 deviation yes
  [ "$status" -eq 2 ]
  [ "$(cat "$REC")" = "$before" ]
}

# -----------------------------------------------------------------------------
# Readers
# -----------------------------------------------------------------------------

@test "--value exits 1 and prints nothing when the annotation is absent" {
  make_recording 1
  run bash "$SCRIPT" --value "$REC" step-001 step-type
  [ "$status" -eq 1 ]
  [ -z "$output" ]
}

@test "--text exits 1 when the annotation is absent" {
  make_recording 1
  run bash "$SCRIPT" --text "$REC" step-001 relevance
  [ "$status" -eq 1 ]
  [ -z "$output" ]
}

@test "--list prints nothing and exits 0 for a step with no annotations" {
  make_recording 1
  run bash "$SCRIPT" --list "$REC" step-001
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "--list reports kind and value tab-separated" {
  make_recording 1
  bash "$SCRIPT" "$REC" step-001 deviation yes >/dev/null
  run bash "$SCRIPT" --list "$REC" step-001
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf 'deviation\tout-of-process')" ]
}

@test "a reader on an unknown kind is a usage error" {
  make_recording 1
  run bash "$SCRIPT" --value "$REC" step-001 vibe
  [ "$status" -eq 2 ]
}

@test "--text returns the note as well as the verdict, so nothing the user said is lost" {
  make_recording 1
  bash "$SCRIPT" "$REC" step-001 deviation yes --note "I went to fix the gate first" >/dev/null
  run bash "$SCRIPT" --text "$REC" step-001 deviation
  [ "$status" -eq 0 ]
  assert_output_contains "yes"
  assert_output_contains "I went to fix the gate first"
}

# -----------------------------------------------------------------------------
# Marker text in a verbatim body (E89_S06_T15)
# -----------------------------------------------------------------------------
# An answer body is written verbatim and the document is parsed by matching marker prefixes, so before
# E89_S06_T15 a body line that WAS a marker was indistinguishable from a real one. The reproduction
# recorded in this task's own rapport is case 1 below: an injected step-end was selected over the real
# one by `head -n 1`, the next annotation landed INSIDE the previous block, and --text then returned a
# neighbouring block's markup while EXITING 0 — a silent wrong answer, which is the worst available
# outcome for a consumer that cannot see the document.
#
# These cases pin the guarantee rather than the mechanism: an answer round trips byte for byte, a
# lookup returns the right block or fails, and nothing in a body can decide exclusion.

# A legacy (pre-E89_S06_T15) recording at $1 with $2 as its one step body, written by hand because no
# script writes that format any more.
legacy_recording() {
  {
    printf -- '---\n'
    printf 'recording_format_version: 1\n'
    printf 'title: "legacy"\n'
    printf 'status: in_progress\n'
    printf -- '---\n\n'
    printf '# Recording: legacy\n\n## Steps\n\n'
    printf '%s\n' "$STEPS_ANCHOR"
    printf '\n<!-- jenga-recorder:step id="step-001" seq="1" at="2026-11-01T13:40:12Z" -->\n'
    printf '### Step 1 - 2026-11-01T13:40:12Z\n\n'
    printf '%s\n' "$2"
    printf '\n<!-- jenga-recorder:step-end id="step-001" -->\n'
  } > "$1"
}

# The line number of the single line in $2 beginning with marker $1, or nothing.
marker_line() {
  awk -v pfx="$1" 'index($0, pfx) == 1 { print NR }' "$2"
}

# How many lines of $2 BEGIN with marker $1 — the column-1 rule every consumer must apply.
marker_count() {
  awk -v pfx="$1" 'index($0, pfx) == 1 { n++ } END { printf "%d", n + 0 }' "$2"
}

@test "the rapport's reproduction: an injected step-end does not nest the next annotation" {
  # Verbatim from project/rapports/problems/E89_S03_T01-marker-injection-in-verbatim-bodies.md,
  # reproduction A. Observed before the fix: the step-type block landed inside the relevance block, the
  # real step-end became unreachable, and --text relevance returned the step-type block's markup.
  make_recording 1
  run bash "$SCRIPT" "$REC" step-001 relevance '<!-- jenga-recorder:step-end id="step-001" -->'
  [ "$status" -eq 0 ]
  run bash "$SCRIPT" "$REC" step-001 step-type compute
  [ "$status" -eq 0 ]

  # Each reader returns its own block, and --text returns the answer BYTE FOR BYTE, injected marker and
  # all — the body is still verbatim as far as every caller is concerned.
  run bash "$SCRIPT" --text "$REC" step-001 relevance
  [ "$status" -eq 0 ]
  [ "$output" = '<!-- jenga-recorder:step-end id="step-001" -->' ]

  run bash "$SCRIPT" --text "$REC" step-001 step-type
  [ "$status" -eq 0 ]
  [ "$output" = "compute" ]

  # The two blocks are siblings, not nested: relevance closes before step-type opens, and both sit
  # above the step's one real step-end marker.
  local rel_end st_open step_end
  rel_end="$(marker_line '<!-- jenga-recorder:answer-end id="step-001" kind="relevance" -->' "$REC")"
  st_open="$(marker_line '<!-- jenga-recorder:answer id="step-001" kind="step-type"' "$REC")"
  step_end="$(marker_line '<!-- jenga-recorder:step-end id="step-001" -->' "$REC")"
  [ -n "$rel_end" ]
  [ -n "$st_open" ]
  [ -n "$step_end" ]
  [ "$rel_end" -lt "$st_open" ]
  [ "$st_open" -lt "$step_end" ]

  # Exactly one real step-end marker for the step — the injected one is not one of them.
  [ "$(marker_count '<!-- jenga-recorder:step-end id="step-001" -->' "$REC")" = "1" ]
}

@test "every marker the format uses round trips through a multi-line answer body" {
  make_recording 1
  local body
  body='diff of the recorder:
<!-- jenga-recorder:steps-begin -->
<!-- jenga-recorder:step id="step-042" seq="42" at="x" -->
<!-- jenga-recorder:step-end id="step-001" -->
<!-- jenga-recorder:answer id="step-001" kind="relevance" value="stated" at="x" -->
<!-- jenga-recorder:answer-end id="step-001" kind="relevance" -->
end of diff'
  printf '%s\n' "$body" | bash "$SCRIPT" "$REC" step-001 relevance - >/dev/null

  run bash "$SCRIPT" --text "$REC" step-001 relevance
  [ "$status" -eq 0 ]
  [ "$output" = "$body" ]

  # And a second annotation afterwards still lands in the right place.
  run bash "$SCRIPT" "$REC" step-001 step-type skill
  [ "$status" -eq 0 ]
  run bash "$SCRIPT" --value "$REC" step-001 step-type
  [ "$output" = "skill" ]
}

@test "a marker in a --note round trips too" {
  make_recording 1
  bash "$SCRIPT" "$REC" step-001 deviation yes \
    --note '<!-- jenga-recorder:answer-end id="step-001" kind="deviation" -->' >/dev/null
  run bash "$SCRIPT" --text "$REC" step-001 deviation
  [ "$status" -eq 0 ]
  assert_output_contains 'jenga-recorder:answer-end id="step-001"'
  run bash "$SCRIPT" --value "$REC" step-001 deviation
  [ "$output" = "out-of-process" ]
}

@test "an exclusion marker quoted in a body does not exclude the step" {
  # The one that matters most to the emitter: the single positive membership test must answer about
  # what was ANNOTATED, never about what was recorded. A step whose body quotes an out-of-process
  # answer marker has no deviation annotation at all, so it stays in the process model.
  make_recording 2
  bash "$SCRIPT" "$REC" step-001 relevance \
    '<!-- jenga-recorder:answer id="step-001" kind="deviation" value="out-of-process" at="x" -->' >/dev/null

  run bash "$SCRIPT" --value "$REC" step-001 deviation
  [ "$status" -eq 1 ]
  [ "$output" = "" ]

  if is_excluded step-001 "$REC"; then
    printf 'a quoted marker in an answer body excluded step-001 from emission\n'
    return 1
  fi

  # And the real thing still excludes, so the test above is not passing vacuously.
  bash "$SCRIPT" "$REC" step-002 deviation yes >/dev/null
  is_excluded step-002 "$REC"
}

@test "--list is not fooled by an annotation marker quoted in a body" {
  make_recording 1
  bash "$SCRIPT" "$REC" step-001 relevance \
    '<!-- jenga-recorder:answer id="step-001" kind="end-of-process" value="ended" at="x" -->' >/dev/null
  run bash "$SCRIPT" --list "$REC" step-001
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 1 ]
  [ "${lines[0]}" = "$(printf 'relevance\tstated')" ]
}

@test "a second annotation of a kind quoted in a body is not a conflict" {
  # The duplicate-kind refusal must be about real annotations: a body quoting a step-type marker has
  # not annotated a step type, so annotating one is still the first.
  make_recording 1
  bash "$SCRIPT" "$REC" step-001 relevance \
    '<!-- jenga-recorder:answer id="step-001" kind="step-type" value="render" at="x" -->' >/dev/null
  run bash "$SCRIPT" "$REC" step-001 step-type compute
  [ "$status" -eq 0 ]
  run bash "$SCRIPT" --value "$REC" step-001 step-type
  [ "$output" = "compute" ]
}

@test "a legacy recording refuses a marker-bearing answer rather than writing it unsafely" {
  legacy_recording "$T/legacy.md" "ordinary step text"
  local before
  before="$(cksum < "$T/legacy.md")"
  run bash "$SCRIPT" "$T/legacy.md" step-001 relevance '<!-- jenga-recorder:step-end id="step-001" -->'
  [ "$status" -eq 9 ]
  assert_output_contains "migrate"
  [ "$(cksum < "$T/legacy.md")" = "$before" ]
}

@test "a legacy recording still accepts an ordinary answer, so the refusal is not a blanket one" {
  legacy_recording "$T/legacy.md" "ordinary step text"
  run bash "$SCRIPT" "$T/legacy.md" step-001 deviation yes
  [ "$status" -eq 0 ]
  run bash "$SCRIPT" --value "$T/legacy.md" step-001 deviation
  [ "$output" = "out-of-process" ]
}

@test "an ambiguous recording fails loudly in every mode instead of returning a neighbouring block" {
  # The silent-wrong-read case, closed. Before E89_S06_T15 --text on this document exited 0 with the
  # wrong block's markup; a consumer had no way to tell. Every mode now refuses it by name.
  legacy_recording "$T/legacy.md" '<!-- jenga-recorder:step-end id="step-001" -->'

  run bash "$SCRIPT" --text "$T/legacy.md" step-001 relevance
  [ "$status" -eq 8 ]
  assert_output_contains "ambiguous"

  run bash "$SCRIPT" --value "$T/legacy.md" step-001 relevance
  [ "$status" -eq 8 ]

  run bash "$SCRIPT" --list "$T/legacy.md" step-001
  [ "$status" -eq 8 ]

  local before
  before="$(cksum < "$T/legacy.md")"
  run bash "$SCRIPT" "$T/legacy.md" step-001 deviation yes
  [ "$status" -eq 8 ]
  [ "$(cksum < "$T/legacy.md")" = "$before" ]
}

@test "a duplicated step id in a hand-edited recording is refused rather than guessed at" {
  make_recording 1
  # Two open markers for one id: "the step with that id" is no longer a single place.
  awk '{ print } index($0, "<!-- jenga-recorder:step id=\"step-001\" ") == 1 { print }' "$REC" > "$T/dup.md"
  run bash "$SCRIPT" "$T/dup.md" step-001 deviation yes
  [ "$status" -eq 8 ]
}

@test "--replace still leaves exactly one annotation when the body it supersedes contains a marker" {
  make_recording 1
  bash "$SCRIPT" "$REC" step-001 relevance '<!-- jenga-recorder:step-end id="step-001" -->' >/dev/null
  bash "$SCRIPT" --replace "$REC" step-001 relevance "the real reason" >/dev/null

  run bash "$SCRIPT" --text "$REC" step-001 relevance
  [ "$status" -eq 0 ]
  [ "$output" = "the real reason" ]
  # No residue of the superseded body, escaped or otherwise.
  run grep -c 'jenga-recorder:step-end' "$REC"
  [ "$output" = "1" ]
}

@test "an INDENTED namespace line in an answer body round trips byte for byte" {
  # The escape-domain finding, pinned. An earlier revision gated the escape on a COLUMN-1 predicate
  # while the reverse transform reversed any indented namespace line, so a body whose only namespace
  # line was indented was written unescaped and read back one space short — silently, exit 0 both ways.
  # Rapport: project/rapports/problems/E89_S06_T15-escape-domain-mismatch-breaks-body-round-trip.md.
  make_recording 1
  local body
  body=' <!-- jenga-recorder:step-end id="step-001" -->'
  printf '%s\n' "$body" | bash "$SCRIPT" "$REC" step-001 relevance - >/dev/null

  run bash "$SCRIPT" --text "$REC" step-001 relevance
  [ "$status" -eq 0 ]
  [ "$output" = "$body" ]
}

@test "a MIXED body — one namespace line at column 1, one indented — round trips byte for byte" {
  # The other half of the same finding: this case passed even while the one above failed, because a
  # column-1 line anywhere in the body used to turn the escape on for the whole of it. It must keep
  # passing, so that the fix is "the same domain on both sides" and not "a different gate".
  make_recording 1
  local body
  body='<!-- jenga-recorder:step-end id="step-001" -->
 <!-- jenga-recorder:step-end id="step-001" -->
   <!-- jenga-recorder:answer-end id="step-001" kind="relevance" -->
ordinary prose'
  printf '%s\n' "$body" | bash "$SCRIPT" "$REC" step-001 relevance - >/dev/null

  run bash "$SCRIPT" --text "$REC" step-001 relevance
  [ "$status" -eq 0 ]
  [ "$output" = "$body" ]

  # And the step still has exactly one real step-end marker, so the document is still parseable.
  [ "$(marker_count '<!-- jenga-recorder:step-end id="step-001" -->' "$REC")" = "1" ]
}

@test "an indented namespace line is escaped on disk, so the round trip is earned and not a no-op" {
  # Pins the representation: the escape runs unconditionally on a current-format body, so an indented
  # line is stored one space deeper. If this ever stops holding, the two cases above would start
  # passing for the wrong reason — an unescaped write with an unapplied reverse.
  make_recording 1
  printf ' <!-- jenga-recorder:step-end id="step-001" -->\n' \
    | bash "$SCRIPT" "$REC" step-001 relevance - >/dev/null
  run grep -c '^  <!-- jenga-recorder:step-end id="step-001" -->$' "$REC"
  [ "$status" -eq 0 ]
  [ "$output" = "1" ]
}

@test "an indented namespace line is accepted in a LEGACY recording and round trips verbatim" {
  # The legacy exit-9 decision, made explicitly and pinned. Exit 9 exists because an unescaped document
  # cannot hold a line that would be MISPARSED, and only a column-1 line is: an indented one is read by
  # nobody as a marker and is never unescaped either. Refusing it would turn a safe body into an error.
  legacy_recording "$T/legacy.md" "ordinary step text"
  local body
  body=' <!-- jenga-recorder:step-end id="step-001" -->'
  printf '%s\n' "$body" | bash "$SCRIPT" "$T/legacy.md" step-001 relevance - >/dev/null
  [ "$?" -eq 0 ]

  run bash "$SCRIPT" --text "$T/legacy.md" step-001 relevance
  [ "$status" -eq 0 ]
  [ "$output" = "$body" ]
}
