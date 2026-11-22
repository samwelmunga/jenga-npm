#!/usr/bin/env bats
# bats file_tags=tier:integration
#
# Recording provenance: the `source` and `source_ref` frontmatter keys (E103, task E103_S01_T01).
#
# The contract is the PROVENANCE section of skills/j-workflow-recorder/scripts/recording-format.sh. What this
# suite pins:
#
#   1. THE DEFAULT IS LIVE AND CHANGES NOTHING ELSE. `recording-file.sh create` with no new arguments writes
#      `source: live` and no `source_ref` line, and the document is byte-identical to the pre-change format
#      apart from that one line (pinned against a literal copy of the pre-change document, not against a
#      second run of the new code).
#   2. THE SET IS CLOSED. Each of live, session-transcript, external-url and pasted is accepted (both the
#      spaced and the = option forms); anything else is a non-zero exit with a message and nothing written.
#   3. source_ref NEVER HOLDS A CREDENTIAL. A reference with URL userinfo, a credential-named query parameter,
#      a bearer token or a newline is refused before anything is written.
#   4. A RECORDING WRITTEN BEFORE THE CHANGE READS AS LIVE, through rec_source.
#   5. THE EMITTED DEFINITION CARRIES IT. emit-workflow.sh writes a top-level `provenance` object
#      ({source, source_ref?}) next to source_recording, and the existing validator still passes the file.
#
# Isolation: every test writes only inside $BATS_TEST_TMPDIR; JENGA_PROJECT_ROOT points at a throwaway project.

bats_require_minimum_version 1.5.0
load helpers/assertions

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
SCRIPTS="$REPO_ROOT/skills/j-workflow-recorder/scripts"
FILE_SCRIPT="$SCRIPTS/recording-file.sh"
FORMAT_LIB="$SCRIPTS/recording-format.sh"
EMIT_SCRIPT="$SCRIPTS/emit-workflow.sh"
ANSWER_SCRIPT="$SCRIPTS/record-answer.sh"
CLOSE_SCRIPT="$SCRIPTS/close-recording.sh"
VALIDATOR="$REPO_ROOT/scripts/workflow/validate-workflow.sh"

setup() {
  T="$BATS_TEST_TMPDIR"
  PROJ="$T/proj"
  mkdir -p "$PROJ/project/configs"
  printf '%s\n' '{"paths":{"workflows":"out/defs"}}' > "$PROJ/project/configs/workflow.json"
  DEFS="$PROJ/out/defs"
  REC="$T/ship-the-site_RECORDING.md"
  DEST="$DEFS/ship-the-site.json"

  unset JENGA_WORKFLOWS_TEST_ROOT JENGA_RECORDING_DIR
  export JENGA_PROJECT_ROOT="$PROJ"
  export JENGA_RECORDER_NOW=2026-11-02T01:02:03Z
  export JENGA_RECORDING_STATE_DIR="$T/pointer-state"
  export JENGA_RECORDING_SESSION_ID="provenance-suite-$BATS_TEST_NUMBER"
}

# The key's raw value from the leading --- block only.
fm_value() {
  awk -v key="$2:" '
    NR == 1 { next }
    $0 == "---" { exit }
    index($0, key) == 1 { v = substr($0, length(key) + 1); sub(/^[ \t]+/, "", v); print v; exit }
  ' "$1"
}

# 0 when the frontmatter has the key at all.
fm_has() {
  awk -v key="$2:" '
    NR == 1 { next }
    $0 == "---" { exit }
    index($0, key) == 1 { found = 1; exit }
    END { exit (found == 1 ? 0 : 1) }
  ' "$1"
}

lib() { bash -c '. "$1"; shift; "$@"' _ "$FORMAT_LIB" "$@"; }

# A closed recording of one confirm step, created with whatever create options are passed.
emittable_recording() {
  bash "$FILE_SCRIPT" create "$@" "$REC" "ship the site" >/dev/null
  bash "$FILE_SCRIPT" append "$REC" "Ask whether the build looks right" >/dev/null
  bash "$ANSWER_SCRIPT" "$REC" step-001 step-type confirm >/dev/null
  bash "$CLOSE_SCRIPT" "$REC" >/dev/null 2>&1
}

# ---------------------------------------------------------------------------
# The default
# ---------------------------------------------------------------------------

@test "create with no new arguments writes source: live and no source_ref line" {
  run bash "$FILE_SCRIPT" create "$REC" "A title"
  [ "$status" -eq 0 ]
  [ "$(fm_value "$REC" source)" = "live" ]
  run fm_has "$REC" source_ref
  [ "$status" -eq 1 ]
}

@test "create with no new arguments is byte-identical to the pre-change document apart from the source: live line" {
  bash "$FILE_SCRIPT" create "$REC" "A title" >/dev/null
  # The pre-change document, verbatim, as recording-file.sh wrote it before E103_S01_T01.
  cat > "$T/expected" <<'DOC'
---
recording_format_version: 2
title: "A title"
status: in_progress
date_started: 2026-11-02T01:02:03Z
date_ended:
---

# Recording: A title

Recorded by `j.workflow-recorder` as the session happened. Each step below was appended at the
time it occurred, so an interrupted session still leaves a complete record of everything up to
the interruption.

## Steps

<!-- jenga-recorder:steps-begin -->
DOC
  # Exactly one line differs, and it is the new one.
  run diff "$T/expected" "$REC"
  [ "$status" -eq 1 ]
  [ "$(printf '%s\n' "$output" | grep -c '^[<>]')" -eq 1 ]
  [ "$(printf '%s\n' "$output" | grep '^>')" = "> source: live" ]
  # Removing it gives back the pre-change bytes exactly.
  grep -vx 'source: live' "$REC" > "$T/stripped"
  cmp "$T/expected" "$T/stripped"
}

@test "rec_source reads a recording written before the change (no source key) as live" {
  printf -- '---\nrecording_format_version: 2\ntitle: "old"\nstatus: in_progress\ndate_started: 2026-11-02T01:02:03Z\ndate_ended:\n---\n\n## Steps\n\n<!-- jenga-recorder:steps-begin -->\n' > "$REC"
  [ "$(lib rec_source "$REC")" = "live" ]
  [ "$(lib rec_source_ref "$REC")" = "" ]
}

@test "a body line shaped like source: is step text, not frontmatter" {
  bash "$FILE_SCRIPT" create "$REC" "A title" >/dev/null
  bash "$FILE_SCRIPT" append "$REC" "source: pasted" >/dev/null
  [ "$(lib rec_source "$REC")" = "live" ]
}

# ---------------------------------------------------------------------------
# The closed set
# ---------------------------------------------------------------------------

@test "every allowed source value is accepted and written verbatim (spaced form)" {
  for kind in live session-transcript external-url pasted; do
    rec="$T/$kind/x_RECORDING.md"
    run bash "$FILE_SCRIPT" create --source "$kind" "$rec" "A title"
    [ "$status" -eq 0 ]
    [ "$(fm_value "$rec" source)" = "$kind" ]
    [ "$(lib rec_source "$rec")" = "$kind" ]
  done
}

@test "every allowed source value is accepted with the --source=<kind> form" {
  for kind in live session-transcript external-url pasted; do
    rec="$T/eq-$kind/x_RECORDING.md"
    run bash "$FILE_SCRIPT" create "--source=$kind" "$rec" "A title"
    [ "$status" -eq 0 ]
    [ "$(fm_value "$rec" source)" = "$kind" ]
  done
}

@test "a source outside the closed set exits non-zero with a message and writes nothing" {
  run --separate-stderr bash "$FILE_SCRIPT" create --source transcript "$REC" "A title"
  [ "$status" -eq 2 ]
  [ ! -e "$REC" ]
  assert_contains "$stderr" "transcript"
  assert_contains "$stderr" "live session-transcript external-url pasted"
  [ -z "$(ls -A "$T" | grep -F '.tmp-' || true)" ]
}

@test "an empty or case-variant source is refused too" {
  run bash "$FILE_SCRIPT" create --source "" "$REC" "A title"
  [ "$status" -eq 2 ]
  [ ! -e "$REC" ]
  run bash "$FILE_SCRIPT" create --source Live "$REC" "A title"
  [ "$status" -eq 2 ]
  [ ! -e "$REC" ]
}

@test "options are recognised only before the path: a title word shaped like an option is title text" {
  run bash "$FILE_SCRIPT" create "$REC" about --source pasted
  [ "$status" -eq 0 ]
  [ "$(fm_value "$REC" source)" = "live" ]
  [ "$(fm_value "$REC" title)" = '"about --source pasted"' ]
}

@test "an unknown option before the path is a usage error and writes nothing" {
  run bash "$FILE_SCRIPT" create --sauce live "$REC" "A title"
  [ "$status" -eq 2 ]
  [ ! -e "$REC" ]
}

# ---------------------------------------------------------------------------
# source_ref
# ---------------------------------------------------------------------------

@test "a source_ref is written as a quoted scalar and round trips through rec_source_ref" {
  local ref='/tmp/a "quoted" \ path.jsonl'
  run bash "$FILE_SCRIPT" create --source session-transcript --source-ref "$ref" "$REC" "A title"
  [ "$status" -eq 0 ]
  [ "$(fm_value "$REC" source_ref)" = '"/tmp/a \"quoted\" \\ path.jsonl"' ]
  [ "$(lib rec_source_ref "$REC")" = "$ref" ]
}

@test "an external source_ref with URL, fetch time and content hash is accepted" {
  local ref='https://example.com/setup fetched 2026-11-20T00:00:00Z sha256:0a1b2c'
  run bash "$FILE_SCRIPT" create --source external-url "--source-ref=$ref" "$REC" "A title"
  [ "$status" -eq 0 ]
  [ "$(lib rec_source_ref "$REC")" = "$ref" ]
}

@test "a source_ref that could carry a credential is refused and nothing is written" {
  for ref in 'https://user:hunter2@example.com/setup' \
             'https://example.com/setup?page=1&access_token=abc' \
             'https://bucket.example.com/f?X-Amz-Signature=deadbeef' \
             'https://example.com/?api_key=abc' \
             'Authorization: Bearer abc.def'; do
    run --separate-stderr bash "$FILE_SCRIPT" create --source external-url --source-ref "$ref" "$REC" "A title"
    [ "$status" -eq 2 ]
    [ ! -e "$REC" ]
    assert_contains "$stderr" "never holds a credential"
    # The message never echoes the refused value back.
    assert_not_contains "$stderr" "$ref"
  done
}

@test "a multi-line source_ref is refused" {
  run bash "$FILE_SCRIPT" create --source pasted --source-ref "$(printf 'a\nb')" "$REC" "A title"
  [ "$status" -eq 2 ]
  [ ! -e "$REC" ]
}

@test "a non-live recording does not claim to have been recorded live" {
  bash "$FILE_SCRIPT" create --source pasted "$REC" "A title" >/dev/null
  run grep -F 'as the session happened' "$REC"
  [ "$status" -eq 1 ]
  run grep -F 'Reconstructed after the process was performed' "$REC"
  [ "$status" -eq 0 ]
  # Still a normal recording: steps append and read back.
  bash "$FILE_SCRIPT" append "$REC" "first step" >/dev/null
  [ "$(bash "$FILE_SCRIPT" steps "$REC")" = "step-001" ]
}

# ---------------------------------------------------------------------------
# Emission
# ---------------------------------------------------------------------------

@test "emission of a default recording carries provenance.source live and no source_ref" {
  emittable_recording
  run --separate-stderr bash "$EMIT_SCRIPT" "$REC"
  [ "$status" -eq 0 ]
  [ "$(jq -c .provenance "$DEST")" = '{"source":"live"}' ]
  [ "$(jq -r .source_recording "$DEST")" = "ship-the-site_RECORDING.md" ]
  run bash "$VALIDATOR" "$DEST"
  [ "$status" -eq 0 ]
}

@test "emission carries a non-live source and its source_ref, next to source_recording" {
  local ref='https://example.com/setup fetched 2026-11-20T00:00:00Z sha256:0a1b2c'
  emittable_recording --source external-url --source-ref "$ref"
  run --separate-stderr bash "$EMIT_SCRIPT" "$REC"
  [ "$status" -eq 0 ]
  [ "$(jq -r .provenance.source "$DEST")" = "external-url" ]
  [ "$(jq -r .provenance.source_ref "$DEST")" = "$ref" ]
  [ "$(jq -c 'keys_unsorted' "$DEST")" = '["id","name","description","source_recording","provenance","steps"]' ]
  run bash "$VALIDATOR" "$DEST"
  [ "$status" -eq 0 ]
}

@test "emission for each allowed source passes the existing validator" {
  for kind in session-transcript pasted; do
    rm -f "$REC" "$DEST"
    emittable_recording --source "$kind" --source-ref "session-$kind"
    run --separate-stderr bash "$EMIT_SCRIPT" "$REC"
    [ "$status" -eq 0 ]
    [ "$(jq -c .provenance "$DEST")" = "{\"source\":\"$kind\",\"source_ref\":\"session-$kind\"}" ]
    run bash "$VALIDATOR" "$DEST"
    [ "$status" -eq 0 ]
  done
}

@test "emission of a recording written before the change (no source key) reads it as live" {
  emittable_recording
  grep -vx 'source: live' "$REC" > "$T/legacy" && cat "$T/legacy" > "$REC"
  run fm_has "$REC" source
  [ "$status" -eq 1 ]
  run --separate-stderr bash "$EMIT_SCRIPT" "$REC"
  [ "$status" -eq 0 ]
  [ "$(jq -c .provenance "$DEST")" = '{"source":"live"}' ]
}

@test "re-emission with provenance is byte-identical" {
  emittable_recording --source session-transcript --source-ref "abc-123"
  bash "$EMIT_SCRIPT" "$REC" >/dev/null
  cp "$DEST" "$T/first.json"
  bash "$EMIT_SCRIPT" "$REC" >/dev/null
  cmp "$T/first.json" "$DEST"
}

@test "a hand-edited unknown source or credential-bearing source_ref is refused at emission (exit 5), nothing written" {
  emittable_recording
  sed 's/^source: live$/source: rumour/' "$REC" > "$T/edited" && cat "$T/edited" > "$REC"
  run --separate-stderr bash "$EMIT_SCRIPT" "$REC"
  [ "$status" -eq 5 ]
  [ ! -e "$DEST" ]
  assert_contains "$stderr" "rumour"

  sed 's/^source: rumour$/source: external-url\
source_ref: "https:\/\/u:p@example.com\/x"/' "$REC" > "$T/edited" && cat "$T/edited" > "$REC"
  [ "$(fm_value "$REC" source)" = "external-url" ]
  run --separate-stderr bash "$EMIT_SCRIPT" "$REC"
  [ "$status" -eq 5 ]
  [ ! -e "$DEST" ]
}
