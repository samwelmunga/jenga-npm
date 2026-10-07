#!/usr/bin/env bats
#
# Coverage for the real Expo descriptor skills/j-connect/descriptors/expo.json
# (E65_S06_T03). Pure data checks with jq, the validator and list-services.sh;
# no `eas`, `expo` or network call is made (neither CLI is installed on the authoring machine).
#
# Design source: project/documentation/figma-expo-connect-research.md (E65_S06_T01), Part B. Facts that doc marks
# "could not verify" (that `eas --version` is the documented version command, the exit status of
# `eas whoami` when logged out, where `eas login` stores credentials, a Node prerequisite, Expo MCP
# OAuth in a real Claude Code session) are NOT asserted here; see tests/expo-connect.bats for the
# stubbed runner behaviour.

bats_require_minimum_version 1.5.0
load helpers/assertions

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
EXPO_JSON="$REPO_ROOT/skills/j-connect/descriptors/expo.json"
VALIDATE="$REPO_ROOT/skills/j-connect/scripts/validate-descriptor.sh"
LIST="$REPO_ROOT/skills/j-connect/scripts/list-services.sh"
DOCS_CLI="https://docs.expo.dev/eas/cli/"
DOCS_MCP="https://docs.expo.dev/mcp/"

@test "expo.json exists, has id expo and passes the descriptor validator" {
  [ -f "$EXPO_JSON" ]
  [ "$(jq -r '.id' "$EXPO_JSON")" = "expo" ]
  run bash "$VALIDATE" "$EXPO_JSON"
  [ "$status" -eq 0 ]
}

@test "detect is the eas version probe; auth check and verify are the same authenticated no-op, not a version command" {
  [ "$(jq -c '.detect.command' "$EXPO_JSON")" = '["eas","--version"]' ]
  [ "$(jq -c '.auth.check.command' "$EXPO_JSON")" = '["eas","whoami"]' ]
  [ "$(jq -c '.verify.command' "$EXPO_JSON")" = '["eas","whoami"]' ]
  [ "$(jq -c '.auth.check.command' "$EXPO_JSON")" != "$(jq -c '.detect.command' "$EXPO_JSON")" ]
  [ "$(jq -r '.auth.type' "$EXPO_JSON")" = "browser" ]
  assert_contains "$(jq -r '.auth.instructions' "$EXPO_JSON")" "eas login"
  assert_contains "$(jq -r '.auth.instructions' "$EXPO_JSON")" "do not paste a password or token into this chat"
}

@test "docs, install.docs_url and auth.docs_url are the official docs.expo.dev URLs from the research doc" {
  [ "$(jq -c '.docs' "$EXPO_JSON")" = "[\"$DOCS_CLI\",\"$DOCS_MCP\"]" ]
  [ "$(jq -r '.install.docs_url' "$EXPO_JSON")" = "$DOCS_CLI" ]
  [ "$(jq -r '.auth.docs_url' "$EXPO_JSON")" = "$DOCS_CLI" ]
  [ "$(jq -r '[.docs[], .install.docs_url, .auth.docs_url] | map(select(test("^https://docs\\.expo\\.dev/"))) | length' "$EXPO_JSON")" -eq 4 ]
}

@test "install.methods is only the bare unpinned npm eas-cli package for darwin and linux (everything else falls back to the docs URL)" {
  [ "$(jq -c '.install.methods' "$EXPO_JSON")" = '[{"platform":"darwin","manager":"npm","package":"eas-cli"},{"platform":"linux","manager":"npm","package":"eas-cli"}]' ]
  [ "$(jq '[.install.methods[].package | select(test("[@ ]|--|:[0-9]|==|latest"))] | length' "$EXPO_JSON")" -eq 0 ]
  # a Homebrew install of eas-cli is not stated by any page read (research doc), so no brew entry
  [ "$(jq '[.install.methods[] | select(.manager == "brew")] | length' "$EXPO_JSON")" -eq 0 ]
}

@test "no command, script or run key under install, and no hardcoded install string anywhere" {
  # `command` is legitimate only as the argv arrays of detect, auth.check and verify.
  [ "$(jq '[.install | .. | objects | keys[] | select(. == "command" or . == "script" or . == "run")] | length' "$EXPO_JSON")" -eq 0 ]
  [ "$(jq '[.. | objects | keys[] | select(. == "script" or . == "run")] | length' "$EXPO_JSON")" -eq 0 ]
  run grep -Eq 'brew install|snap install|npm (i|install)|yarn (global )?add|pnpm (add|install)|bun (add|install)|npx |apt(-get)? install|curl |wget |\| *(ba)?sh' "$EXPO_JSON"
  [ "$status" -eq 1 ]
}

@test "auth is browser: no secrets block, no env var, no env file (the CLI keeps its own credentials, so the gitignore guardrail has nothing to guard) and nothing that looks like a credential" {
  [ "$(jq 'has("secrets")' "$EXPO_JSON")" = "false" ]
  [ "$(jq '.auth | has("env_var")' "$EXPO_JSON")" = "false" ]
  [ "$(jq '.register_mcp | has("env")' "$EXPO_JSON")" = "false" ]
  # the non-interactive token variable stays out of the descriptor (research doc B3)
  run grep -q 'EXPO_TOKEN' "$EXPO_JSON"
  [ "$status" -eq 1 ]
  run grep -Eq 'gh[opsu]_[A-Za-z0-9]{16,}|sk-[A-Za-z0-9]{16,}|AKIA[0-9A-Z]{16}|eyJ[A-Za-z0-9_-]{10,}\.|-----BEGIN|[Bb]earer [A-Za-z0-9]' "$EXPO_JSON"
  [ "$status" -eq 1 ]
}

@test "register_mcp is explicitly unsupported and the reasons (plugin duplicate, EAS/store tools) are in free text" {
  [ "$(jq -c '.register_mcp' "$EXPO_JSON")" = '{"supported":false}' ]
  instr="$(jq -r '.auth.instructions' "$EXPO_JSON")"
  assert_contains "$instr" "not registered here"
  assert_contains "$instr" "duplicate"
  assert_contains "$instr" "https://docs.expo.dev/mcp/"
}

@test "EAS / store-submission boundary: no build, submit, credentials or testflight argv element, no store or signing env-var name, no publish.json reference" {
  [ "$(jq '[.detect.command[], .auth.check.command[], .verify.command[]] | map(select(. == "build" or . == "submit" or . == "credentials" or . == "testflight" or . == "build:run" or test("^(build|submit|credentials|testflight)"))) | length' "$EXPO_JSON")" -eq 0 ]
  [ "$(jq '[.. | strings | select(test("APP_STORE_CONNECT|CODE_SIGN_IDENTITY|PROVISIONING_PROFILE|PLAY_CONSOLE|GOOGLE_SERVICE_ACCOUNT"))] | length' "$EXPO_JSON")" -eq 0 ]
  run grep -q 'publish\.json' "$EXPO_JSON"
  [ "$status" -eq 1 ]
  hint="$(jq -r '.install.hint' "$EXPO_JSON")"
  assert_contains "$hint" "EAS Build, EAS Submit, signing and store credentials"
  assert_contains "$hint" "j.publish"
  assert_contains "$hint" "mobile-ios"
}

@test "verify is an exit-status command, not a stored-string comparison; requires is absent" {
  [ "$(jq '.verify | keys' -c "$EXPO_JSON")" = '["command"]' ]
  [ "$(jq 'has("requires")' "$EXPO_JSON")" = "false" ]
}

@test "free text carries the research doc's could-not-verify caveats" {
  assert_contains "$(jq -r '.install.hint' "$EXPO_JSON")" "not verified against a real machine"
  assert_contains "$(jq -r '.install.hint' "$EXPO_JSON")" "Node.js requirement"
  assert_contains "$(jq -r '.auth.instructions' "$EXPO_JSON")" "was not verified against a real account"
}

@test "list-services.sh with no arguments lists expo (mcp false, no requires) and does not skip it, from any cwd" {
  cd "$BATS_TEST_TMPDIR"
  run --separate-stderr bash "$LIST"
  [ "$status" -eq 0 ]
  [ "$(jq -c '.services[] | select(.id == "expo") | [.mcp, .requires, .unresolved_requires]' <<<"$output")" = '[false,[],[]]' ]
  [ "$(jq -c '[.skipped[] | select(tostring | test("expo"))] | length' <<<"$output")" -eq 0 ]
}

@test "the .claude and .agents mirror copies are byte-identical to the source descriptor" {
  cmp "$EXPO_JSON" "$REPO_ROOT/.claude/skills/j-connect/descriptors/expo.json"
  cmp "$EXPO_JSON" "$REPO_ROOT/.agents/skills/j-connect/descriptors/expo.json"
}
