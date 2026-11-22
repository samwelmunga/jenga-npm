#!/usr/bin/env bats
# bats file_tags=tier:integration
#
# Coverage for scripts/test-estimate.sh, the up-front duration estimate for a selection of
# test files (E95_S02_T02). Fixture only: the timing log is a throwaway file under
# $BATS_TEST_TMPDIR passed with --timings; the real project/logs/test-timings.jsonl is never read.
#
# The subject ships, so this file ships. It names no private tooling.

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
SCRIPT="$REPO_ROOT/scripts/test-estimate.sh"

@test "E95_S02_T02: the latest file record per path wins, keyed on path; untimed files are named" {
  local log="$BATS_TEST_TMPDIR/timings.jsonl"
  # tests/a.bats: an older 90 s record, the newer 2.5 s one (different blob: path is the key),
  # and a newer non-file record that must be ignored. tests/b.bats: 4 s.
  cat > "$log" <<'EOF'
{"date":"2026-11-01T10:00:00Z","suite":"tests/a.bats","duration_ms":90000,"scope":"file","blob":"old"}
{"date":"2026-11-02T10:00:00Z","suite":"tests/a.bats","duration_ms":2500,"scope":"file","blob":"new"}
{"date":"2026-11-03T10:00:00Z","suite":"tests/a.bats","duration_ms":700000,"scope":"suite","blob":"new"}
{"date":"2026-11-01T10:00:00Z","suite":"tests/b.bats","duration_ms":4000,"scope":"file","blob":"b"}
EOF
  run bash "$SCRIPT" --timings "$log" tests/a.bats tests/b.bats tests/untimed.bats
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "estimate: 7 s for 3 file(s) (2 timed, 1 untimed); excludes 1 untimed file(s)" ]
  [ "${lines[1]}" = "untimed: tests/untimed.bats" ]
  [ "${#lines[@]}" -eq 2 ]

  run bash "$SCRIPT" --timings "$log" --json tests/a.bats tests/b.bats tests/untimed.bats
  [ "$status" -eq 0 ]
  [ "$output" = '{"files":3,"timed":2,"untimed":["tests/untimed.bats"],"estimated_seconds":7}' ]

  # no timing log at all (the public package ships none): every file untimed, still exit 0
  run bash "$SCRIPT" --timings "$BATS_TEST_TMPDIR/absent.jsonl" tests/a.bats
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "estimate: 0 s for 1 file(s) (0 timed, 1 untimed); excludes 1 untimed file(s)" ]
  [ "${lines[1]}" = "untimed: tests/a.bats" ]
}
