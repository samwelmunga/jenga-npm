#!/usr/bin/env bats
#
# Coverage for skills/j-test/scripts/record-timing.sh, the one writer of the test-timing
# log (E77_S06_T03), written by E77_S06_T08.
#
# Fixture only: every log is a throwaway file under $BATS_TEST_TMPDIR, always passed
# with --log. The real project/logs/test-timings.jsonl is never read or written.
#
# The subject ships, so this file ships. It names no private tooling.

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
SCRIPT="$REPO_ROOT/skills/j-test/scripts/record-timing.sh"

setup() {
  LOG="$BATS_TEST_TMPDIR/logs/test-timings.jsonl"
  mkdir -p "$BATS_TEST_TMPDIR/logs"
}

# good_args: the arguments of one valid record, one per line, so a case can swap one.
record() {
  bash "$SCRIPT" --suite tests/example.bats --tests 5 --passed 4 --failed 1 --duration-ms 1234 \
    --caller timing-test --status failed --commit abc1234 --blob def5678abc --log "$LOG" "$@"
}

@test "E77_S06_T03: one call appends exactly one valid JSON line with all thirteen keys" {
  run record
  [ "$status" -eq 0 ]
  [ "$(wc -l < "$LOG" | tr -d ' ')" = "1" ]
  run jq -e -c '. as $r | ["date","suite","tests","passed","failed","duration_ms","scope","caller","status","commit","blob","load_1m","cpu_ms"] | all(. as $k | $r | has($k))' "$LOG"
  [ "$status" -eq 0 ]
  [ "$(jq -r 'keys_unsorted | length' "$LOG")" = "13" ]
}

@test "E77_S06_T03: the keys come in the documented order with the supplied values" {
  run record
  [ "$status" -eq 0 ]
  [ "$(jq -r 'keys_unsorted | join(",")' "$LOG")" = "date,suite,tests,passed,failed,duration_ms,scope,caller,status,commit,blob,load_1m,cpu_ms" ]
  [ "$(jq -r '.suite' "$LOG")" = "tests/example.bats" ]
  [ "$(jq -r '.tests' "$LOG")" = "5" ]
  [ "$(jq -r '.passed' "$LOG")" = "4" ]
  [ "$(jq -r '.failed' "$LOG")" = "1" ]
  [ "$(jq -r '.duration_ms' "$LOG")" = "1234" ]
  [ "$(jq -r '.scope' "$LOG")" = "file" ]
  [ "$(jq -r '.caller' "$LOG")" = "timing-test" ]
  [ "$(jq -r '.status' "$LOG")" = "failed" ]
  [ "$(jq -r '.commit' "$LOG")" = "abc1234" ]
  [ "$(jq -r '.blob' "$LOG")" = "def5678abc" ]
}

@test "E77_S06_T03: the date is a UTC ISO 8601 stamp and load_1m is null when not supplied" {
  run record
  [ "$status" -eq 0 ]
  date_value="$(jq -r '.date' "$LOG")"
  case "$date_value" in
    [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]Z) ;;
    *) echo "bad date: $date_value"; return 1 ;;
  esac
  [ "$(jq -c '.load_1m' "$LOG")" = "null" ]
}

@test "E77_S06_T03: --load-1m is stored as a JSON number, and the word null is the same as omitting it" {
  run record --load-1m 3.42
  [ "$status" -eq 0 ]
  run record --load-1m null
  [ "$status" -eq 0 ]
  [ "$(sed -n 1p "$LOG" | jq -c '.load_1m')" = "3.42" ]
  [ "$(sed -n 2p "$LOG" | jq -c '.load_1m')" = "null" ]
}

@test "E77_S06_T11: --cpu-ms is stored as a JSON integer, and null or omitting it gives null" {
  run record --cpu-ms 61832
  [ "$status" -eq 0 ]
  run record --cpu-ms null
  [ "$status" -eq 0 ]
  run record
  [ "$status" -eq 0 ]
  [ "$(sed -n 1p "$LOG" | jq -c '.cpu_ms')" = "61832" ]
  [ "$(sed -n 2p "$LOG" | jq -c '.cpu_ms')" = "null" ]
  [ "$(sed -n 3p "$LOG" | jq -c '.cpu_ms')" = "null" ]
}

@test "E77_S06_T11: a bad --cpu-ms is refused with exit 2 and nothing is written" {
  for v in -1 1.5 abc "" 1234567890123456; do
    run record --cpu-ms "$v"
    [ "$status" -eq 2 ]
  done
  [ ! -s "$LOG" ]
}

@test "E77_S06_T03: successive calls append, one line each, and never rewrite earlier lines" {
  run record
  [ "$status" -eq 0 ]
  first="$(sed -n 1p "$LOG")"
  run record --status timeout
  [ "$status" -eq 0 ]
  [ "$(wc -l < "$LOG" | tr -d ' ')" = "2" ]
  [ "$(sed -n 1p "$LOG")" = "$first" ]
  [ "$(sed -n 2p "$LOG" | jq -r '.status')" = "timeout" ]
}

@test "E77_S06_T03: a negative duration exits 2 and leaves the log unchanged" {
  run record
  [ "$status" -eq 0 ]
  before="$(cksum < "$LOG")"
  run bash "$SCRIPT" --suite tests/example.bats --tests 5 --passed 4 --failed 1 --duration-ms -1 \
    --caller c --status passed --commit abc1234 --blob def5678abc --log "$LOG"
  [ "$status" -eq 2 ]
  [ "$before" = "$(cksum < "$LOG")" ]
}

@test "E77_S06_T03: an unknown --status exits 2 and creates no log" {
  run bash "$SCRIPT" --suite tests/example.bats --tests 1 --passed 1 --failed 0 --duration-ms 10 \
    --caller c --status flaky --commit abc1234 --blob def5678abc --log "$LOG"
  [ "$status" -eq 2 ]
  [ ! -e "$LOG" ]
}

@test "E77_S06_T03: each bad field is refused with exit 2 and nothing is written" {
  local base=(--suite tests/x.bats --tests 2 --passed 1 --failed 1 --duration-ms 5 --caller c --status passed --commit abc1234 --blob def5678abc)
  run bash "$SCRIPT" "${base[@]}" --log "$LOG" --tests abc
  [ "$status" -eq 2 ]
  run bash "$SCRIPT" "${base[@]}" --log "$LOG" --passed 2 --failed 1
  [ "$status" -eq 2 ]
  run bash "$SCRIPT" "${base[@]}" --log "$LOG" --suite /abs/path.bats
  [ "$status" -eq 2 ]
  run bash "$SCRIPT" "${base[@]}" --log "$LOG" --commit XYZ
  [ "$status" -eq 2 ]
  run bash "$SCRIPT" "${base[@]}" --log "$LOG" --blob abc
  [ "$status" -eq 2 ]
  run bash "$SCRIPT" "${base[@]}" --log "$LOG" --load-1m -3
  [ "$status" -eq 2 ]
  run bash "$SCRIPT" "${base[@]}" --log "$LOG" --caller ""
  [ "$status" -eq 2 ]
  [ ! -e "$LOG" ]
}

@test "E77_S06_T03: a missing required field and an unknown option both exit 2" {
  run bash "$SCRIPT" --suite tests/x.bats --log "$LOG"
  [ "$status" -eq 2 ]
  run bash "$SCRIPT" --bogus --log "$LOG"
  [ "$status" -eq 2 ]
  [ ! -e "$LOG" ]
}

@test "E77_S06_T03: two concurrent calls leave two intact JSON lines" {
  record --suite tests/one.bats > /dev/null 2>&1 &
  pid_one=$!
  record --suite tests/two.bats > /dev/null 2>&1 &
  pid_two=$!
  wait "$pid_one"
  wait "$pid_two"
  [ "$(wc -l < "$LOG" | tr -d ' ')" = "2" ]
  [ "$(jq -c '.suite' "$LOG" | sort | tr '\n' ' ')" = '"tests/one.bats" "tests/two.bats" ' ]
}

@test "E77_S06_T03: a log that is not JSONL is refused with exit 4 and left byte-identical" {
  printf '%s\n' '[1,2,3]' > "$LOG"
  before="$(cksum < "$LOG")"
  run record
  [ "$status" -eq 4 ]
  [ "$before" = "$(cksum < "$LOG")" ]
}

@test "E77_S06_T03: it writes nothing outside --log" {
  mkdir -p "$BATS_TEST_TMPDIR/sandbox"
  cd "$BATS_TEST_TMPDIR/sandbox"
  run record
  [ "$status" -eq 0 ]
  run find "$BATS_TEST_TMPDIR" -type f -newer "$SCRIPT"
  # the only regular file created under the fixture tree is the log itself
  [ "$(printf '%s\n' "$output" | grep -c .)" = "1" ]
  case "$output" in
    *"/logs/test-timings.jsonl") ;;
    *) echo "unexpected files: $output"; return 1 ;;
  esac
}

@test "E77_S06_T03: the script carries no reference to the private mirror tooling" {
  needle="mirror""-public"   # split so this shipped file never carries the private skill name
  run grep -n "$needle" "$SCRIPT"
  [ "$status" -ne 0 ]
}

@test "E77_S06_T03: --help prints the contract and exits 0" {
  run bash "$SCRIPT" --help
  [ "$status" -eq 0 ]
  case "$output" in
    *duration_ms*) ;;
    *) echo "help lacks the record shape"; return 1 ;;
  esac
}
