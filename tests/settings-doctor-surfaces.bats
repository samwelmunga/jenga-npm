#!/usr/bin/env bats
# bats file_tags=tier:integration
#
# E100_S05_T06: the two surfaces of the settings doctor (E100_S05_T01): the j.status "Settings requirements" step 6.85
# (skills/j-status/SKILL.md, E100_S05_T04) and the skill-start notice scripts/settings-doctor-once.sh (E100_S05_T05).
#
# Fixture and demonstrated result (the story's "demonstrated on a fixture with a missing hook" proof):
#   tests/fixtures/settings-doctor-surfaces/missing  .claude/settings.json without the recorder hook
#   tests/fixtures/settings-doctor-surfaces/present  .claude/settings.json holding the recorder hook from the shipped fragment
# On `missing`, the j.status command lists workflow-recorder hooks.UserPromptSubmit[0] as inactive with "npx jenga sync" and
# the restart note, and the skill-start notice prints once then nothing; on `present` the same calls report all active.
# j.status is instruction text, so the test pins the script command and its exit status and output, never the model's wording.
#
# Isolation: a fixture package under $BATS_TEST_TMPDIR holds the doctor, the once script and the real recorder fragment;
# --project-dir/--home point at $BATS_TEST_TMPDIR; TMPDIR and CLAUDE_SESSION_ID isolate the once markers. Paths are
# canonicalised with pwd -P (macOS /var is a symlink). Written without being executed by its author; the tester runs it.

load helpers/assertions

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd -P)"
FIXTURES="$REPO_ROOT/tests/fixtures/settings-doctor-surfaces"

setup() {
  PKG="$BATS_TEST_TMPDIR/pkg"; PROJ="$BATS_TEST_TMPDIR/proj"; HOMED="$BATS_TEST_TMPDIR/home"; TMPD="$BATS_TEST_TMPDIR/tmp"
  mkdir -p "$PKG/scripts" "$PKG/skills/index/scripts" "$PKG/skills/j-workflow-recorder" "$HOMED/.claude" "$TMPD" "$PROJ"
  cp "$REPO_ROOT/scripts/settings-doctor.sh" "$REPO_ROOT/scripts/settings-doctor-once.sh" "$PKG/scripts/"
  cp "$REPO_ROOT/skills/index/scripts/package-root.sh" "$PKG/skills/index/scripts/package-root.sh"
  : > "$PKG/scripts/resolve-root.sh"
  cp "$REPO_ROOT/skills/j-workflow-recorder/settings-fragment.json" "$PKG/skills/j-workflow-recorder/"
  PKG="$(cd "$PKG" && pwd -P)"; PROJ="$(cd "$PROJ" && pwd -P)"; HOMED="$(cd "$HOMED" && pwd -P)"; TMPD="$(cd "$TMPD" && pwd -P)"
  export TMPDIR="$TMPD" CLAUDE_SESSION_ID="surfaces-$BATS_TEST_NUMBER"
}

use_fixture() { cp -R "$FIXTURES/$1/." "$PROJ/"; }
doctor() { bash "$PKG/scripts/settings-doctor.sh" --project-dir "$PROJ" --home "$HOMED" "$@"; }
once() { bash "$PKG/scripts/settings-doctor-once.sh" j-workflow-recorder --project-dir "$PROJ" --home "$HOMED"; }
settings_hash() { find "$PROJ" "$HOMED" -type f | LC_ALL=C sort | while IFS= read -r f; do shasum "$f"; done; }

@test "j.status step 6.85, missing hook: --quiet exits 1 and lists the requirement inactive with the fix" {
  use_fixture missing
  run doctor --quiet
  [ "$status" -eq 1 ]
  assert_output_contains "workflow-recorder: hooks.UserPromptSubmit[0]: inactive"
  assert_output_contains "  fix: run: npx jenga sync"
  assert_output_contains "restart Claude Code"
}

@test "j.status step 6.85, present hook: --quiet exits 0 and prints nothing; the full run gives one active line" {
  use_fixture present
  run doctor --quiet
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  run doctor
  [ "$status" -eq 0 ]
  assert_output_contains "workflow-recorder: hooks.UserPromptSubmit[0]: active ($PROJ/.claude/settings.json)"
  [ "$(printf '%s\n' "$output" | grep -c ': active')" -eq 1 ]
}

@test "skill-start notice, missing hook: printed once, then nothing; exit 0 both times" {
  use_fixture missing
  run once
  [ "$status" -eq 0 ]
  assert_output_contains "Settings notice (j-workflow-recorder)"
  assert_output_contains "inactive"
  assert_output_contains "npx jenga sync"
  run once
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "skill-start notice, present hook: silent, exit 0" {
  use_fixture present
  run once
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "the preflight never blocks: an unreadable settings file exits 0" {
  use_fixture missing
  chmod 000 "$PROJ/.claude/settings.json"
  run once
  chmod 600 "$PROJ/.claude/settings.json"
  [ "$status" -eq 0 ]
}

@test "the preflight never blocks: an invalid settings file exits 0" {
  use_fixture missing
  printf '%s' '{ not json' > "$PROJ/.claude/settings.json"
  run once
  [ "$status" -eq 0 ]
}

@test "neither surface changes a settings file (hash compare, missing and present)" {
  local fx
  for fx in missing present; do
    rm -rf "$PROJ"; mkdir -p "$PROJ"; rm -f "$TMPD"/jenga-settings-once-*
    use_fixture "$fx"
    before="$(settings_hash)"
    run doctor --quiet; run doctor; run once; run once
    after="$(settings_hash)"
    [ "$before" = "$after" ]
  done
}
