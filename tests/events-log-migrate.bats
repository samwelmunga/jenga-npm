#!/usr/bin/env bats
#
# Coverage for scripts/events-log-migrate.sh (E75_S01_T02): the one-off conversion of the shared event
# log from a JSON array to JSONL, which is also the recovery path for in-flight branches.
#
# Every test works on a scratch copy under $BATS_TEST_TMPDIR. The real project/logs/events.json is never
# read or written. The fixture is deliberately awkward: \uXXXX escapes, raw non-ASCII text, nested
# objects and arrays, strings that contain the array's own punctuation, and irregular indentation.

load helpers/assertions

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
MIGRATE="$REPO_ROOT/scripts/events-log-migrate.sh"

setup() {
  F="$BATS_TEST_TMPDIR/events.json"
  ORIG="$BATS_TEST_TMPDIR/original.json"
  cat > "$F" <<'JSON'
[
    {"event":"a","msg":"café and café","nested":{"k":[1,2,{"x":"[b], c]"}]}},
  {
     "event" : "b",
     "text": "line\nbreak \"quoted\" \\ back",
     "n": -1.5e3,
     "ok": true, "none": null
  },
  {"event":"c","empty":{}, "arr":[]}
]
JSON
  cp "$F" "$ORIG"
}

@test "converts a JSON array into JSONL with one record per line" {
  run bash "$MIGRATE" "$F"
  [ "$status" -eq 0 ]
  [ "$(wc -l < "$F" | tr -d ' ')" -eq 3 ]
  # No line is an array bracket or a separator: every line starts with the record's own "{".
  [ "$(grep -c '^[][, ]' "$F" || true)" -eq 0 ]
  [ ! -e "$F.lock.d" ]
}

@test "every record keeps its value: the migrated file slurps to the original array" {
  run bash "$MIGRATE" "$F"
  [ "$status" -eq 0 ]
  local before after
  before="$(jq -S -c . "$ORIG")"
  after="$(jq -S -s -c . "$F")"
  [ "$before" = "$after" ]
}

@test "string literals are kept byte-for-byte: escapes, raw non-ASCII and punctuation inside strings" {
  run bash "$MIGRATE" "$F"
  [ "$status" -eq 0 ]
  grep -F 'café and café' "$F" > /dev/null
  grep -F '"x":"[b], c]"' "$F" > /dev/null
  grep -F '"text": "line\nbreak \"quoted\" \\ back"' "$F" > /dev/null
  grep -F '"n": -1.5e3' "$F" > /dev/null
}

@test "idempotent: migrating an already-migrated file changes nothing" {
  run bash "$MIGRATE" "$F"
  [ "$status" -eq 0 ]
  local once="$BATS_TEST_TMPDIR/once.jsonl"
  cp "$F" "$once"
  run bash "$MIGRATE" "$F"
  [ "$status" -eq 0 ]
  assert_output_contains "already JSONL"
  cmp -s "$F" "$once"
}

@test "a truncated array is refused with exit 2 and the file is left untouched" {
  printf '[{"event":"a"},{"event":"b"}\n' > "$F"
  local before
  before="$(cksum < "$F")"
  run bash "$MIGRATE" "$F"
  [ "$status" -eq 2 ]
  assert_output_contains "refused, file untouched"
  [ "$(cksum < "$F")" = "$before" ]
  [ ! -e "$F.lock.d" ]
}

@test "content that is neither a JSON array nor JSONL is refused with exit 2 and left untouched" {
  printf 'not json at all\n{"event":"a"}\n' > "$F"
  local before
  before="$(cksum < "$F")"
  run bash "$MIGRATE" "$F"
  [ "$status" -eq 2 ]
  assert_output_contains "neither a JSON array nor JSONL"
  [ "$(cksum < "$F")" = "$before" ]
}

@test "a missing argument is a usage error (exit 1)" {
  run bash "$MIGRATE"
  [ "$status" -eq 1 ]
  assert_output_contains "Usage"
}
