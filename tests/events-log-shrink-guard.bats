#!/usr/bin/env bats
#
# Coverage for scripts/check-events-log-shrink.sh (E75_S01_T03). Builds scratch git repos; never touches this repo's log.

setup() {
  GUARD="$BATS_TEST_DIRNAME/../scripts/check-events-log-shrink.sh"
  R="$BATS_TEST_TMPDIR/repo"
  mkdir -p "$R/project/logs"
  git -C "$R" init -q
  git -C "$R" config user.email t@example.com
  git -C "$R" config user.name t
  printf '{"event":"a"}\n{"event":"b"}\n{"event":"c"}\n' > "$R/project/logs/events.json"
  git -C "$R" add -A
  git -C "$R" commit -q -m init
}

run_guard() { (cd "$R" && bash "$GUARD" "$@"); }

@test "passes when unchanged" {
  run run_guard
  [ "$status" -eq 0 ]
}

@test "passes on a pure append" {
  printf '{"event":"d"}\n' >> "$R/project/logs/events.json"
  run run_guard
  [ "$status" -eq 0 ]
}

@test "fails when the log shrinks" {
  printf '{"event":"a"}\n' > "$R/project/logs/events.json"
  run run_guard
  [ "$status" -eq 1 ]
  [[ "$output" == *shrank* ]]
}

@test "fails when replaced by an array with more lines" {
  printf '[\n{"event":"a"},\n{"event":"b"},\n{"event":"c"},\n{"event":"d"}\n]\n' > "$R/project/logs/events.json"
  run run_guard
  [ "$status" -eq 1 ]
}

@test "fails when an existing line is rewritten at the same length" {
  printf '{"event":"a"}\n{"event":"X"}\n{"event":"c"}\n' > "$R/project/logs/events.json"
  run run_guard
  [ "$status" -eq 1 ]
}

@test "fails when the file is deleted" {
  rm "$R/project/logs/events.json"
  run run_guard
  [ "$status" -eq 1 ]
}

@test "--staged checks the index, not the working tree" {
  printf '{"event":"a"}\n' > "$R/project/logs/events.json"
  git -C "$R" add -A
  printf '{"event":"a"}\n{"event":"b"}\n{"event":"c"}\n{"event":"d"}\n' > "$R/project/logs/events.json"
  run run_guard --staged
  [ "$status" -eq 1 ]
  run run_guard
  [ "$status" -eq 0 ]
}

@test "passes when HEAD has no version of the file" {
  git -C "$R" rm -q --cached project/logs/events.json
  git -C "$R" commit -q -m drop
  run run_guard
  [ "$status" -eq 0 ]
}
