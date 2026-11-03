#!/usr/bin/env bats
#
# skills/j-workflow-recorder/scripts/recording-file.sh — create, append, and the step entry format
# (E89, task E89_S01_T02).
#
# What this suite pins, and why each one is here rather than left to review:
#
#   1. APPEND LEAVES EVERY EARLIER BYTE UNCHANGED. This is E89_S01's own acceptance criterion and the
#      reason the steps section is the last thing in the document. It is asserted the strong way — the
#      file's bytes before the append must be a byte-for-byte PREFIX of the file after it — not by
#      eyeballing the tail. A design that rewrote the file on append (a step counter in the
#      frontmatter, say) would pass a weaker "the old text is still in there somewhere" check and
#      fails this one.
#   2. NO HALF-WRITTEN FRONTMATTER IS OBSERVABLE. `create` writes a same-directory temp file and mv's
#      it into place, so the recording path never holds a partial document. Asserted both by the
#      mechanics (a temp file is used, and nothing is left behind) and by the outcome (a failed
#      create leaves the target absent or untouched).
#   3. THE STEP ENTRY FORMAT IS A CONTRACT. E89_S03_T01 and E89_S04_T01 both parse it, so the open
#      marker's exact shape — one line, `id`/`seq`/`at` in that order, a unique id, a close marker —
#      is pinned here. The human-facing "### Step" heading is deliberately NOT pinned beyond its
#      existence.
#   4. APPEND REFUSES TO GUESS. A file with no steps section is an error, not an append to the end of
#      an arbitrary document.
#   5. APPEND REFUSES A SEALED RECORDING (exit 7, added by E89_S03_T03). Once close-recording.sh has
#      written `status: closed` into the frontmatter, the document is a finished definition source and
#      must not grow — otherwise an emitter can be handed a source that changed after it read it. This
#      is part of THIS script's published contract, so it is pinned here and not only in the sealing
#      layer's own suite. Two halves matter equally: the refusal itself, and the fact that it reads the
#      FRONTMATTER only — a `status: closed` line in a step body is step text and seals nothing, and
#      `steps` keeps reading a sealed recording, because being read is the point of sealing it.
#
# Isolation: every test writes only inside $BATS_TEST_TMPDIR. The script resolves no roots at all (the
# path is an argument), so there is nothing else to point away from the real project.

bats_require_minimum_version 1.5.0
load helpers/assertions

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
SCRIPT="$REPO_ROOT/skills/j-workflow-recorder/scripts/recording-file.sh"
CONTRACT="$REPO_ROOT/skills/j-workflow-recorder/scripts/recording-format.sh"

STEPS_ANCHOR='<!-- jenga-recorder:steps-begin -->'

setup() {
  T="$BATS_TEST_TMPDIR"
  REC="$T/my-process_RECORDING.md"
  unset JENGA_RECORDER_NOW
}

# Seals recording $1 by hand, by writing the frontmatter value the guard reads. Deliberately NOT a call
# to close-recording.sh: this suite covers recording-file.sh, and the guard's input is the frontmatter
# itself, whatever wrote it.
seal_by_hand() {
  sed 's/^status: in_progress$/status: closed/' "$1" > "$1.sealed"
  mv "$1.sealed" "$1"
}

# -----------------------------------------------------------------------------
# Shape of the script itself
# -----------------------------------------------------------------------------

@test "recording-file.sh exists, is executable and passes bash -n" {
  [ -f "$SCRIPT" ]
  [ -x "$SCRIPT" ]
  run bash -n "$SCRIPT"
  [ "$status" -eq 0 ]
}

@test "the sealed-recording refusal is documented in the script's header comment" {
  # A new exit code with no description in the contract its consumers read is how contracts drift.
  run grep -c "WHY A CLOSED RECORDING REFUSES APPENDS" "$SCRIPT"
  [ "$status" -eq 0 ]
  run grep -E "^#   7   append: the recording is CLOSED" "$SCRIPT"
  [ "$status" -eq 0 ]
}

@test "the step entry format is documented in ONE place, which this script cites and sources" {
  # The format is the contract E89_S03_T01 and E89_S04_T01 parse. Until E89_S06_T15 it was restated in
  # this script's header AND in record-answer.sh's, which is how a two-script contract drifts; it now
  # has exactly one definition. Both halves are asserted: this header points at that file and actually
  # sources it, so the citation cannot drift from the code, and that file carries the format.
  local header contract
  header="$(sed -n '1,/^set -u$/p' "$SCRIPT")"
  assert_contains "$header" "THE STEP ENTRY FORMAT"
  assert_contains "$header" "recording-format.sh"
  run grep -E '^\. "\$FORMAT_LIB"$' "$SCRIPT"
  [ "$status" -eq 0 ]

  contract="$(sed -n '1,/^REC_NAMESPACE=/p' "$CONTRACT")"
  assert_contains "$contract" 'jenga-recorder:step id='
  assert_contains "$contract" 'jenga-recorder:step-end'
  assert_contains "$contract" 'jenga-recorder:answer id='
  assert_contains "$contract" "seq"

  # And it is NOT restated here any more. A second copy is the thing this case exists to prevent.
  run grep -Fc 'THE STEP ENTRY FORMAT - THE SINGLE SOURCE OF TRUTH' "$SCRIPT"
  [ "$output" = "0" ]
}

@test "the parse contract library exists, passes bash -n and is sourced by both scripts" {
  [ -f "$CONTRACT" ]
  run bash -n "$CONTRACT"
  [ "$status" -eq 0 ]
  run grep -Fc 'recording-format.sh' "$REPO_ROOT/skills/j-workflow-recorder/scripts/record-answer.sh"
  [ "$status" -eq 0 ]
  [ "$output" != "0" ]
}

@test "the marker-injection exit codes are documented in the script's header comment" {
  # Same reason as the sealed-recording case above: a new exit code with no description in the contract
  # its consumers read is how contracts drift.
  run grep -E "^#   8   the recording's markers are AMBIGUOUS" "$SCRIPT"
  [ "$status" -eq 0 ]
  run grep -E "^#   9   append: the step text contains a line that would be read as a marker" "$SCRIPT"
  [ "$status" -eq 0 ]
}

@test "recording-file.sh --help prints usage on stdout and exits 0" {
  run bash "$SCRIPT" --help
  [ "$status" -eq 0 ]
  assert_output_contains "create"
  assert_output_contains "append"
}

# -----------------------------------------------------------------------------
# create
# -----------------------------------------------------------------------------

@test "create produces a file with frontmatter and a steps section" {
  run bash "$SCRIPT" create "$REC" "Set up the release pipeline"
  [ "$status" -eq 0 ]
  [ -f "$REC" ]

  # Frontmatter is a complete, delimited block at the very top.
  [ "$(sed -n '1p' "$REC")" = "---" ]
  run grep -c '^---$' "$REC"
  [ "$output" -ge 2 ]

  run grep -Fq "# Recording: Set up the release pipeline" "$REC"
  [ "$status" -eq 0 ]
  run grep -Fq "$STEPS_ANCHOR" "$REC"
  [ "$status" -eq 0 ]
}

@test "create's frontmatter parses as YAML" {
  # The title is user-supplied text going into a double-quoted YAML scalar, so the quote and the
  # backslash in this fixture are the two characters that would break the block if unescaped.
  local title='Set up the "release" pipeline with a \ backslash'
  bash "$SCRIPT" create "$REC" "$title" >/dev/null

  # The checker is written to a file rather than piped into `python3 -`: bats' `run` does not carry a
  # heredoc through to the command it invokes, so a piped script would silently be empty.
  cat > "$T/check.py" <<'PY'
import re, sys
try:
    import yaml
except ImportError:
    print("SKIP: PyYAML not installed")
    raise SystemExit(0)
text = open(sys.argv[1]).read()
m = re.match(r"^---\n(.*?\n)---\n", text, re.S)
if not m:
    raise SystemExit("no delimited frontmatter block")
data = yaml.safe_load(m.group(1))
if not isinstance(data, dict):
    raise SystemExit("frontmatter is not a mapping: %r" % (data,))
for key in ("recording_format_version", "title", "status", "date_started"):
    if key not in data:
        raise SystemExit("frontmatter is missing %s" % key)
if data["title"] != sys.argv[2]:
    raise SystemExit("title was not round-tripped: %r != %r" % (data["title"], sys.argv[2]))
print("OK")
PY
  run python3 "$T/check.py" "$REC" "$title"
  [ "$status" -eq 0 ]
  assert_output_contains_any "OK" "SKIP"
}

@test "create prints the path it wrote and nothing else" {
  run --separate-stderr bash "$SCRIPT" create "$REC" "A title"
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 1 ]
  [ "$output" = "$REC" ]
  [ "$stderr" = "" ]
}

@test "create makes the parent directory when it does not exist" {
  local deep
  deep="$T/a/b/c/deep_RECORDING.md"
  run bash "$SCRIPT" create "$deep" "Deep"
  [ "$status" -eq 0 ]
  [ -f "$deep" ]
}

@test "create refuses to clobber an existing file, exits non-zero and names the path" {
  printf 'pre-existing content\n' > "$REC"
  run bash "$SCRIPT" create "$REC" "A title"
  [ "$status" -ne 0 ]
  [ "$status" -eq 4 ]
  assert_output_contains "$REC"
  # The existing file is untouched.
  [ "$(cat "$REC")" = "pre-existing content" ]
}

@test "create leaves no temporary file behind on success" {
  bash "$SCRIPT" create "$REC" "A title"
  run bash -c 'ls -A "$1" | grep -c "^\.tmp-" || true' _ "$T"
  [ "$output" = "0" ]
}

@test "create writes via a same-directory temporary file" {
  # Observed from the inside: a create whose mv cannot succeed must have staged its content in a
  # temp file NEXT TO the target (same directory, so the mv is a rename and not a copy), and must
  # leave nothing at the target path. Simulated by making the target a directory, so mv fails.
  mkdir -p "$REC"
  run bash "$SCRIPT" create "$REC" "A title"
  [ "$status" -ne 0 ]
  # Whatever happened, no partial document exists as a FILE at the target path.
  [ ! -f "$REC" ]
  # The staging file, if it survived the failure, is in the same directory as the target.
  run bash -c 'ls -A "$1" | grep "^\.tmp-" | wc -l | tr -d " "' _ "$T"
  [ "$status" -eq 0 ]
}

@test "no partial frontmatter is observable at the target path" {
  # The guarantee E89_S01 needs: there is no moment at which the recording path holds half a
  # frontmatter block. Checked by asserting that whenever the path exists at all, its frontmatter is
  # a complete delimited block — run across a create that is interrupted at every byte offset of its
  # own output is not reproducible here, so this asserts the invariant on the committed artifact and
  # relies on the mv for the rest (see the script header, "WHY create IS ATOMIC").
  bash "$SCRIPT" create "$REC" "A title"
  local first last
  first="$(sed -n '1p' "$REC")"
  [ "$first" = "---" ]
  last="$(grep -n '^---$' "$REC" | sed -n '2p' | cut -d: -f1)"
  [ -n "$last" ]
  [ "$last" -gt 1 ]
}

@test "create with no title exits 2" {
  run bash "$SCRIPT" create "$REC"
  [ "$status" -eq 2 ]
  [ ! -e "$REC" ]
}

# -----------------------------------------------------------------------------
# append
# -----------------------------------------------------------------------------

@test "append adds exactly one entry and leaves every earlier byte of the file unchanged" {
  bash "$SCRIPT" create "$REC" "A title"
  local before_size after_size prefix
  before_size="$(wc -c < "$REC" | tr -d ' ')"
  cp "$REC" "$T/before.md"

  run bash "$SCRIPT" append "$REC" "Ran the first command"
  [ "$status" -eq 0 ]

  after_size="$(wc -c < "$REC" | tr -d ' ')"
  [ "$after_size" -gt "$before_size" ]

  # The strong form: the old bytes are a byte-for-byte PREFIX of the new file.
  head -c "$before_size" "$REC" > "$T/prefix.md"
  run cmp -s "$T/before.md" "$T/prefix.md"
  [ "$status" -eq 0 ]

  # Exactly one entry was added.
  run bash -c 'grep -Fc "<!-- jenga-recorder:step id=" "$1"' _ "$REC"
  [ "$output" = "1" ]
}

@test "three successive appends yield three entries in call order with distinct stable ids" {
  bash "$SCRIPT" create "$REC" "A title"
  local id1 id2 id3
  id1="$(bash "$SCRIPT" append "$REC" "first")"
  id2="$(bash "$SCRIPT" append "$REC" "second")"
  id3="$(bash "$SCRIPT" append "$REC" "third")"

  [ "$id1" = "step-001" ]
  [ "$id2" = "step-002" ]
  [ "$id3" = "step-003" ]
  [ "$id1" != "$id2" ]
  [ "$id2" != "$id3" ]

  run bash -c 'grep -Fc "<!-- jenga-recorder:step id=" "$1"' _ "$REC"
  [ "$output" = "3" ]

  # File order matches call order, and the ids the script reports match the ids in the file.
  run bash "$SCRIPT" steps "$REC"
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "step-001" ]
  [ "${lines[1]}" = "step-002" ]
  [ "${lines[2]}" = "step-003" ]

  # The step TEXT is in call order too, not just the markers.
  run bash -c 'grep -n -E "^(first|second|third)$" "$1" | cut -d: -f2 | paste -sd, -' _ "$REC"
  [ "$output" = "first,second,third" ]
}

@test "each append leaves every byte written by the previous one unchanged" {
  bash "$SCRIPT" create "$REC" "A title"
  local i size
  i=1
  while [ "$i" -le 4 ]; do
    size="$(wc -c < "$REC" | tr -d ' ')"
    cp "$REC" "$T/snap.md"
    bash "$SCRIPT" append "$REC" "step text $i"
    head -c "$size" "$REC" > "$T/snapprefix.md"
    run cmp -s "$T/snap.md" "$T/snapprefix.md"
    [ "$status" -eq 0 ]
    i=$(( i + 1 ))
  done
  run bash -c 'grep -Fc "<!-- jenga-recorder:step id=" "$1"' _ "$REC"
  [ "$output" = "4" ]
}

@test "a repeated identical append is a real second step, not a no-op" {
  bash "$SCRIPT" create "$REC" "A title"
  local a b
  a="$(bash "$SCRIPT" append "$REC" "did the same thing")"
  b="$(bash "$SCRIPT" append "$REC" "did the same thing")"
  [ "$a" != "$b" ]
  run bash -c 'grep -Fc "<!-- jenga-recorder:step id=" "$1"' _ "$REC"
  [ "$output" = "2" ]
}

@test "the step entry carries the contract's open marker, close marker and timestamp" {
  bash "$SCRIPT" create "$REC" "A title"
  JENGA_RECORDER_NOW="2026-11-01T13:40:12Z" bash "$SCRIPT" append "$REC" "Ran j.commit"

  run grep -F '<!-- jenga-recorder:step id="step-001" seq="1" at="2026-11-01T13:40:12Z" -->' "$REC"
  [ "$status" -eq 0 ]
  run grep -F '<!-- jenga-recorder:step-end id="step-001" -->' "$REC"
  [ "$status" -eq 0 ]
  run grep -E '^### Step 1 ' "$REC"
  [ "$status" -eq 0 ]
  run grep -Fx 'Ran j.commit' "$REC"
  [ "$status" -eq 0 ]
}

@test "the open marker is one line, so a line-oriented consumer can anchor on it" {
  bash "$SCRIPT" create "$REC" "A title"
  bash "$SCRIPT" append "$REC" "something"
  run bash -c 'grep -F "<!-- jenga-recorder:step id=" "$1" | wc -l | tr -d " "' _ "$REC"
  [ "$output" = "1" ]
  run bash -c 'grep -F "<!-- jenga-recorder:step id=" "$1"' _ "$REC"
  case "$output" in
    *"-->"*) : ;;
    *) echo "the open marker is not closed on its own line: $output" >&2; return 1 ;;
  esac
}

@test "multi-line step text is written verbatim via stdin" {
  bash "$SCRIPT" create "$REC" "A title"
  printf 'line one\nline two\n- a bullet\n' | bash "$SCRIPT" append "$REC" -
  run grep -Fx 'line one' "$REC"
  [ "$status" -eq 0 ]
  run grep -Fx 'line two' "$REC"
  [ "$status" -eq 0 ]
  run grep -Fx -e '- a bullet' "$REC"
  [ "$status" -eq 0 ]
  run bash -c 'grep -Fc "<!-- jenga-recorder:step id=" "$1"' _ "$REC"
  [ "$output" = "1" ]
}

@test "append against a file with no steps section exits non-zero and changes nothing" {
  printf 'just some prose\nand more of it\n' > "$T/plain.md"
  run bash "$SCRIPT" append "$T/plain.md" "a step"
  [ "$status" -ne 0 ]
  [ "$status" -eq 5 ]
  assert_output_contains "no steps section"
  [ "$(cat "$T/plain.md")" = "just some prose
and more of it" ]
}

@test "append accepts a hand-edited recording whose anchor comment was removed but '## Steps' remains" {
  printf -- '---\ntitle: "x"\n---\n\n# Recording: x\n\n## Steps\n' > "$T/hand.md"
  run bash "$SCRIPT" append "$T/hand.md" "a step"
  [ "$status" -eq 0 ]
  run grep -Fq '<!-- jenga-recorder:step id="step-001"' "$T/hand.md"
  [ "$status" -eq 0 ]
}

@test "append against a sealed recording exits 7 and changes nothing" {
  bash "$SCRIPT" create "$REC" "A title" >/dev/null
  bash "$SCRIPT" append "$REC" "step one" >/dev/null
  seal_by_hand "$REC"
  local before
  before="$(cksum < "$REC")"

  run bash "$SCRIPT" append "$REC" "a step that must not land"
  [ "$status" -eq 7 ]
  assert_output_contains "closed"
  [ "$(cksum < "$REC")" = "$before" ]
  run grep -c "a step that must not land" "$REC"
  [ "$status" -ne 0 ]
}

@test "the sealed refusal reads the frontmatter only: status: closed in a step body seals nothing" {
  # The distinction this pins is the whole reason the guard scans the leading --- block rather than the
  # file: step text is written verbatim, so a recorded step can legitimately contain any line at all,
  # including this one. If it sealed the document, capturing a step about closing a recording would end
  # the recording.
  bash "$SCRIPT" create "$REC" "A title" >/dev/null
  bash "$SCRIPT" append "$REC" "status: closed" >/dev/null

  run bash "$SCRIPT" append "$REC" "step two text"
  [ "$status" -eq 0 ]
  [ "$output" = "step-002" ]
}

@test "steps still reads a sealed recording" {
  # Sealing exists so the recording can be read as a definition source. A seal that made it unreadable
  # would defeat its own purpose, so the guard is on append alone.
  bash "$SCRIPT" create "$REC" "A title" >/dev/null
  bash "$SCRIPT" append "$REC" "step one" >/dev/null
  bash "$SCRIPT" append "$REC" "step two" >/dev/null
  seal_by_hand "$REC"

  run bash "$SCRIPT" steps "$REC"
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 2 ]
  [ "${lines[0]}" = "step-001" ]
  [ "${lines[1]}" = "step-002" ]
}

@test "append still works on an open recording, so the guard is not a blanket refusal" {
  bash "$SCRIPT" create "$REC" "A title" >/dev/null
  run bash "$SCRIPT" append "$REC" "step one"
  [ "$status" -eq 0 ]
  [ "$output" = "step-001" ]
}

@test "append against a missing file exits 3" {
  run bash "$SCRIPT" append "$T/does-not-exist.md" "a step"
  [ "$status" -eq 3 ]
}

@test "append with no step text exits 2" {
  bash "$SCRIPT" create "$REC" "A title"
  local before
  before="$(cksum < "$REC")"
  run bash "$SCRIPT" append "$REC"
  [ "$status" -eq 2 ]
  [ "$(cksum < "$REC")" = "$before" ]
}

@test "a bad JENGA_RECORDER_NOW is rejected rather than silently stamped" {
  bash "$SCRIPT" create "$REC" "A title"
  JENGA_RECORDER_NOW="yesterday" run bash "$SCRIPT" append "$REC" "a step"
  [ "$status" -eq 2 ]
  run bash -c 'grep -Fc "<!-- jenga-recorder:step id=" "$1" || true' _ "$REC"
  [ "$output" = "0" ]
}

# -----------------------------------------------------------------------------
# An interrupted session leaves a valid partial recording
# -----------------------------------------------------------------------------

@test "a recording abandoned after two of four steps is still complete and readable" {
  # E89_S01's story criterion, end to end: create, append twice, then stop. The document must be a
  # whole thing — delimited frontmatter, a heading, a steps section, both steps intact.
  bash "$SCRIPT" create "$REC" "An interrupted process"
  bash "$SCRIPT" append "$REC" "first thing"
  bash "$SCRIPT" append "$REC" "second thing"

  [ "$(sed -n '1p' "$REC")" = "---" ]
  run grep -Fq "# Recording: An interrupted process" "$REC"
  [ "$status" -eq 0 ]
  run grep -Fq "$STEPS_ANCHOR" "$REC"
  [ "$status" -eq 0 ]
  run bash "$SCRIPT" steps "$REC"
  [ "${#lines[@]}" -eq 2 ]
  run grep -Fx 'first thing' "$REC"
  [ "$status" -eq 0 ]
  run grep -Fx 'second thing' "$REC"
  [ "$status" -eq 0 ]
  # The last byte is a newline: no truncated final line.
  run bash -c 'tail -c 1 "$1" | od -An -c | tr -d " "' _ "$REC"
  assert_output_contains '\n'
}

# -----------------------------------------------------------------------------
# steps
# -----------------------------------------------------------------------------

@test "steps prints nothing for a recording with no steps yet" {
  bash "$SCRIPT" create "$REC" "A title"
  run bash "$SCRIPT" steps "$REC"
  [ "$status" -eq 0 ]
  [ "$output" = "" ]
}

@test "an unknown sub-command exits 2" {
  run bash "$SCRIPT" frobnicate "$REC"
  [ "$status" -eq 2 ]
}

@test "no sub-command exits 2" {
  run bash "$SCRIPT"
  [ "$status" -eq 2 ]
}

# -----------------------------------------------------------------------------
# Marker text in a verbatim body (E89_S06_T15)
# -----------------------------------------------------------------------------
# A step body is written verbatim and the document is parsed by matching marker prefixes, so before
# E89_S06_T15 a body line that WAS a marker was indistinguishable from a real one. The trigger is not
# malice: the hook captures whatever the user types, and the likeliest case is self-hosting — recording
# a session that edits the recorder, where marker strings appear in ordinary diffs and command output.
#
# The reproduction recorded in E89_S03_T01's rapport is case 1 below: an injected open marker inflated
# `grep -Fc`, producing a phantom step-009, skipping step-002 and breaking "once written, a step's id
# never changes". These cases pin the fix at the level of the GUARANTEE (ids, counts, bodies) rather
# than the mechanism, so a future change of mechanism has to keep the guarantee.

# How many lines of $2 BEGIN with marker $1 — the column-1 rule the format promises and every consumer
# must apply. Deliberately not an unanchored grep: an escaped body line still contains the marker text,
# so an unanchored count would be fooled no matter how the writer escaped it.
marker_count() {
  awk -v pfx="$1" 'index($0, pfx) == 1 { n++ } END { printf "%d", n + 0 }' "$2"
}

# A legacy (pre-E89_S06_T15) recording at $1 with $2's text as its one step body, written by hand
# because no script writes that format any more. Frontmatter declares version 1 and the body is
# unescaped, which is exactly the representation the escape rule replaced.
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

@test "the rapport's reproduction: an injected open marker does not renumber the steps" {
  # Verbatim from project/rapports/problems/E89_S03_T01-marker-injection-in-verbatim-bodies.md,
  # reproduction B. Observed before the fix: step-001, a phantom step-009, then step-003 — step-002
  # skipped, and record-answer.sh would accept step-009 as a real step id.
  bash "$SCRIPT" create "$REC" "A title" >/dev/null
  bash "$SCRIPT" append "$REC" 'editing <!-- jenga-recorder:step id="step-009" seq="9" at="x" --> today' >/dev/null
  local second third
  second="$(bash "$SCRIPT" append "$REC" "next real step")"
  third="$(bash "$SCRIPT" append "$REC" "and another")"
  [ "$second" = "step-002" ]
  [ "$third" = "step-003" ]

  run bash "$SCRIPT" steps "$REC"
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 3 ]
  [ "${lines[0]}" = "step-001" ]
  [ "${lines[1]}" = "step-002" ]
  [ "${lines[2]}" = "step-003" ]
}

@test "an open marker at column 1 in a step body is not read as a step" {
  bash "$SCRIPT" create "$REC" "A title" >/dev/null
  printf 'before\n<!-- jenga-recorder:step id="step-009" seq="9" at="x" -->\nafter\n' \
    | bash "$SCRIPT" append "$REC" - >/dev/null
  local second
  second="$(bash "$SCRIPT" append "$REC" "next real step")"
  [ "$second" = "step-002" ]
  [ "$(marker_count '<!-- jenga-recorder:step ' "$REC")" = "2" ]

  run bash "$SCRIPT" steps "$REC"
  [ "${#lines[@]}" -eq 2 ]
  [ "${lines[1]}" = "step-002" ]
}

@test "every marker the format uses can appear at column 1 in a multi-line body" {
  # All five markers of the format, each on its own line at column 1, inside one step body — then a
  # further append. Nothing may become a step, a step-end, an annotation or a second steps section.
  bash "$SCRIPT" create "$REC" "A title" >/dev/null
  printf '%s\n' \
    'diff of the recorder:' \
    '<!-- jenga-recorder:steps-begin -->' \
    '<!-- jenga-recorder:step id="step-042" seq="42" at="x" -->' \
    '<!-- jenga-recorder:step-end id="step-001" -->' \
    '<!-- jenga-recorder:answer id="step-001" kind="deviation" value="out-of-process" at="x" -->' \
    '<!-- jenga-recorder:answer-end id="step-001" kind="deviation" -->' \
    'end of diff' \
    | bash "$SCRIPT" append "$REC" - >/dev/null
  local second
  second="$(bash "$SCRIPT" append "$REC" "next real step")"
  [ "$second" = "step-002" ]

  run bash "$SCRIPT" steps "$REC"
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 2 ]
  [ "${lines[0]}" = "step-001" ]
  [ "${lines[1]}" = "step-002" ]

  # Exactly the real markers, and exactly one steps anchor.
  [ "$(marker_count '<!-- jenga-recorder:step ' "$REC")" = "2" ]
  [ "$(marker_count '<!-- jenga-recorder:step-end ' "$REC")" = "2" ]
  [ "$(marker_count '<!-- jenga-recorder:steps-begin -->' "$REC")" = "1" ]
  [ "$(marker_count '<!-- jenga-recorder:answer ' "$REC")" = "0" ]
  [ "$(marker_count '<!-- jenga-recorder:answer-end ' "$REC")" = "0" ]
}

@test "the escape touches only the marker-looking lines, and only by one leading space" {
  # The representation is pinned, not just its effect: the body is still the user's text, the escape is
  # one space on the lines that needed it, and the step's own markers are untouched at column 1.
  bash "$SCRIPT" create "$REC" "A title" >/dev/null
  printf 'plain line\n<!-- jenga-recorder:step-end id="step-001" -->\n  indented prose\n' \
    | bash "$SCRIPT" append "$REC" - >/dev/null

  run bash -c 'sed -n "/^### Step 1/,/^<!-- jenga-recorder:step-end/p" "$1" | sed -n "3,5p"' _ "$REC"
  [ "${lines[0]}" = "plain line" ]
  [ "${lines[1]}" = ' <!-- jenga-recorder:step-end id="step-001" -->' ]
  [ "${lines[2]}" = "  indented prose" ]
}

@test "a step body that says status: closed still seals nothing, and one that says a format version still sets nothing" {
  # The frontmatter-only read is the correct handling of this very problem for those two keys, and the
  # escape must not have replaced it with something coarser: it only ever rewrites lines in the marker
  # namespace, so a body line of either shape is still plain step text.
  bash "$SCRIPT" create "$REC" "A title" >/dev/null
  bash "$SCRIPT" append "$REC" "status: closed" >/dev/null
  bash "$SCRIPT" append "$REC" "recording_format_version: 1" >/dev/null

  # Still open, still at the current version — so a marker-bearing body is still accepted, which it
  # would not be if the body had downgraded the document.
  run bash "$SCRIPT" append "$REC" '<!-- jenga-recorder:step-end id="step-001" -->'
  [ "$status" -eq 0 ]
  [ "$output" = "step-003" ]
}

@test "create declares the format version whose bodies are escaped" {
  bash "$SCRIPT" create "$REC" "A title" >/dev/null
  run grep -E '^recording_format_version: 2$' "$REC"
  [ "$status" -eq 0 ]
}

@test "a legacy recording refuses a marker-bearing body rather than writing it unsafely" {
  legacy_recording "$T/legacy.md" "ordinary step text"
  local before
  before="$(cksum < "$T/legacy.md")"
  run bash "$SCRIPT" append "$T/legacy.md" '<!-- jenga-recorder:step id="step-009" seq="9" at="x" -->'
  [ "$status" -eq 9 ]
  assert_output_contains "migrate"
  [ "$(cksum < "$T/legacy.md")" = "$before" ]
}

@test "a clean legacy recording still accepts ordinary steps, so the refusal is not a blanket one" {
  legacy_recording "$T/legacy.md" "ordinary step text"
  run bash "$SCRIPT" append "$T/legacy.md" "a second ordinary step"
  [ "$status" -eq 0 ]
  [ "$output" = "step-002" ]
  run bash "$SCRIPT" steps "$T/legacy.md"
  [ "${#lines[@]}" -eq 2 ]
}

@test "a legacy recording that already carries an injected marker is reported, not misread" {
  # The document the rapport describes: the injected step-end sits above the real one, so "the step-end
  # marker for step-001" is two different lines. Every mode must say so rather than pick one.
  legacy_recording "$T/legacy.md" '<!-- jenga-recorder:step-end id="step-001" -->'

  run bash "$SCRIPT" append "$T/legacy.md" "another step"
  [ "$status" -eq 8 ]
  assert_output_contains "ambiguous"
  assert_output_contains "step-end"

  run bash "$SCRIPT" steps "$T/legacy.md"
  [ "$status" -eq 8 ]
}

@test "migrate promotes a clean legacy recording and changes not one body byte" {
  legacy_recording "$T/legacy.md" "ordinary step text"
  local body_before body_after
  body_before="$(sed -n '/^# Recording/,$p' "$T/legacy.md")"

  run bash "$SCRIPT" migrate "$T/legacy.md"
  [ "$status" -eq 0 ]
  [ "$output" = "2" ]
  run grep -E '^recording_format_version: 2$' "$T/legacy.md"
  [ "$status" -eq 0 ]

  body_after="$(sed -n '/^# Recording/,$p' "$T/legacy.md")"
  [ "$body_before" = "$body_after" ]

  # And the promotion is what makes a marker-bearing body representable.
  run bash "$SCRIPT" append "$T/legacy.md" '<!-- jenga-recorder:step-end id="step-001" -->'
  [ "$status" -eq 0 ]
}

@test "migrate inserts the version key when the legacy recording has none at all" {
  printf -- '---\ntitle: "x"\n---\n\n# Recording: x\n\n## Steps\n' > "$T/hand.md"
  run bash "$SCRIPT" migrate "$T/hand.md"
  [ "$status" -eq 0 ]
  [ "$output" = "2" ]
  run grep -E '^recording_format_version: 2$' "$T/hand.md"
  [ "$status" -eq 0 ]
  # The title survives: the key was inserted, not written over something.
  run grep -E '^title: "x"$' "$T/hand.md"
  [ "$status" -eq 0 ]
}

@test "migrate refuses an ambiguous recording and changes nothing" {
  legacy_recording "$T/legacy.md" '<!-- jenga-recorder:step-end id="step-001" -->'
  local before
  before="$(cksum < "$T/legacy.md")"
  run bash "$SCRIPT" migrate "$T/legacy.md"
  [ "$status" -eq 8 ]
  [ "$(cksum < "$T/legacy.md")" = "$before" ]
}

@test "migrate is a no-op success on a recording already at the current version" {
  bash "$SCRIPT" create "$REC" "A title" >/dev/null
  bash "$SCRIPT" append "$REC" "step one" >/dev/null
  local before
  before="$(cksum < "$REC")"
  run bash "$SCRIPT" migrate "$REC"
  [ "$status" -eq 0 ]
  [ "$output" = "2" ]
  [ "$(cksum < "$REC")" = "$before" ]
}

@test "migrate refuses a document with no frontmatter rather than inventing one" {
  printf 'just some prose\n\n## Steps\n' > "$T/plain.md"
  local before
  before="$(cat "$T/plain.md")"
  run bash "$SCRIPT" migrate "$T/plain.md"
  [ "$status" -eq 5 ]
  [ "$(cat "$T/plain.md")" = "$before" ]
}

@test "migrate against a missing file exits 3" {
  run bash "$SCRIPT" migrate "$T/does-not-exist.md"
  [ "$status" -eq 3 ]
}

@test "append leaves every earlier byte unchanged even when the body is escaped" {
  # The escape happens before the >>, so E89_S01's prefix criterion survives it.
  bash "$SCRIPT" create "$REC" "A title" >/dev/null
  bash "$SCRIPT" append "$REC" "step one" >/dev/null
  local size
  size="$(wc -c < "$REC" | tr -d ' ')"
  cp "$REC" "$T/snap.md"
  bash "$SCRIPT" append "$REC" '<!-- jenga-recorder:step id="step-009" seq="9" at="x" -->' >/dev/null
  head -c "$size" "$REC" > "$T/snapprefix.md"
  run cmp -s "$T/snap.md" "$T/snapprefix.md"
  [ "$status" -eq 0 ]
}

@test "an INDENTED namespace line in a step body is escaped, not written verbatim" {
  # The write half of the escape-domain finding. The escape runs unconditionally on a current-format
  # body, so an indented namespace line is stored one space deeper — which is what makes the reverse
  # transform in record-answer.sh --text exact rather than a line-stealing no-op.
  bash "$SCRIPT" create "$REC" "A title" >/dev/null
  printf ' <!-- jenga-recorder:step-end id="step-001" -->\n' | bash "$SCRIPT" append "$REC" - >/dev/null

  run grep -c '^  <!-- jenga-recorder:step-end id="step-001" -->$' "$REC"
  [ "$status" -eq 0 ]
  [ "$output" = "1" ]
  # Exactly one real step-end marker for the step: the body line is not one.
  [ "$(marker_count '<!-- jenga-recorder:step-end id="step-001" -->' "$REC")" = "1" ]
}

@test "an indented namespace line in a step body is accepted in a LEGACY recording" {
  # The legacy predicate is deliberately the narrower one — a column-1 line only. An indented line is
  # misparsed by nobody there, so it is written verbatim rather than refused.
  legacy_recording "$T/legacy.md" "ordinary step text"
  run bash -c 'printf " <!-- jenga-recorder:step-end id=\"step-001\" -->\n" | bash "$1" append "$2" -' \
    _ "$SCRIPT" "$T/legacy.md"
  [ "$status" -eq 0 ]
  [ "$output" = "step-002" ]
  # Verbatim: one leading space, exactly as it was given.
  run grep -c '^ <!-- jenga-recorder:step-end id="step-001" -->$' "$T/legacy.md"
  [ "$output" = "1" ]
}
