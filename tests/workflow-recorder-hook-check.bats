#!/usr/bin/env bats
# bats file_tags=tier:integration
#
# skills/j-workflow-recorder/scripts/check-recorder-hook.sh (E89_S06_T20).
#
# `j.workflow-recorder start` runs this first so a missing UserPromptSubmit hook is announced instead of the recording
# silently capturing nothing. Pinned: registered in a project file, missing everywhere, registered only in the
# user-level ~/.claude/settings.json (counts: Claude Code reads it), and "present" only in files Claude Code does not
# read for hooks in a consumer (.agents/settings.json, the repository-root settings.json), which must NOT count.
# Isolation: --project-dir and --home point at $BATS_TEST_TMPDIR, so the real ~/.claude is never read.

load helpers/assertions

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
SCRIPT="$REPO_ROOT/skills/j-workflow-recorder/scripts/check-recorder-hook.sh"

HOOK_JSON='{"hooks":{"UserPromptSubmit":[{"matcher":"","hooks":[{"type":"command","command":"exec \"$P/hooks/on_recording_step.sh\""}]}]}}'
OTHER_JSON='{"hooks":{"SessionEnd":[{"hooks":[{"type":"command","command":"on_session_end.sh"}]}],"UserPromptSubmit":[{"hooks":[{"type":"command","command":"echo mine"}]}]}}'

setup() {
  PROJ="$BATS_TEST_TMPDIR/proj"; HOMED="$BATS_TEST_TMPDIR/home"
  mkdir -p "$PROJ/.claude" "$PROJ/.agents" "$HOMED/.claude"
}

check() { bash "$SCRIPT" --project-dir "$PROJ" --home "$HOMED"; }

@test "registered in .claude/settings.json" {
  printf '%s' "$HOOK_JSON" > "$PROJ/.claude/settings.json"
  run check
  [ "$status" -eq 0 ]
  assert_output_contains "registered: $PROJ/.claude/settings.json"
}

@test "registered in .claude/settings.local.json" {
  printf '%s' "$OTHER_JSON" > "$PROJ/.claude/settings.json"
  printf '%s' "$HOOK_JSON" > "$PROJ/.claude/settings.local.json"
  run check
  [ "$status" -eq 0 ]
  assert_output_contains "settings.local.json"
}

@test "missing: pre-E89 settings with another UserPromptSubmit hook is plain about it and gives the fix" {
  printf '%s' "$OTHER_JSON" > "$PROJ/.claude/settings.json"
  run check
  [ "$status" -eq 1 ]
  assert_output_contains "not registered"
  assert_output_contains "capture nothing"
  assert_output_contains "npx jenga sync"
  assert_output_contains "restart"
  assert_output_contains "pointer"
}

@test "missing: no settings files at all" {
  run check
  [ "$status" -eq 1 ]
  assert_output_contains "not registered"
}

@test "registered only in the user-level ~/.claude/settings.json counts" {
  printf '%s' "$HOOK_JSON" > "$HOMED/.claude/settings.json"
  run check
  [ "$status" -eq 0 ]
  assert_output_contains "registered: $HOMED/.claude/settings.json"
}

@test "registered only in files Claude Code does not read for a consumer does not count" {
  printf '%s' "$HOOK_JSON" > "$PROJ/.agents/settings.json"
  printf '%s' "$HOOK_JSON" > "$PROJ/settings.json"
  run check
  [ "$status" -eq 1 ]
  assert_output_contains "not registered"
}

@test "an invalid settings file is treated as not registering the hook" {
  printf '{ nope' > "$PROJ/.claude/settings.json"
  run check
  [ "$status" -eq 1 ]
}

@test "SKILL.md start runs the check before choosing the name" {
  run grep -n "check-recorder-hook.sh" "$REPO_ROOT/skills/j-workflow-recorder/SKILL.md"
  [ "$status" -eq 0 ]
}
