#!/usr/bin/env bats
#
# Coverage for the real Figma descriptor skills/j-connect/descriptors/figma.json
# (E65_S06_T02). Pure data checks with jq, the validator and list-services.sh;
# no `claude`, Figma or network call is made.
#
# Design source: project/documentation/figma-expo-connect-research.md (E65_S06_T01), design (A) "detect and report".
# What the probe covers, per that doc (A3): `claude mcp get "claude.ai Figma"` sees the claude.ai
# connector (case i). It does NOT see a project .mcp.json entry unless that entry is named exactly
# "claude.ai Figma" (case ii), nor a user/local-scope entry or Figma plugin server under another
# name (case iii). Exit 0 means "configured", not "connected"/"authorised".
# Facts the doc marks "could not verify" (plugin server name, exit status for a server needing
# authentication, real OAuth in Claude Code) are NOT asserted here; see tests/figma-connect.bats
# for the stubbed runner behaviour.

bats_require_minimum_version 1.5.0
load helpers/assertions

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
FIGMA_JSON="$REPO_ROOT/skills/j-connect/descriptors/figma.json"
VALIDATE="$REPO_ROOT/skills/j-connect/scripts/validate-descriptor.sh"
LIST="$REPO_ROOT/skills/j-connect/scripts/list-services.sh"
DOCS_REMOTE="https://developers.figma.com/docs/figma-mcp-server/remote-server-installation/"
DOCS_CLAUDE="https://help.figma.com/hc/en-us/articles/39888612464151-Claude-Code-and-Figma-Set-up-the-MCP-server"

@test "figma.json exists, has id figma and passes the descriptor validator" {
  [ -f "$FIGMA_JSON" ]
  [ "$(jq -r '.id' "$FIGMA_JSON")" = "figma" ]
  run bash "$VALIDATE" "$FIGMA_JSON"
  [ "$status" -eq 0 ]
}

@test "detect and verify are the claude mcp get probe for the claude.ai Figma connector, as an argv array" {
  [ "$(jq -c '.detect.command' "$FIGMA_JSON")" = '["claude","mcp","get","claude.ai Figma"]' ]
  [ "$(jq -c '.verify.command' "$FIGMA_JSON")" = '["claude","mcp","get","claude.ai Figma"]' ]
  [ "$(jq '.detect.command | type' "$FIGMA_JSON")" = '"array"' ]
  # the probe is read-only: never add, remove or reset
  [ "$(jq '[.detect.command[], .verify.command[]] | map(select(. == "add" or . == "remove" or . == "reset")) | length' "$FIGMA_JSON")" -eq 0 ]
}

@test "free text states which already-connected cases the probe cannot see and that exit 0 is not authorisation" {
  hint="$(jq -r '.install.hint' "$FIGMA_JSON")"
  assert_contains "$hint" "claude.ai Figma connector"
  assert_contains "$hint" "another name"
  assert_contains "$hint" "user or local scope"
  assert_contains "$hint" "Figma plugin"
  assert_contains "$hint" "duplicate"
  assert_contains "$(jq -r '.auth.instructions' "$FIGMA_JSON")" "not that you have approved it"
}

@test "docs and install.docs_url are the official Figma URLs from the research doc" {
  [ "$(jq -c '.docs' "$FIGMA_JSON")" = "[\"$DOCS_REMOTE\",\"$DOCS_CLAUDE\"]" ]
  [ "$(jq -r '.install.docs_url' "$FIGMA_JSON")" = "$DOCS_REMOTE" ]
  [ "$(jq -r '.auth.docs_url' "$FIGMA_JSON")" = "$DOCS_CLAUDE" ]
  [ "$(jq -r '[.docs[], .install.docs_url, .auth.docs_url] | map(select(test("^https://(developers|help)\\.figma\\.com/"))) | length' "$FIGMA_JSON")" -eq 4 ]
}

@test "no install methods, no command/script/run under install, and no hardcoded install string anywhere" {
  # `command` is legitimate only as the argv arrays of detect and verify.
  [ "$(jq '.install | has("methods")' "$FIGMA_JSON")" = "false" ]
  [ "$(jq '[.install | .. | objects | keys[] | select(. == "command" or . == "script" or . == "run")] | length' "$FIGMA_JSON")" -eq 0 ]
  [ "$(jq '[.. | objects | keys[] | select(. == "script" or . == "run")] | length' "$FIGMA_JSON")" -eq 0 ]
  run grep -Eq 'brew install|snap install|npm (i|install)|apt(-get)? install|claude plugin install|claude mcp add|curl |wget |\| *(ba)?sh' "$FIGMA_JSON"
  [ "$status" -eq 1 ]
}

@test "register_mcp is explicitly unsupported (detect and report) and the duplicate-avoidance reason is in free text" {
  [ "$(jq -c '.register_mcp' "$FIGMA_JSON")" = '{"supported":false}' ]
  assert_contains "$(jq -r '.install.hint' "$FIGMA_JSON")" "could duplicate an existing Figma connection"
}

@test "auth is none (OAuth happens inside Claude Code), with no secrets block and nothing that looks like a credential" {
  [ "$(jq -r '.auth.type' "$FIGMA_JSON")" = "none" ]
  [ "$(jq 'has("secrets")' "$FIGMA_JSON")" = "false" ]
  [ "$(jq '.auth | has("env_var")' "$FIGMA_JSON")" = "false" ]
  [ "$(jq '.auth | has("check")' "$FIGMA_JSON")" = "false" ]
  assert_contains "$(jq -r '.auth.instructions' "$FIGMA_JSON")" "never handles a token"
  run grep -Eq 'figd_|gh[opsu]_[A-Za-z0-9]{16,}|sk-[A-Za-z0-9]{16,}|AKIA[0-9A-Z]{16}|eyJ[A-Za-z0-9_-]{10,}\.|-----BEGIN|[Bb]earer [A-Za-z0-9]' "$FIGMA_JSON"
  [ "$status" -eq 1 ]
}

@test "verify is an exit-status command, not a stored-string comparison; requires is absent" {
  [ "$(jq '.verify | keys' -c "$FIGMA_JSON")" = '["command"]' ]
  [ "$(jq 'has("requires")' "$FIGMA_JSON")" = "false" ]
}

@test "list-services.sh with no arguments lists figma (mcp false, no requires) and does not skip it, from any cwd" {
  cd "$BATS_TEST_TMPDIR"
  run --separate-stderr bash "$LIST"
  [ "$status" -eq 0 ]
  [ "$(jq -c '.services[] | select(.id == "figma") | [.mcp, .requires, .unresolved_requires]' <<<"$output")" = '[false,[],[]]' ]
  [ "$(jq -c '[.skipped[] | select(tostring | test("figma"))] | length' <<<"$output")" -eq 0 ]
}

@test "the .claude and .agents mirror copies are byte-identical to the source descriptor" {
  cmp "$FIGMA_JSON" "$REPO_ROOT/.claude/skills/j-connect/descriptors/figma.json"
  cmp "$FIGMA_JSON" "$REPO_ROOT/.agents/skills/j-connect/descriptors/figma.json"
}
