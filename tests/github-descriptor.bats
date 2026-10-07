#!/usr/bin/env bats
#
# Coverage for the real GitHub CLI auth descriptor
# skills/j-connect/descriptors/github.json (E65_S03_T01).
#
# Pure data checks with jq, the validator and list-services.sh; no `gh` is run.

bats_require_minimum_version 1.5.0
load helpers/assertions

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
GH_JSON="$REPO_ROOT/skills/j-connect/descriptors/github.json"
VALIDATE="$REPO_ROOT/skills/j-connect/scripts/validate-descriptor.sh"
LIST="$REPO_ROOT/skills/j-connect/scripts/list-services.sh"

@test "github.json exists, has id github and passes the descriptor validator" {
  [ -f "$GH_JSON" ]
  [ "$(jq -r '.id' "$GH_JSON")" = "github" ]
  run bash "$VALIDATE" "$GH_JSON"
  [ "$status" -eq 0 ]
}

@test "detect, auth and verify commands, auth type and register_mcp are as specified" {
  [ "$(jq -c '.detect.command' "$GH_JSON")" = '["gh","--version"]' ]
  [ "$(jq -r '.auth.type' "$GH_JSON")" = "browser" ]
  [ "$(jq -c '.auth.check.command' "$GH_JSON")" = '["gh","auth","status"]' ]
  [ "$(jq -c '.verify.command' "$GH_JSON")" = '["gh","auth","status"]' ]
  [ "$(jq -c '.register_mcp' "$GH_JSON")" = '{"supported":false}' ]
}

@test "install and auth docs URLs are official http(s) URLs and the instructions tell the user to run gh auth login" {
  run jq -r '.install.docs_url, .auth.docs_url' "$GH_JSON"
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | grep -Ec '^https?://(github\.com/cli/cli|cli\.github\.com/)')" -eq 2 ]
  assert_contains "$(jq -r '.auth.instructions' "$GH_JSON")" "gh auth login"
}

@test "install.methods has exactly one unpinned darwin/brew/gh entry" {
  [ "$(jq -c '.install.methods' "$GH_JSON")" = '[{"platform":"darwin","manager":"brew","package":"gh"}]' ]
}

@test "no command, script or run key under install, and no script or run key anywhere" {
  # `command` is legitimate only as the argv arrays of detect, auth.check and verify.
  [ "$(jq '[.install | .. | objects | keys[] | select(. == "command" or . == "script" or . == "run")] | length' "$GH_JSON")" -eq 0 ]
  [ "$(jq '[.. | objects | keys[] | select(. == "script" or . == "run")] | length' "$GH_JSON")" -eq 0 ]
}

@test "no secrets block and nothing that looks like a credential" {
  [ "$(jq 'has("secrets")' "$GH_JSON")" = "false" ]
  run grep -Eq 'gh[opsu]_[A-Za-z0-9]{16,}|github_pat_|sk-[A-Za-z0-9]{16,}|AKIA[0-9A-Z]{16}|eyJ[A-Za-z0-9_-]{10,}\.|-----BEGIN|[Bb]earer [A-Za-z0-9]' "$GH_JSON"
  [ "$status" -eq 1 ]
}

@test "list-services.sh with no arguments lists github (mcp false, no requires) and does not skip it, from any cwd" {
  cd "$BATS_TEST_TMPDIR"
  run --separate-stderr bash "$LIST"
  [ "$status" -eq 0 ]
  [ "$(jq -c '.services[] | select(.id == "github") | [.mcp, .requires, .unresolved_requires]' <<<"$output")" = '[false,[],[]]' ]
  [ "$(jq -c '[.skipped[] | select(tostring | test("github"))] | length' <<<"$output")" -eq 0 ]
}
