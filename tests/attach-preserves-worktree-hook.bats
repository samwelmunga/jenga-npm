#!/usr/bin/env bats
#
# Regression coverage for E15_S04_T01.
#
# Why this file exists
# ---------------------
# During verification of E28_S07, `jenga attach` was observed alongside a
# clobbered WorktreeCreate hook in .claude/settings.json (the
# install-worktree-commit-guard.sh invocation had vanished). Investigation for
# this task found that the CURRENT lib/commands/attach.js (as of commit
# 619198b) already round-trips the existing settings.json object -- it reads
# whatever is on disk, merges only settings.mcpServers.jenga, and writes the
# full object back -- rather than overwriting from a template or stale copy.
# That should make it non-destructive to any existing hook today. This suite
# locks that finding in as a regression test rather than leaving it as an
# unverified read of the source.
#
# lib/commands/attach.js only ever touches .claude/settings.json (the
# .agents/settings.json dual-write was removed from this file in 619198b) --
# this suite covers exactly what the file does, not a wider contract.

load helpers/assertions

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
JENGA_BIN="$REPO_ROOT/bin/jenga.js"

# The exact commit-guard-inclusive WorktreeCreate hook this repo's own root
# settings.json ships, reused here as the fixture's "before" state so the
# test exercises the real, current hook shape rather than a hand-simplified
# stand-in.
GUARD_INVOCATION="install-worktree-commit-guard.sh"

setup() {
  FIXTURE_DIR="$BATS_TEST_TMPDIR/consumer"
  mkdir -p "$FIXTURE_DIR/.claude"
  # Minimal jenga.cli.json -- runAttach only checks for its existence.
  printf '{}\n' > "$FIXTURE_DIR/jenga.cli.json"

  WORKTREE_CREATE_CMD="$(jq -r '.hooks.WorktreeCreate[0].hooks[0].command' "$REPO_ROOT/settings.json")"

  jq -n --arg cmd "$WORKTREE_CREATE_CMD" '{
    hooks: {
      WorktreeCreate: [
        { hooks: [ { type: "command", command: $cmd } ] }
      ],
      WorktreeRemove: [
        { hooks: [ { type: "command", command: "\"$(git rev-parse --show-toplevel)/scripts/worktree-remove-guard.sh\"\n" } ] }
      ],
      SessionEnd: [
        { hooks: [ { type: "command", async: true, command: "on_session_end.sh" } ] }
      ]
    }
  }' > "$FIXTURE_DIR/.claude/settings.json"
}

@test "fixture settings.json contains the commit-guard invocation before attach runs" {
  run jq -r '.hooks.WorktreeCreate[0].hooks[0].command' "$FIXTURE_DIR/.claude/settings.json"
  [ "$status" -eq 0 ]
  assert_output_contains "$GUARD_INVOCATION"
}

@test "jenga attach exits successfully against the fixture" {
  cd "$FIXTURE_DIR"
  run node "$JENGA_BIN" attach
  [ "$status" -eq 0 ]
}

@test "jenga attach leaves install-worktree-commit-guard.sh present in the WorktreeCreate hook" {
  cd "$FIXTURE_DIR"
  run node "$JENGA_BIN" attach
  [ "$status" -eq 0 ]
  run jq -r '.hooks.WorktreeCreate[0].hooks[0].command' "$FIXTURE_DIR/.claude/settings.json"
  [ "$status" -eq 0 ]
  assert_output_contains "$GUARD_INVOCATION"
}

@test "jenga attach leaves the WorktreeCreate hook command byte-identical to before" {
  local before
  before="$(jq -r '.hooks.WorktreeCreate[0].hooks[0].command' "$FIXTURE_DIR/.claude/settings.json")"
  cd "$FIXTURE_DIR"
  run node "$JENGA_BIN" attach
  [ "$status" -eq 0 ]
  run jq -r '.hooks.WorktreeCreate[0].hooks[0].command' "$FIXTURE_DIR/.claude/settings.json"
  [ "$status" -eq 0 ]
  [ "$output" = "$before" ]
}

@test "jenga attach leaves WorktreeRemove and SessionEnd hooks untouched" {
  local before_remove before_end
  before_remove="$(jq -c '.hooks.WorktreeRemove' "$FIXTURE_DIR/.claude/settings.json")"
  before_end="$(jq -c '.hooks.SessionEnd' "$FIXTURE_DIR/.claude/settings.json")"
  cd "$FIXTURE_DIR"
  run node "$JENGA_BIN" attach
  [ "$status" -eq 0 ]
  run jq -c '.hooks.WorktreeRemove' "$FIXTURE_DIR/.claude/settings.json"
  [ "$status" -eq 0 ]
  [ "$output" = "$before_remove" ]
  run jq -c '.hooks.SessionEnd' "$FIXTURE_DIR/.claude/settings.json"
  [ "$status" -eq 0 ]
  [ "$output" = "$before_end" ]
}

@test "jenga attach writes mcpServers.jenga into the fixture settings.json" {
  cd "$FIXTURE_DIR"
  run node "$JENGA_BIN" attach
  [ "$status" -eq 0 ]
  run jq -e '.mcpServers.jenga.command == "node"' "$FIXTURE_DIR/.claude/settings.json"
  [ "$status" -eq 0 ]
}
