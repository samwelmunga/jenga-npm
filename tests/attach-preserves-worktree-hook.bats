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
# Since E65_S07 (see project/documentation/mcp-registration-decision.md) lib/commands/attach.js
# registers the router in the project-root .mcp.json -- the file Claude Code
# reads project-scope MCP servers from -- and no longer opens
# .claude/settings.json at all. The hook-preservation tests below therefore hold
# by construction; they stay as regression guards, and the .mcp.json tests cover
# the new contract (create, merge by name, idempotent re-run, refusal on invalid
# JSON, and the migration case of a stale mcpServers.jenga in settings.json).

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

@test "jenga attach leaves .claude/settings.json byte-identical (no mcpServers written there)" {
  local before
  before="$(cat "$FIXTURE_DIR/.claude/settings.json")"
  cd "$FIXTURE_DIR"
  run node "$JENGA_BIN" attach
  [ "$status" -eq 0 ]
  [ "$(cat "$FIXTURE_DIR/.claude/settings.json")" = "$before" ]
  run jq -e 'has("mcpServers") | not' "$FIXTURE_DIR/.claude/settings.json"
  [ "$status" -eq 0 ]
}

@test "jenga attach creates .mcp.json with the jenga router entry when missing" {
  [ ! -e "$FIXTURE_DIR/.mcp.json" ]
  cd "$FIXTURE_DIR"
  run node "$JENGA_BIN" attach
  [ "$status" -eq 0 ]
  assert_output_contains ".mcp.json updated"
  assert_output_contains "Pending approval"
  run jq -e '.mcpServers.jenga.type == "stdio" and .mcpServers.jenga.command == "node"
             and (.mcpServers.jenga.args | length == 1)
             and (.mcpServers.jenga.args[0] | endswith("/mcp/router/index.js"))
             and (.mcpServers | keys == ["jenga"])' "$FIXTURE_DIR/.mcp.json"
  [ "$status" -eq 0 ]
  # atomic write leaves no temp file behind
  [ -z "$(find "$FIXTURE_DIR" -maxdepth 1 -name '*.tmp')" ]
}

@test "jenga attach works with no .claude directory at all and creates none" {
  rm -rf "$FIXTURE_DIR/.claude"
  cd "$FIXTURE_DIR"
  run node "$JENGA_BIN" attach
  [ "$status" -eq 0 ]
  [ -f "$FIXTURE_DIR/.mcp.json" ]
  [ ! -e "$FIXTURE_DIR/.claude" ]
}

@test "jenga attach merges alongside unrelated servers and keys without touching them" {
  cat > "$FIXTURE_DIR/.mcp.json" <<'EOF'
{
  "mcpServers": {
    "other": { "type": "stdio", "command": "other-cmd", "args": ["a", "b"], "env": { "X": "${X}" } },
    "remote": { "type": "http", "url": "https://example.invalid/mcp" }
  },
  "somethingElse": { "keep": [1, 2, 3] }
}
EOF
  local before_other before_remote before_else
  before_other="$(jq -c '.mcpServers.other' "$FIXTURE_DIR/.mcp.json")"
  before_remote="$(jq -c '.mcpServers.remote' "$FIXTURE_DIR/.mcp.json")"
  before_else="$(jq -c '.somethingElse' "$FIXTURE_DIR/.mcp.json")"
  cd "$FIXTURE_DIR"
  run node "$JENGA_BIN" attach
  [ "$status" -eq 0 ]
  [ "$(jq -c '.mcpServers.other' "$FIXTURE_DIR/.mcp.json")" = "$before_other" ]
  [ "$(jq -c '.mcpServers.remote' "$FIXTURE_DIR/.mcp.json")" = "$before_remote" ]
  [ "$(jq -c '.somethingElse' "$FIXTURE_DIR/.mcp.json")" = "$before_else" ]
  [ "$(jq -c '.mcpServers | keys_unsorted' "$FIXTURE_DIR/.mcp.json")" = '["other","remote","jenga"]' ]
  [ "$(jq -r '.mcpServers.jenga.command' "$FIXTURE_DIR/.mcp.json")" = "node" ]
}

@test "jenga attach re-run is idempotent and does not rewrite an up-to-date .mcp.json" {
  cd "$FIXTURE_DIR"
  run node "$JENGA_BIN" attach
  [ "$status" -eq 0 ]
  local first inode_before
  first="$(cat "$FIXTURE_DIR/.mcp.json")"
  # A rewrite goes through temp file + rename, which would change the inode.
  inode_before="$(ls -i "$FIXTURE_DIR/.mcp.json" | awk '{print $1}')"
  run node "$JENGA_BIN" attach
  [ "$status" -eq 0 ]
  assert_output_contains "already up to date"
  [ "$(cat "$FIXTURE_DIR/.mcp.json")" = "$first" ]
  [ "$(ls -i "$FIXTURE_DIR/.mcp.json" | awk '{print $1}')" = "$inode_before" ]
}

@test "jenga attach replaces only a stale jenga entry (e.g. after an upgrade), in place" {
  printf '%s\n' '{"mcpServers":{"first":{"type":"stdio","command":"c1","args":[]},"jenga":{"type":"stdio","command":"node","args":["/old/path/index.js"]},"last":{"type":"stdio","command":"c2","args":[]}}}' > "$FIXTURE_DIR/.mcp.json"
  cd "$FIXTURE_DIR"
  run node "$JENGA_BIN" attach
  [ "$status" -eq 0 ]
  [ "$(jq -c '.mcpServers | keys_unsorted' "$FIXTURE_DIR/.mcp.json")" = '["first","jenga","last"]' ]
  [ "$(jq -r '.mcpServers.jenga.args[0]' "$FIXTURE_DIR/.mcp.json")" != "/old/path/index.js" ]
  [ "$(jq -c '.mcpServers.first' "$FIXTURE_DIR/.mcp.json")" = '{"type":"stdio","command":"c1","args":[]}' ]
  [ "$(jq -c '.mcpServers.last' "$FIXTURE_DIR/.mcp.json")" = '{"type":"stdio","command":"c2","args":[]}' ]
}

@test "jenga attach refuses an unparseable .mcp.json and leaves it untouched" {
  printf '{ "mcpServers": { oops' > "$FIXTURE_DIR/.mcp.json"
  local before
  before="$(cat "$FIXTURE_DIR/.mcp.json")"
  cd "$FIXTURE_DIR"
  run node "$JENGA_BIN" attach
  [ "$status" -ne 0 ]
  assert_output_contains "Failed to parse .mcp.json"
  [ "$(cat "$FIXTURE_DIR/.mcp.json")" = "$before" ]
}

@test "jenga attach refuses a non-object mcpServers and leaves .mcp.json untouched" {
  printf '{"mcpServers": []}\n' > "$FIXTURE_DIR/.mcp.json"
  local before
  before="$(cat "$FIXTURE_DIR/.mcp.json")"
  cd "$FIXTURE_DIR"
  run node "$JENGA_BIN" attach
  [ "$status" -ne 0 ]
  assert_output_contains "mcpServers"
  [ "$(cat "$FIXTURE_DIR/.mcp.json")" = "$before" ]
}

@test "migration: a stale mcpServers.jenga in .claude/settings.json is left alone and a note is printed" {
  jq '. + {mcpServers: {jenga: {type: "stdio", command: "node", args: ["/old/router.js"]}, mine: {type: "stdio", command: "m", args: []}}}' \
    "$FIXTURE_DIR/.claude/settings.json" > "$FIXTURE_DIR/s.tmp" && mv "$FIXTURE_DIR/s.tmp" "$FIXTURE_DIR/.claude/settings.json"
  local before
  before="$(cat "$FIXTURE_DIR/.claude/settings.json")"
  cd "$FIXTURE_DIR"
  run node "$JENGA_BIN" attach
  [ "$status" -eq 0 ]
  assert_output_contains ".claude/settings.json still has an older mcpServers.jenga"
  [ "$(cat "$FIXTURE_DIR/.claude/settings.json")" = "$before" ]
  [ "$(jq -r '.mcpServers.jenga.command' "$FIXTURE_DIR/.mcp.json")" = "node" ]
}

@test "no migration note when .claude/settings.json has no mcpServers.jenga" {
  cd "$FIXTURE_DIR"
  run node "$JENGA_BIN" attach
  [ "$status" -eq 0 ]
  [[ "$output" != *"older mcpServers.jenga"* ]]
}

@test "an unparseable .claude/settings.json no longer makes attach fail, and is not modified" {
  printf 'not json' > "$FIXTURE_DIR/.claude/settings.json"
  cd "$FIXTURE_DIR"
  run node "$JENGA_BIN" attach
  [ "$status" -eq 0 ]
  [ "$(cat "$FIXTURE_DIR/.claude/settings.json")" = "not json" ]
  [ -f "$FIXTURE_DIR/.mcp.json" ]
}

@test "jenga attach without jenga.cli.json still fails and writes nothing" {
  rm "$FIXTURE_DIR/jenga.cli.json"
  cd "$FIXTURE_DIR"
  run node "$JENGA_BIN" attach
  [ "$status" -ne 0 ]
  [ ! -e "$FIXTURE_DIR/.mcp.json" ]
}
