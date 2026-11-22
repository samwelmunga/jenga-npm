#!/usr/bin/env bats
# bats file_tags=tier:integration
#
# Repair of a legacy array-shaped project/logs/events.json on install and in `jenga doctor`
# (E75_S02_T01). Covers lib/events-log-repair.js, its call from scripts/postinstall.js and the
# event-log check in lib/commands/doctor.js.
#
# Every test builds fixture trees under $BATS_TEST_TMPDIR. The real project/logs/events.json is
# neither read nor written: postinstall runs from a synthetic package copy (real lib/ and scripts/,
# which are the code under test) against a synthetic consumer root passed as INIT_CWD, and doctor
# runs with targetRoot / cwd set to a fixture consumer.
#
# The interactive confirm is driven through doctor's documented isInteractive/confirmFn test seam,
# exactly as tests/postinstall-doctor-cleanup.bats does; the non-TTY refusal goes through the real
# bin/jenga.js with piped stdin.

load helpers/assertions

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"

# An awkward-enough array: escapes, raw non-ASCII, nesting, irregular layout.
write_array_log() {
  mkdir -p "$(dirname "$1")"
  cat > "$1" <<'JSON'
[
  {"event":"a","msg":"café é","nested":{"k":[1,2,{"x":"[b], c]"}]}},
  {
    "event" : "b",
    "text": "line\nbreak \"quoted\"",
    "n": -1.5e3, "ok": true, "none": null
  },
  {"event":"c","empty":{}, "arr":[]}
]
JSON
}

write_jsonl_log() {
  mkdir -p "$(dirname "$1")"
  printf '%s\n' '{"event":"a","n":1}' '{"event":"b","msg":"café"}' > "$1"
}

# Compare the migrated file's records with the original array elements.
assert_records_equal_array() {
  python3 - "$1" "$2" <<'PY'
import json, sys
orig = json.load(open(sys.argv[1], encoding="utf-8"))
lines = [l for l in open(sys.argv[2], encoding="utf-8").read().split("\n") if l.strip()]
got = [json.loads(l) for l in lines]
assert got == orig, "records differ"
assert len(got) == len(orig)
PY
}

setup() {
  PKG="$BATS_TEST_TMPDIR/pkg"
  CONSUMER="$BATS_TEST_TMPDIR/consumer"
  LOG="$CONSUMER/project/logs/events.json"
  mkdir -p "$PKG" "$CONSUMER"
  cp -R "$REPO_ROOT/lib" "$PKG/lib"
  cp -R "$REPO_ROOT/scripts" "$PKG/scripts"
  cat > "$PKG/package.json" <<'JSON'
{ "name": "@jenga-ai/agent", "version": "3.0.0", "type": "module" }
JSON
  mkdir -p "$PKG/skills/j-do" "$PKG/agents"
  printf '# do\n' > "$PKG/skills/j-do/SKILL.md"
  printf '# developer\n' > "$PKG/agents/developer.md"
}

run_postinstall() {
  ( cd "$PKG" && INIT_CWD="${1:-$CONSUMER}" node scripts/postinstall.js ) 2>&1
}

# Drive the real runDoctor() with the isInteractive/confirmFn seam. $1 = "true" or "false".
run_doctor_with_confirmation() {
  node -e "
    import('$REPO_ROOT/lib/commands/doctor.js').then(async (m) => {
      const result = await m.runDoctor([], {
        packageRoot: '$REPO_ROOT',
        targetRoot: '$CONSUMER',
        isInteractive: true,
        confirmFn: async (q) => { console.log('PROMPT ' + q); return $1; },
      });
      console.log('SEAM_RESULT ' + JSON.stringify(result.eventLog));
    }).catch((e) => { console.error(e.stack || e.message); process.exit(1); });
  "
}

# ── helper classification ────────────────────────────────────────────────────

@test "classifyEventsLog reports missing, empty, jsonl, array and other without writing" {
  EMPTY="$BATS_TEST_TMPDIR/empty-root"; JL="$BATS_TEST_TMPDIR/jsonl-root"
  AR="$BATS_TEST_TMPDIR/array-root";    OT="$BATS_TEST_TMPDIR/other-root"
  mkdir -p "$EMPTY/project/logs" "$OT/project/logs"
  : > "$EMPTY/project/logs/events.json"
  write_jsonl_log "$JL/project/logs/events.json"
  write_array_log "$AR/project/logs/events.json"
  printf 'this is not json\n' > "$OT/project/logs/events.json"
  cp "$AR/project/logs/events.json" "$BATS_TEST_TMPDIR/array.before"

  run node -e "
    import('$REPO_ROOT/lib/events-log-repair.js').then((m) => {
      const s = (r) => m.classifyEventsLog(r);
      console.log(['$CONSUMER', '$EMPTY', '$JL', '$AR', '$OT'].map((r) => s(r).state).join(','));
      console.log(s('$AR').count + ' ' + s('$JL').count);
    });
  "
  [ "$status" -eq 0 ]
  assert_contains "$output" "missing,empty,jsonl,array,other"
  assert_contains "$output" "3 2"
  cmp "$AR/project/logs/events.json" "$BATS_TEST_TMPDIR/array.before"
  [ ! -e "$CONSUMER/project/logs/events.json" ]
}

# ── postinstall ──────────────────────────────────────────────────────────────

@test "postinstall migrates an array-shaped log to JSONL, values intact, and events-append then succeeds" {
  write_array_log "$LOG"
  cp "$LOG" "$BATS_TEST_TMPDIR/original.json"

  run run_postinstall
  [ "$status" -eq 0 ]
  assert_contains "$output" "array-shaped event log migrated to JSONL (3 entries)"

  [ "$(grep -c . "$LOG")" -eq 3 ]
  assert_records_equal_array "$BATS_TEST_TMPDIR/original.json" "$LOG"

  run bash "$REPO_ROOT/scripts/events-append.sh" --file "$LOG" '{"event":"after_repair"}'
  [ "$status" -eq 0 ]
  [ "$(grep -c . "$LOG")" -eq 4 ]
}

@test "postinstall leaves a JSONL log byte-for-byte unchanged" {
  write_jsonl_log "$LOG"
  cp "$LOG" "$BATS_TEST_TMPDIR/before"
  run run_postinstall
  [ "$status" -eq 0 ]
  assert_not_contains "$output" "event log migrated"
  cmp "$LOG" "$BATS_TEST_TMPDIR/before"
}

@test "postinstall leaves an empty log byte-for-byte unchanged" {
  mkdir -p "$(dirname "$LOG")"; : > "$LOG"
  run run_postinstall
  [ "$status" -eq 0 ]
  [ -f "$LOG" ]
  [ ! -s "$LOG" ]
}

@test "postinstall does not create a missing log" {
  run run_postinstall
  [ "$status" -eq 0 ]
  [ ! -e "$LOG" ]
  [ ! -e "$CONSUMER/project" ]
}

@test "postinstall: a log that is neither array nor JSONL is untouched, reported with its path and reason, install completes" {
  mkdir -p "$(dirname "$LOG")"
  printf '[1, 2, oops\n' > "$LOG"
  cp "$LOG" "$BATS_TEST_TMPDIR/before"
  # Starts with "[" but is not valid JSON: the helper classifies it as 'other', so the script is not run.
  run run_postinstall
  [ "$status" -eq 0 ]
  assert_contains "$output" "$LOG — not migrated: not valid JSON"
  cmp "$LOG" "$BATS_TEST_TMPDIR/before"
  [ -f "$CONSUMER/.jenga-version" ]
}

@test "postinstall: migration script exit 2 is reported with the script's message and the install completes" {
  write_array_log "$LOG"
  cp "$LOG" "$BATS_TEST_TMPDIR/before"
  printf '#!/usr/bin/env bash\necho "events-log-migrate: refused, file untouched" >&2\nexit 2\n' > "$PKG/scripts/events-log-migrate.sh"
  run run_postinstall
  [ "$status" -eq 0 ]
  assert_contains "$output" "event log migration failed (exit 2)"
  assert_contains "$output" "events-log-migrate: refused, file untouched"
  assert_contains "$output" "$LOG"
  cmp "$LOG" "$BATS_TEST_TMPDIR/before"
  [ -f "$CONSUMER/.jenga-version" ]
}

@test "postinstall: a forced verification failure (exit 3) leaves the original untouched and does not fail the install" {
  write_array_log "$LOG"
  cp "$LOG" "$BATS_TEST_TMPDIR/before"
  printf '#!/usr/bin/env bash\necho "events-log-migrate: element 0 changed value; nothing written" >&2\nexit 3\n' > "$PKG/scripts/events-log-migrate.sh"
  run run_postinstall
  [ "$status" -eq 0 ]
  assert_contains "$output" "event log migration failed (exit 3)"
  assert_contains "$output" "element 0 changed value; nothing written"
  cmp "$LOG" "$BATS_TEST_TMPDIR/before"
  [ -f "$CONSUMER/.jenga-version" ]
}

@test "postinstall: a missing migration script is reported (exit 4) and does not fail the install" {
  write_array_log "$LOG"
  cp "$LOG" "$BATS_TEST_TMPDIR/before"
  rm "$PKG/scripts/events-log-migrate.sh"
  run run_postinstall
  [ "$status" -eq 0 ]
  assert_contains "$output" "event log migration failed (exit 4)"
  cmp "$LOG" "$BATS_TEST_TMPDIR/before"
  [ -f "$CONSUMER/.jenga-version" ]
}

@test "postinstall inside the package itself still skips everything, including the log repair" {
  write_array_log "$PKG/project/logs/events.json"
  cp "$PKG/project/logs/events.json" "$BATS_TEST_TMPDIR/before"
  # postinstall's guard compares path.resolve() of INIT_CWD with the package root derived from
  # import.meta.url, which Node returns symlink-resolved. macOS tmp dirs live behind a symlink
  # (/var -> /private/var), so pass the physical path, as npm does for INIT_CWD.
  run run_postinstall "$(cd "$PKG" && pwd -P)"
  [ "$status" -eq 0 ]
  assert_contains "$output" "running inside the package itself"
  cmp "$PKG/project/logs/events.json" "$BATS_TEST_TMPDIR/before"
  [ ! -e "$PKG/.jenga-version" ]
}

# ── jenga doctor ─────────────────────────────────────────────────────────────

@test "doctor (real CLI, non-TTY stdin) lists an array log but never migrates it, even when input reads as yes" {
  write_array_log "$LOG"
  cp "$LOG" "$BATS_TEST_TMPDIR/before"
  run bash -c "cd '$CONSUMER' && echo y | node '$REPO_ROOT/bin/jenga.js' doctor"
  [ "$status" -eq 0 ]
  assert_contains "$output" "$LOG"
  assert_contains "$output" "legacy JSON array (3 element(s))"
  assert_contains "$output" "event log not migrated"
  cmp "$LOG" "$BATS_TEST_TMPDIR/before"
}

@test "doctor --dry-run lists an array log but does not migrate it" {
  write_array_log "$LOG"
  cp "$LOG" "$BATS_TEST_TMPDIR/before"
  run bash -c "cd '$CONSUMER' && node '$REPO_ROOT/bin/jenga.js' doctor --dry-run"
  [ "$status" -eq 0 ]
  assert_contains "$output" "legacy JSON array (3 element(s))"
  assert_contains "$output" "event log was not migrated"
  cmp "$LOG" "$BATS_TEST_TMPDIR/before"
}

@test "doctor declined (via test seam): array log left untouched" {
  write_array_log "$LOG"
  cp "$LOG" "$BATS_TEST_TMPDIR/before"
  run run_doctor_with_confirmation false
  [ "$status" -eq 0 ]
  assert_contains "$output" "PROMPT Migrate $LOG (3 element(s)) to JSONL?"
  assert_contains "$output" "event log was not migrated"
  assert_contains "$output" '"migrated":false'
  cmp "$LOG" "$BATS_TEST_TMPDIR/before"
}

@test "doctor confirmed (via test seam): migrates the array log, values intact, and events-append then succeeds" {
  write_array_log "$LOG"
  cp "$LOG" "$BATS_TEST_TMPDIR/original.json"
  run run_doctor_with_confirmation true
  [ "$status" -eq 0 ]
  assert_contains "$output" "migrated to JSONL (3 entries)"
  assert_contains "$output" '"migrated":true'
  [ "$(grep -c . "$LOG")" -eq 3 ]
  assert_records_equal_array "$BATS_TEST_TMPDIR/original.json" "$LOG"
  run bash "$REPO_ROOT/scripts/events-append.sh" --file "$LOG" '{"event":"after_repair"}'
  [ "$status" -eq 0 ]
}

@test "doctor: JSONL, empty and missing logs produce no finding and are never prompted or touched" {
  write_jsonl_log "$LOG"
  cp "$LOG" "$BATS_TEST_TMPDIR/before"
  run run_doctor_with_confirmation true
  [ "$status" -eq 0 ]
  assert_not_contains "$output" "PROMPT"
  assert_not_contains "$output" "Event log:"
  cmp "$LOG" "$BATS_TEST_TMPDIR/before"

  : > "$LOG"
  run run_doctor_with_confirmation true
  [ "$status" -eq 0 ]
  assert_not_contains "$output" "PROMPT"
  [ ! -s "$LOG" ]

  rm -rf "$CONSUMER/project"
  run run_doctor_with_confirmation true
  [ "$status" -eq 0 ]
  assert_not_contains "$output" "PROMPT"
  [ ! -e "$CONSUMER/project" ]
}

@test "doctor: a log that is neither array nor JSONL is reported and left untouched, never prompted" {
  mkdir -p "$(dirname "$LOG")"
  printf 'plain text\n' > "$LOG"
  cp "$LOG" "$BATS_TEST_TMPDIR/before"
  run run_doctor_with_confirmation true
  [ "$status" -eq 0 ]
  assert_contains "$output" "neither a JSON array nor JSONL"
  assert_not_contains "$output" "PROMPT"
  cmp "$LOG" "$BATS_TEST_TMPDIR/before"
}
