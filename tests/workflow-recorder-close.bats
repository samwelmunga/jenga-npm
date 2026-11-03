#!/usr/bin/env bats
#
# skills/j-workflow-recorder/scripts/close-recording.sh — the sealing layer (E89, E89_S03_T03).
#
# What this suite pins, and why each one is here rather than left to review:
#
#   1. THE ORDER IS THE WHOLE POINT. The frontmatter write happens BEFORE the pointer is cleared, and a
#      failed write must therefore leave the pointer intact. That is not observable from a happy path,
#      so it is asserted against two real, independent write failures (an unwritable recording and an
#      unwritable directory) by checking the pointer afterwards — the state the ordering exists to
#      prevent is "cleared pointer, unclosed document", and this is the only coverage that can see it.
#   2. A SEALED RECORDING STOPS BEING APPENDABLE FOR TWO INDEPENDENT REASONS, NEITHER OF THEM THE TTL.
#      The pointer is cleared (so the capture hook has nowhere to write) AND recording-file.sh append
#      refuses the closed frontmatter outright (so a caller holding the path directly is refused too).
#      Both are asserted, because either one alone would leave a route by which the workflow-definition
#      emitter could be handed a source that grew after it was read. The TTL is never advanced, waited
#      for, or set anywhere in this suite — if either mechanism depended on expiry these cases would
#      fail.
#   3. SEALING IS AN IN-PLACE FRONTMATTER REWRITE, AND THE THREE NARROWER GUARANTEES THAT REPLACE
#      recording-file.sh's STRONG APPEND PREFIX PROPERTY ARE ASSERTED, NOT ASSERTED-ABOUT. Everything
#      below the frontmatter stays byte-identical (compared as bytes, not "the text is still in
#      there"); exactly two frontmatter lines change; and a failed write leaves the file byte-identical.
#   4. THE INTERFACE IS A CONTRACT ANOTHER PIECE OF WORK CODES AGAINST. The bare no-argument form, the
#      "path on stdout and nothing else" rule, and every exit code in the header's table are pinned
#      here, because the end-of-process handoff and a later session-end close-out both call this script
#      and branch on exactly those.
#   5. THE AWKWARD CASES ARE REAL CASES, NOT ERRORS. A recording with zero steps is sealed (with a
#      warning), and an explicit path whose pointer names a DIFFERENT recording is sealed without
#      touching that other recording's pointer. Both would be tempting to refuse, and refusing either
#      would strand a document or orphan a live recording.
#
# Isolation: every test writes only inside $BATS_TEST_TMPDIR, and the pointer is redirected there via
# JENGA_RECORDING_STATE_DIR with an explicit session id, so no real session state is read or written.
# JENGA_RECORDING_TTL_MINUTES is deliberately NOT set: the suite must not depend on the TTL in either
# direction.

bats_require_minimum_version 1.5.0
load helpers/assertions

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
SCRIPT="$REPO_ROOT/skills/j-workflow-recorder/scripts/close-recording.sh"
FILE_SCRIPT="$REPO_ROOT/skills/j-workflow-recorder/scripts/recording-file.sh"
POINTER_SCRIPT="$REPO_ROOT/skills/j-workflow-recorder/scripts/active-recording.sh"

setup() {
  T="$BATS_TEST_TMPDIR"
  REC="$T/my-process_RECORDING.md"
  export JENGA_RECORDER_NOW=2026-11-02T01:02:03Z
  export JENGA_RECORDING_STATE_DIR="$T/pointer-state"
  export JENGA_RECORDING_SESSION_ID="close-suite-$BATS_TEST_NUMBER"
}

teardown() {
  # Restore anything a write-failure case made read-only, so bats can clean up after itself.
  if [ -e "$T" ]; then chmod -R u+w "$T" 2>/dev/null || true; fi
}

# A recording at $REC with $1 steps, step N's text being "step N text". No pointer is set.
make_recording() {
  local n="${1:-2}" i=1
  bash "$FILE_SCRIPT" create "$REC" "my process" >/dev/null
  while [ "$i" -le "$n" ]; do
    bash "$FILE_SCRIPT" append "$REC" "step $i text" >/dev/null
    i=$(( i + 1 ))
  done
}

point_at() {
  bash "$POINTER_SCRIPT" set "$1" --title "my process" >/dev/null
}

# Prints the frontmatter block of $1 (the leading --- block), closing marker included.
frontmatter_of() {
  awk 'NR == 1 { print; next } { print } $0 == "---" && NR > 1 { exit }' "$1"
}

# Prints everything from the line AFTER the frontmatter's closing --- to the end of $1.
body_of() {
  awk '
    NR == 1 { next }
    seen != 1 && $0 == "---" { seen = 1; next }
    seen == 1 { print }
  ' "$1"
}

# Prints the value of frontmatter key $2 in file $1, or nothing.
fm_value() {
  awk -v key="$2:" '
    NR == 1 { next }
    $0 == "---" { exit }
    index($0, key) == 1 { v = substr($0, length(key) + 1); sub(/^[ \t]+/, "", v); print v; exit }
  ' "$1"
}

skip_if_root() {
  if [ "$(id -u)" = "0" ]; then
    skip "running as root: file permissions do not prevent writes, so a write failure cannot be simulated"
  fi
}

# ---------------------------------------------------------------------------
# The happy path and the stdout contract
# ---------------------------------------------------------------------------

@test "close-recording.sh: bare, with no argument, closes the recording the pointer names" {
  make_recording 2
  point_at "$REC"

  run --separate-stderr bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$output" = "$REC" ]
  [ "$(fm_value "$REC" status)" = "closed" ]
}

@test "close-recording.sh: prints exactly the path on stdout and nothing else" {
  make_recording 2
  point_at "$REC"

  run --separate-stderr bash "$SCRIPT"
  [ "$status" -eq 0 ]
  # Exactly one line, and that line is the path. Nothing conversational, nothing on stdout but this.
  [ "${#lines[@]}" -eq 1 ]
  [ "${lines[0]}" = "$REC" ]
  [ "$stderr" = "" ]
}

@test "close-recording.sh: the frontmatter records the closed state and a closing timestamp" {
  make_recording 1
  point_at "$REC"

  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(fm_value "$REC" status)" = "closed" ]
  [ "$(fm_value "$REC" date_ended)" = "2026-11-02T01:02:03Z" ]
  # date_started is NOT disturbed by sealing.
  [ -n "$(fm_value "$REC" date_started)" ]
  [ "$(fm_value "$REC" date_started)" != "" ]
}

@test "close-recording.sh: the sealed frontmatter still parses as YAML" {
  make_recording 2
  point_at "$REC"
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]

  run python3 - "$REC" <<'PY'
import sys
raw = open(sys.argv[1]).read()
assert raw.startswith("---\n"), "no frontmatter block"
fm = raw[4:].split("\n---\n", 1)[0]
try:
    import yaml
except ImportError:
    # No pyyaml on this machine: fall back to checking every frontmatter line is a plain key: value
    # pair, which is the only shape this format ever has.
    for line in fm.splitlines():
        if line.strip() == "":
            continue
        assert ":" in line, "not a key: value line: %r" % line
        key = line.split(":", 1)[0]
        assert key and key == key.strip(), "bad key in %r" % line
    print("shape-ok")
    sys.exit(0)
data = yaml.safe_load(fm)
assert isinstance(data, dict), "frontmatter is not a mapping: %r" % (data,)
assert str(data["status"]) == "closed", data
assert data["date_ended"] is not None, data
print("yaml-ok")
PY
  [ "$status" -eq 0 ]
  assert_output_contains_any "yaml-ok" "shape-ok"
}

@test "close-recording.sh: --reason records closed_reason, and its absence writes no such key" {
  make_recording 1
  point_at "$REC"
  run bash "$SCRIPT" --reason "session-end"
  [ "$status" -eq 0 ]
  [ "$(fm_value "$REC" closed_reason)" = '"session-end"' ]

  # The ordinary case carries no marker to interpret.
  local other="$T/other_RECORDING.md"
  bash "$FILE_SCRIPT" create "$other" "other" >/dev/null
  run bash "$SCRIPT" "$other"
  [ "$status" -eq 0 ]
  [ -z "$(fm_value "$other" closed_reason)" ]
}

# ---------------------------------------------------------------------------
# Guarantee 1: the pointer is cleared — and that is what stops further appends
# ---------------------------------------------------------------------------

@test "close-recording.sh: after a successful close, active-recording.sh get exits non-zero" {
  make_recording 2
  point_at "$REC"

  run bash "$POINTER_SCRIPT" get
  [ "$status" -eq 0 ]
  [ "$output" = "$REC" ]

  run bash "$SCRIPT"
  [ "$status" -eq 0 ]

  run --separate-stderr bash "$POINTER_SCRIPT" get
  [ "$status" -ne 0 ]
  [ "$output" = "" ]
}

@test "close-recording.sh: the pointer is cleared explicitly, never left to the TTL" {
  # The pointer's expiry is never reached, advanced or shortened anywhere in this suite. If sealing
  # relied on expiry to stop a recording looking live, this case would see a live pointer with a long
  # time still to run.
  make_recording 1
  point_at "$REC"
  local expires
  expires="$(bash "$POINTER_SCRIPT" status --field expires_at)"
  [ -n "$expires" ]

  run bash "$SCRIPT"
  [ "$status" -eq 0 ]

  run bash "$POINTER_SCRIPT" status --field active
  [ "$status" -eq 0 ]
  assert_output_not_contains "true"
}

@test "recording-file.sh append against a closed recording exits non-zero and writes nothing" {
  make_recording 2
  point_at "$REC"
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]

  local before after
  before="$(cat "$REC")"
  # A caller holding the path directly, with the pointer entirely out of the picture.
  run bash "$FILE_SCRIPT" append "$REC" "a step that must not land"
  [ "$status" -ne 0 ]
  [ "$status" -eq 7 ]
  after="$(cat "$REC")"
  [ "$before" = "$after" ]
  run grep -c "a step that must not land" "$REC"
  [ "$status" -ne 0 ]
  run grep -c 'jenga-recorder:step ' "$REC"
  [ "$output" = "2" ]
}

@test "recording-file.sh steps still reads a closed recording" {
  # Sealing exists so the emitter can read the document. A seal that made it unreadable would defeat
  # its own purpose.
  make_recording 3
  point_at "$REC"
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]

  run bash "$FILE_SCRIPT" steps "$REC"
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 3 ]
  [ "${lines[0]}" = "step-001" ]
  [ "${lines[2]}" = "step-003" ]
}

@test "recording-file.sh append still works on an OPEN recording (the guard is not a blanket refusal)" {
  make_recording 1
  run bash "$FILE_SCRIPT" append "$REC" "step 2 text"
  [ "$status" -eq 0 ]
  [ "$output" = "step-002" ]
}

@test "recording-file.sh: a step body containing status: closed does not seal anything" {
  # Only the frontmatter is consulted. A line of step text is step text.
  make_recording 1
  bash "$FILE_SCRIPT" append "$REC" "status: closed" >/dev/null
  run bash "$FILE_SCRIPT" append "$REC" "step 3 text"
  [ "$status" -eq 0 ]
  [ "$output" = "step-003" ]
}

# ---------------------------------------------------------------------------
# Guarantee 2: double close is refused
# ---------------------------------------------------------------------------

@test "close-recording.sh: closing an already-closed recording exits non-zero and changes nothing" {
  make_recording 2
  point_at "$REC"
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]

  local before after
  before="$(cat "$REC")"
  run --separate-stderr bash "$SCRIPT" "$REC"
  [ "$status" -eq 6 ]
  [ "$output" = "" ]
  assert_contains "$stderr" "already closed"
  after="$(cat "$REC")"
  [ "$before" = "$after" ]
}

@test "close-recording.sh: a double close does not clear a pointer that belongs to another recording" {
  # The scenario the refusal protects: the first recording was sealed, a second one was legitimately
  # started, and someone asks to stop the first one again. A second close that cleared the pointer
  # would silently orphan the live recording.
  make_recording 1
  point_at "$REC"
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]

  local second="$T/second_RECORDING.md"
  bash "$FILE_SCRIPT" create "$second" "second" >/dev/null
  point_at "$second"

  run bash "$SCRIPT" "$REC"
  [ "$status" -eq 6 ]

  run bash "$POINTER_SCRIPT" get
  [ "$status" -eq 0 ]
  [ "$output" = "$second" ]
}

@test "close-recording.sh: --if-open makes an already-closed recording a success that writes nothing" {
  make_recording 1
  point_at "$REC"
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]

  local before after
  before="$(cat "$REC")"
  run --separate-stderr bash "$SCRIPT" "$REC" --if-open
  [ "$status" -eq 0 ]
  [ "$output" = "$REC" ]
  assert_contains "$stderr" "already closed"
  after="$(cat "$REC")"
  [ "$before" = "$after" ]
}

# ---------------------------------------------------------------------------
# Guarantee 3: the write-then-clear ORDERING, asserted against real write failures
# ---------------------------------------------------------------------------

@test "close-recording.sh: an unwritable recording fails the write and leaves the pointer intact" {
  skip_if_root
  make_recording 2
  point_at "$REC"
  local before
  before="$(cat "$REC")"

  chmod a-w "$REC"
  run --separate-stderr bash "$SCRIPT"
  [ "$status" -eq 7 ]
  [ "$output" = "" ]
  assert_contains "$stderr" "the pointer is intact"
  chmod u+w "$REC"

  # The state the ordering exists to prevent: a cleared pointer with an unclosed document.
  run bash "$POINTER_SCRIPT" get
  [ "$status" -eq 0 ]
  [ "$output" = "$REC" ]
  [ "$(cat "$REC")" = "$before" ]
  [ "$(fm_value "$REC" status)" = "in_progress" ]
}

@test "close-recording.sh: an unwritable directory fails the write and leaves the pointer intact" {
  skip_if_root
  local dir="$T/sealed-dir"
  mkdir -p "$dir"
  REC="$dir/my-process_RECORDING.md"
  make_recording 1
  point_at "$REC"
  local before
  before="$(cat "$REC")"

  chmod a-w "$dir"
  run --separate-stderr bash "$SCRIPT"
  [ "$status" -eq 7 ]
  [ "$output" = "" ]
  assert_contains "$stderr" "the pointer is intact"
  chmod u+w "$dir"

  run bash "$POINTER_SCRIPT" get
  [ "$status" -eq 0 ]
  [ "$output" = "$REC" ]
  [ "$(cat "$REC")" = "$before" ]
  [ "$(fm_value "$REC" status)" = "in_progress" ]
}

@test "close-recording.sh: a failed write leaves no temporary file behind at the recording's path" {
  skip_if_root
  make_recording 1
  point_at "$REC"
  chmod a-w "$REC"
  run bash "$SCRIPT"
  [ "$status" -eq 7 ]
  chmod u+w "$REC"

  run bash -c "ls -a \"$T\" | grep -c '^\.tmp-'"
  [ "$output" = "0" ]
}

@test "close-recording.sh: a successful seal leaves no temporary file behind" {
  make_recording 2
  point_at "$REC"
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]

  run bash -c "ls -a \"$T\" | grep -c '^\.tmp-'"
  [ "$output" = "0" ]
}

# ---------------------------------------------------------------------------
# What replaces the strong append prefix property
# ---------------------------------------------------------------------------

@test "close-recording.sh: everything below the frontmatter is byte-identical after sealing" {
  make_recording 3
  point_at "$REC"
  body_of "$REC" > "$T/body-before"

  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  body_of "$REC" > "$T/body-after"

  run cmp "$T/body-before" "$T/body-after"
  [ "$status" -eq 0 ]
}

@test "close-recording.sh: a step entry and its annotation survive sealing byte-for-byte" {
  make_recording 2
  bash "$REPO_ROOT/skills/j-workflow-recorder/scripts/record-answer.sh" \
    "$REC" step-002 end-of-process ended >/dev/null
  point_at "$REC"
  body_of "$REC" > "$T/body-before"

  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  body_of "$REC" > "$T/body-after"
  run cmp "$T/body-before" "$T/body-after"
  [ "$status" -eq 0 ]

  run grep -c 'jenga-recorder:answer ' "$REC"
  [ "$status" -eq 0 ]
  [ "$output" = "1" ]
}

@test "close-recording.sh: exactly two frontmatter lines change, and key order is preserved" {
  make_recording 1
  point_at "$REC"
  frontmatter_of "$REC" > "$T/fm-before"

  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  frontmatter_of "$REC" > "$T/fm-after"

  run python3 - "$T/fm-before" "$T/fm-after" <<'PY'
import sys
before = open(sys.argv[1]).read().splitlines()
after = open(sys.argv[2]).read().splitlines()
assert len(before) == len(after), "line count changed: %d -> %d" % (len(before), len(after))
changed = [(b, a) for b, a in zip(before, after) if b != a]
assert len(changed) == 2, "expected 2 changed lines, got %d: %r" % (len(changed), changed)
keys_before = [l.split(":", 1)[0] for l in before if ":" in l]
keys_after = [l.split(":", 1)[0] for l in after if ":" in l]
assert keys_before == keys_after, "key order changed: %r -> %r" % (keys_before, keys_after)
assert any(a == "status: closed" for _, a in changed), changed
assert any(a.startswith("date_ended: 2026-") for _, a in changed), changed
print("two-lines-ok")
PY
  [ "$status" -eq 0 ]
  assert_output_contains "two-lines-ok"
}

# ---------------------------------------------------------------------------
# A recording with zero steps
# ---------------------------------------------------------------------------

@test "close-recording.sh: a recording with zero steps is sealed, with a warning on stderr" {
  bash "$FILE_SCRIPT" create "$REC" "empty process" >/dev/null
  point_at "$REC"

  run --separate-stderr bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$output" = "$REC" ]
  assert_contains "$stderr" "no steps"
  [ "$(fm_value "$REC" status)" = "closed" ]
  [ "$(fm_value "$REC" date_ended)" = "2026-11-02T01:02:03Z" ]

  run bash "$POINTER_SCRIPT" get
  [ "$status" -ne 0 ]
}

@test "close-recording.sh: the zero-step warning goes to stderr, never to stdout" {
  bash "$FILE_SCRIPT" create "$REC" "empty process" >/dev/null
  point_at "$REC"

  run --separate-stderr bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 1 ]
  [ "${lines[0]}" = "$REC" ]
  assert_contains "$stderr" "no steps"
}

@test "close-recording.sh: the step count drives no decision — a count it cannot read still seals" {
  # The count is delegated to recording-file.sh and is advisory only. With that script unreadable the
  # count cannot be taken at all, and the seal must still be correct.
  make_recording 2
  local stash="$T/scripts"
  mkdir -p "$stash"
  cp "$SCRIPT" "$stash/close-recording.sh"
  # Nothing else alongside it, so step_count_of has no recording-file.sh to delegate to. The path is
  # passed explicitly and no pointer is set, so no pointer operation is attempted either.

  run --separate-stderr bash "$stash/close-recording.sh" "$REC"
  [ "$status" -eq 0 ]
  [ "$output" = "$REC" ]
  [ "$(fm_value "$REC" status)" = "closed" ]
  [ "$(fm_value "$REC" date_ended)" = "2026-11-02T01:02:03Z" ]
}

# ---------------------------------------------------------------------------
# The pointer naming a different recording than the path given
# ---------------------------------------------------------------------------

@test "close-recording.sh: sealing a path the pointer does not name leaves that pointer intact" {
  make_recording 2
  local other="$T/other_RECORDING.md"
  bash "$FILE_SCRIPT" create "$other" "the live one" >/dev/null
  bash "$FILE_SCRIPT" append "$other" "its own step" >/dev/null
  point_at "$other"

  run --separate-stderr bash "$SCRIPT" "$REC"
  [ "$status" -eq 0 ]
  [ "$output" = "$REC" ]
  assert_contains "$stderr" "different recording"
  [ "$(fm_value "$REC" status)" = "closed" ]

  # The live recording is untouched: its pointer still stands and it still accepts steps.
  run bash "$POINTER_SCRIPT" get
  [ "$status" -eq 0 ]
  [ "$output" = "$other" ]
  [ "$(fm_value "$other" status)" = "in_progress" ]
  run bash "$FILE_SCRIPT" append "$other" "another step"
  [ "$status" -eq 0 ]
}

@test "close-recording.sh: the different-pointer warning goes to stderr, with the path still on stdout" {
  make_recording 1
  local other="$T/other_RECORDING.md"
  bash "$FILE_SCRIPT" create "$other" "the live one" >/dev/null
  point_at "$other"

  run --separate-stderr bash "$SCRIPT" "$REC"
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 1 ]
  [ "${lines[0]}" = "$REC" ]
  assert_contains "$stderr" "different recording"
}

@test "close-recording.sh: two spellings of one path are the same recording, and the pointer IS cleared" {
  make_recording 1
  point_at "$REC"

  # The pointer holds the absolute path; the caller passes a relative one.
  run bash -c "cd '$T' && bash '$SCRIPT' ./my-process_RECORDING.md 2>/dev/null"
  [ "$status" -eq 0 ]
  [ "$output" = "./my-process_RECORDING.md" ]

  run bash "$POINTER_SCRIPT" get
  [ "$status" -ne 0 ]
}

@test "close-recording.sh: with an explicit path and no pointer at all, sealing still succeeds" {
  make_recording 1
  run bash "$POINTER_SCRIPT" get
  [ "$status" -ne 0 ]

  run --separate-stderr bash "$SCRIPT" "$REC"
  [ "$status" -eq 0 ]
  [ "$output" = "$REC" ]
  [ "$stderr" = "" ]
  [ "$(fm_value "$REC" status)" = "closed" ]
}

# ---------------------------------------------------------------------------
# Refusals: nothing is guessed, and nothing changes on disk
# ---------------------------------------------------------------------------

@test "close-recording.sh: no active recording and no argument exits non-zero and changes nothing" {
  make_recording 2
  local before
  before="$(cat "$REC")"

  run --separate-stderr bash "$SCRIPT"
  [ "$status" -eq 3 ]
  [ "$output" = "" ]
  assert_contains "$stderr" "no active recording"
  [ "$(cat "$REC")" = "$before" ]
  [ "$(fm_value "$REC" status)" = "in_progress" ]
}

@test "close-recording.sh: a missing recording exits 4" {
  run --separate-stderr bash "$SCRIPT" "$T/nope_RECORDING.md"
  [ "$status" -eq 4 ]
  [ "$output" = "" ]
  assert_contains "$stderr" "no such recording"
}

@test "close-recording.sh: a document with no frontmatter exits 5 and is left alone" {
  printf '# not a recording\n\nsome prose\n' > "$T/plain.md"
  local before
  before="$(cat "$T/plain.md")"

  run --separate-stderr bash "$SCRIPT" "$T/plain.md"
  [ "$status" -eq 5 ]
  [ "$output" = "" ]
  assert_contains "$stderr" "no frontmatter block"
  [ "$(cat "$T/plain.md")" = "$before" ]
}

@test "close-recording.sh: an unterminated frontmatter block exits 5" {
  printf -- '---\ntitle: "half a document"\nstatus: in_progress\n' > "$T/half.md"
  run --separate-stderr bash "$SCRIPT" "$T/half.md"
  [ "$status" -eq 5 ]
  [ "$output" = "" ]
  assert_contains "$stderr" "unterminated"
}

@test "close-recording.sh: an unterminated frontmatter WITH a status key is still refused, unwritten" {
  # The regression this pins: a status key used to be reported the moment it was seen, before the scan
  # could discover there is no closing ---. The document was then sealed with status: closed and NO
  # closing timestamp, at exit 0 — a terminal state that refused appends and could never be re-closed.
  # Termination has to be established before the status value can be trusted.
  printf -- '---\ntitle: "half a document"\nstatus: in_progress\n' > "$T/half-with-status.md"
  local before
  before="$(cat "$T/half-with-status.md")"

  run --separate-stderr bash "$SCRIPT" "$T/half-with-status.md"
  [ "$status" -eq 5 ]
  [ "$output" = "" ]
  assert_contains "$stderr" "unterminated"
  [ "$(cat "$T/half-with-status.md")" = "$before" ]
  assert_not_contains "$(cat "$T/half-with-status.md")" "status: closed"

  # --state must not claim to know the state of a document it refuses to parse, either.
  run --separate-stderr bash "$SCRIPT" --state "$T/half-with-status.md"
  [ "$status" -eq 5 ]
  [ "$output" = "" ]
}

@test "close-recording.sh: a frontmatter with no date_ended key gains one, and never a status alone" {
  # The closing status and the closing timestamp are written by different rules, so a document can be
  # left with one and not the other. The pre-mv sanity check refuses to install such a rewrite; this
  # case covers the path where date_ended is absent entirely and has to be inserted.
  printf -- '---\ntitle: "no ended key"\nstatus: in_progress\n---\n\n## Steps\n\nbody\n' > "$T/noend.md"

  run --separate-stderr bash "$SCRIPT" "$T/noend.md"
  [ "$status" -eq 0 ]
  [ "$output" = "$T/noend.md" ]
  [ "$(fm_value "$T/noend.md" status)" = "closed" ]
  [ "$(fm_value "$T/noend.md" date_ended)" = "2026-11-02T01:02:03Z" ]
}

@test "close-recording.sh: a frontmatter with no status key exits 5" {
  printf -- '---\ntitle: "no status here"\ndate_started: 2026-11-02T01:02:03Z\n---\n\nbody\n' > "$T/nostatus.md"
  local before
  before="$(cat "$T/nostatus.md")"

  run bash "$SCRIPT" "$T/nostatus.md"
  [ "$status" -eq 5 ]
  [ "$(cat "$T/nostatus.md")" = "$before" ]
}

@test "close-recording.sh: an unknown option, a second path and a multi-line reason are usage errors" {
  make_recording 1
  point_at "$REC"
  local before
  before="$(cat "$REC")"

  run bash "$SCRIPT" --nope
  [ "$status" -eq 2 ]

  run bash "$SCRIPT" "$REC" "$T/extra_RECORDING.md"
  [ "$status" -eq 2 ]

  run bash "$SCRIPT" "$REC" --reason "line one
line two"
  [ "$status" -eq 2 ]

  run bash "$SCRIPT" "$REC" --reason
  [ "$status" -eq 2 ]

  # Not one of them touched the recording or the pointer.
  [ "$(cat "$REC")" = "$before" ]
  run bash "$POINTER_SCRIPT" get
  [ "$status" -eq 0 ]
}

@test "close-recording.sh: a bad JENGA_RECORDER_NOW is a usage error and nothing is written" {
  make_recording 1
  point_at "$REC"
  local before
  before="$(cat "$REC")"

  export JENGA_RECORDER_NOW=not-a-time
  run bash "$SCRIPT"
  [ "$status" -eq 2 ]
  [ "$(cat "$REC")" = "$before" ]
  run bash "$POINTER_SCRIPT" get
  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# --state, and the script's own shape
# ---------------------------------------------------------------------------

@test "close-recording.sh: --state reports open then closed, and writes nothing" {
  make_recording 1
  point_at "$REC"

  run bash "$SCRIPT" --state
  [ "$status" -eq 0 ]
  [ "$output" = "open" ]

  # Read-only: the pointer is still live and the recording is still open.
  run bash "$POINTER_SCRIPT" get
  [ "$status" -eq 0 ]
  [ "$(fm_value "$REC" status)" = "in_progress" ]

  bash "$SCRIPT" >/dev/null
  run bash "$SCRIPT" --state "$REC"
  [ "$status" -eq 0 ]
  [ "$output" = "closed" ]
}

@test "close-recording.sh: exists, is executable, passes bash -n and prints usage on --help" {
  [ -f "$SCRIPT" ]
  [ -x "$SCRIPT" ]
  run bash -n "$SCRIPT"
  [ "$status" -eq 0 ]

  run bash "$SCRIPT" --help
  [ "$status" -eq 0 ]
  assert_output_contains "close-recording.sh"
  assert_output_contains "--if-open"
}

@test "close-recording.sh: names no working-tree path of its own" {
  # It derives no paths and resolves no roots: the recording comes from an argument or the pointer, and
  # the sibling scripts are located relative to this file.
  run grep -n "/Users/" "$SCRIPT"
  [ "$status" -ne 0 ]
  run grep -c "BASH_SOURCE" "$SCRIPT"
  [ "$status" -eq 0 ]
}
