#!/usr/bin/env bats
#
# check-story-closeable.sh must treat every terminal task status as closeable.
# Regression: "Passed with remarks" (documented as terminal in
# templates/SCRUM_BOARD_SCHEMA.md and agents/tester.md) was rejected as OPEN
# because the guard only matched `Passed|Done` literally.
load helpers/assertions

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
SCRIPT="$REPO_ROOT/skills/j-close-story/scripts/check-story-closeable.sh"

setup() {
  FIXTURE_REPO="$BATS_TEST_TMPDIR/fixture-repo"
  mkdir -p "$FIXTURE_REPO/project/board/stories" "$FIXTURE_REPO/project/board/tasks"
  git -C "$FIXTURE_REPO" init -q

  mkdir -p "$FIXTURE_REPO/skills/j-close-story/scripts"
  cp "$SCRIPT" "$FIXTURE_REPO/skills/j-close-story/scripts/check-story-closeable.sh"

  cat > "$FIXTURE_REPO/project/board/stories/E99_S01_sample-story.md" <<'EOF'
---
id: E99_S01
status: In Progress
tasks:
  - E99_S01_T01
---

# Sample story
EOF
}

write_task_status() {
  cat > "$FIXTURE_REPO/project/board/tasks/E99_S01_T01_sample-task.md" <<EOF
---
id: E99_S01_T01
status: $1
---

# Sample task
EOF
}

run_guard() {
  run bash "$FIXTURE_REPO/skills/j-close-story/scripts/check-story-closeable.sh" E99_S01
}

@test "Passed is closeable" {
  write_task_status "Passed"
  run_guard
  [ "$status" -eq 0 ]
  assert_output_contains "CLOSEABLE"
}

@test "Done is closeable" {
  write_task_status "Done"
  run_guard
  [ "$status" -eq 0 ]
  assert_output_contains "CLOSEABLE"
}

@test "Passed with remarks is closeable (unquoted)" {
  write_task_status "Passed with remarks"
  run_guard
  [ "$status" -eq 0 ]
  assert_output_contains "CLOSEABLE"
}

@test "Passed with remarks is closeable (quoted)" {
  write_task_status '"Passed with remarks"'
  run_guard
  [ "$status" -eq 0 ]
  assert_output_contains "CLOSEABLE"
}

@test "In Progress is still OPEN" {
  write_task_status "In Progress"
  run_guard
  [ "$status" -eq 1 ]
  assert_output_contains "OPEN"
}

# --- bash 3.2 portability (regression guard) --------------------------------
# `mapfile -t TASK_IDS` made this guard bash 4+ only: on stock macOS bash 3.2 it
# died with "mapfile: command not found" and, under `set -e`, exited 127 before
# a single task status was read.

@test "bash 3.2 compatibility: no mapfile, associative arrays or case-modifying expansions" {
  local code
  code="$(grep -v '^[[:space:]]*#' "$SCRIPT")"
  run grep -E 'mapfile|readarray|declare -A|local -A|\$\{[A-Za-z_]+(,,|\^\^)|\[\[ -v' <<<"$code"
  [ "$status" -eq 1 ]
}

@test "a terminal status is still CLOSEABLE under a pre-4 bash" {
  local old=""
  for c in /bin/bash /usr/bin/bash; do
    [ -x "$c" ] || continue
    case "$("$c" -c 'echo ${BASH_VERSINFO[0]}')" in 1|2|3) old="$c"; break ;; esac
  done
  [ -n "$old" ] || skip "no bash older than 4 available on this host"

  write_task_status "Passed with remarks"
  run "$old" "$FIXTURE_REPO/skills/j-close-story/scripts/check-story-closeable.sh" E99_S01
  [ "$status" -eq 0 ]
  assert_output_contains "CLOSEABLE"
}

@test "an open status is still OPEN under a pre-4 bash (no false CLOSEABLE, no 127)" {
  local old=""
  for c in /bin/bash /usr/bin/bash; do
    [ -x "$c" ] || continue
    case "$("$c" -c 'echo ${BASH_VERSINFO[0]}')" in 1|2|3) old="$c"; break ;; esac
  done
  [ -n "$old" ] || skip "no bash older than 4 available on this host"

  write_task_status "In Progress"
  run "$old" "$FIXTURE_REPO/skills/j-close-story/scripts/check-story-closeable.sh" E99_S01
  [ "$status" -eq 1 ]
  assert_output_not_contains "mapfile"
}
