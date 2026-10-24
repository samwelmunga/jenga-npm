#!/usr/bin/env bats
#
# Coverage for scripts/events-append.sh (E75_S01_T03).
# Every case targets a scratch file under BATS_TEST_TMPDIR via --file; the real project/logs/events.json is never touched.

setup() {
  SCRIPT="$BATS_TEST_DIRNAME/../scripts/events-append.sh"
  F="$BATS_TEST_TMPDIR/events.json"
}

sum() { shasum -a 256 "$1" | cut -d' ' -f1; }

@test "appends one compact line" {
  run bash "$SCRIPT" --file "$F" '{ "event": "a",
    "n": 1 }'
  [ "$status" -eq 0 ]
  [ "$(wc -l < "$F" | tr -d ' ')" = 1 ]
  [ "$(cat "$F")" = '{"event":"a","n":1}' ]
}

@test "accepts the record on stdin" {
  run bash -c "printf '%s' '{\"event\":\"b\"}' | bash '$SCRIPT' --file '$F'"
  [ "$status" -eq 0 ]
  [ "$(cat "$F")" = '{"event":"b"}' ]
}

@test "create-if-absent in a missing directory" {
  run bash "$SCRIPT" --file "$BATS_TEST_TMPDIR/sub/dir/e.json" '{"event":"c"}'
  [ "$status" -eq 0 ]
  [ -s "$BATS_TEST_TMPDIR/sub/dir/e.json" ]
}

@test "20 concurrent appends: none lost, every line parses" {
  for i in $(seq 1 20); do
    bash "$SCRIPT" --file "$F" "{\"event\":\"c\",\"i\":$i}" &
  done
  wait
  [ "$(wc -l < "$F" | tr -d ' ')" = 20 ]
  run jq -s -e 'map(.i) | sort == [range(1;21)]' "$F"
  [ "$status" -eq 0 ]
}

@test "refuses an array-shaped target and leaves it unchanged" {
  printf '[\n  {"event":"x"}\n]\n' > "$F"
  before=$(sum "$F")
  run bash "$SCRIPT" --file "$F" '{"event":"n"}'
  [ "$status" -eq 4 ]
  [ "$(sum "$F")" = "$before" ]
}

@test "refuses a target holding a non-object line" {
  printf '{"event":"x"}\nnot json\n' > "$F"
  before=$(sum "$F")
  run bash "$SCRIPT" --file "$F" '{"event":"n"}'
  [ "$status" -eq 4 ]
  [ "$(sum "$F")" = "$before" ]
}

@test "refuses malformed, non-object and multi-value records without writing" {
  printf '{"event":"x"}\n' > "$F"
  before=$(sum "$F")
  for rec in '{"event":' '[1,2]' '"str"' '42' '{"a":1} {"b":2}' ''; do
    run bash "$SCRIPT" --file "$F" "$rec"
    [ "$status" -ne 0 ]
    [ "$(sum "$F")" = "$before" ]
  done
}

@test "malformed record does not create an absent target" {
  run bash "$SCRIPT" --file "$F" 'nope'
  [ "$status" -ne 0 ]
  [ ! -e "$F" ]
}

@test "never truncates: earlier bytes identical, escapes kept, ASCII-escapes the new record" {
  printf '{"event":"x","t":"caf\\u00e9"}\n{"event":"y"}\n' > "$F"
  cp "$F" "$BATS_TEST_TMPDIR/orig"
  n=$(wc -c < "$F" | tr -d ' ')
  run bash "$SCRIPT" --file "$F" '{"event":"z","t":"café"}'
  [ "$status" -eq 0 ]
  head -c "$n" "$F" | cmp - "$BATS_TEST_TMPDIR/orig"
  bs=$(printf '\\')
  want="{\"event\":\"z\",\"t\":\"caf${bs}u00e9\"}"
  [ "$(tail -n 1 "$F")" = "$want" ]
}

@test "adds a missing trailing newline before the new record" {
  printf '{"event":"x"}' > "$F"
  run bash "$SCRIPT" --file "$F" '{"event":"y"}'
  [ "$status" -eq 0 ]
  [ "$(wc -l < "$F" | tr -d ' ')" = 2 ]
  run jq -s -e 'length == 2' "$F"
  [ "$status" -eq 0 ]
}
