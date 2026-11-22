#!/usr/bin/env bats
# bats file_tags=tier:unit
#
# E100_S03_T11, narrowed by E100_S04_T01: scripts/jenga-permission-level-switch.sh
# prints a hint to run `npx jenga sync` only for a settings file that lacks the
# pre-flight PreToolUse registration, and never after a failed switch.

load helpers/assertions

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
SWITCH="$REPO_ROOT/scripts/jenga-permission-level-switch.sh"

setup() {
  SANDBOX="$(mktemp -d)"
  git init -q "$SANDBOX"
}

teardown() {
  rm -rf "$SANDBOX"
}

@test "switch onto settings lacking the pre-flight hook names the file and npx jenga sync on stderr" {
  run bash -c 'cd "$1" && bash "$2" 3 2>&1 >/dev/null' _ "$SANDBOX" "$SWITCH"
  [ "$status" -eq 0 ]
  assert_output_contains ".claude/settings.json"
  assert_output_contains ".agents/settings.json"
  assert_output_contains "npx jenga sync"
}

@test "switch onto settings that register the pre-flight hook prints no hint" {
  mkdir -p "$SANDBOX/.claude" "$SANDBOX/.agents"
  for d in .claude .agents; do
    echo '{"hooks":{"PreToolUse":[{"hooks":[{"type":"command","command":"exec hooks/on_preflight_check.sh"}]}]}}' > "$SANDBOX/$d/settings.json"
  done
  run bash -c 'cd "$1" && bash "$2" 3 2>&1' _ "$SANDBOX" "$SWITCH"
  [ "$status" -eq 0 ]
  assert_output_contains "Switched to level 3 (standard)."
  [[ "$output" != *"npx jenga sync"* ]] || false
}

@test "invalid-argument switch prints no hint" {
  run bash -c 'cd "$1" && bash "$2" 9 2>&1' _ "$SANDBOX" "$SWITCH"
  [ "$status" -eq 1 ]
  [[ "$output" != *"npx jenga sync"* ]] || false
}

@test "missing-argument switch prints no hint" {
  run bash -c 'cd "$1" && bash "$2" 2>&1' _ "$SANDBOX" "$SWITCH"
  [ "$status" -eq 1 ]
  [[ "$output" != *"npx jenga sync"* ]] || false
}
