#!/usr/bin/env bats
#
# Coverage for the real Supabase descriptor skills/j-connect/descriptors/supabase.json
# (E65_S04_T02). Pure data checks with jq, the validator and list-services.sh;
# no `supabase` is run and nothing touches the network.
#
# Design source: project/documentation/supabase-connect-research.md (E65_S04_T01). Facts that doc
# marks "could not verify" (exit status of `supabase projects list` when logged
# out, the exact text `supabase login` prints, MCP OAuth in a real Claude Code
# session) are NOT asserted here; see tests/supabase-connect.bats for the
# stubbed runner behaviour.

bats_require_minimum_version 1.5.0
load helpers/assertions

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
SB_JSON="$REPO_ROOT/skills/j-connect/descriptors/supabase.json"
VALIDATE="$REPO_ROOT/skills/j-connect/scripts/validate-descriptor.sh"
LIST="$REPO_ROOT/skills/j-connect/scripts/list-services.sh"
DOCS_INSTALL="https://supabase.com/docs/guides/local-development/cli/getting-started"
DOCS_MCP="https://supabase.com/docs/guides/getting-started/mcp"
DOCS_LOGIN="https://supabase.com/docs/reference/cli/supabase-login"

@test "supabase.json exists, has id supabase and passes the descriptor validator" {
  [ -f "$SB_JSON" ]
  [ "$(jq -r '.id' "$SB_JSON")" = "supabase" ]
  run bash "$VALIDATE" "$SB_JSON"
  [ "$status" -eq 0 ]
}

@test "detect is supabase --version; auth check and verify are the same authenticated no-op, not --version" {
  [ "$(jq -c '.detect.command' "$SB_JSON")" = '["supabase","--version"]' ]
  [ "$(jq -c '.auth.check.command' "$SB_JSON")" = '["supabase","projects","list"]' ]
  [ "$(jq -c '.verify.command' "$SB_JSON")" = '["supabase","projects","list"]' ]
  [ "$(jq -c '.auth.check.command' "$SB_JSON")" != "$(jq -c '.detect.command' "$SB_JSON")" ]
  [ "$(jq -r '.auth.type' "$SB_JSON")" = "browser" ]
  assert_contains "$(jq -r '.auth.instructions' "$SB_JSON")" "supabase login"
}

@test "docs, install.docs_url and auth.docs_url are the official supabase.com URLs from the research doc" {
  [ "$(jq -c '.docs' "$SB_JSON")" = "[\"$DOCS_INSTALL\",\"$DOCS_MCP\"]" ]
  [ "$(jq -r '.install.docs_url' "$SB_JSON")" = "$DOCS_INSTALL" ]
  [ "$(jq -r '.auth.docs_url' "$SB_JSON")" = "$DOCS_LOGIN" ]
  [ "$(jq -r '[.docs[], .install.docs_url, .auth.docs_url] | map(select(test("^https://supabase\\.com/docs/"))) | length' "$SB_JSON")" -eq 4 ]
}

@test "install.methods are bare unpinned brew packages for darwin and linux only (no npm, no windows)" {
  [ "$(jq -c '.install.methods' "$SB_JSON")" = '[{"platform":"darwin","manager":"brew","package":"supabase/tap/supabase"},{"platform":"linux","manager":"brew","package":"supabase/tap/supabase"}]' ]
  # no version or flag in any package
  [ "$(jq '[.install.methods[].package | select(test("[@ ]|--|:[0-9]|=="))] | length' "$SB_JSON")" -eq 0 ]
}

@test "no command, script or run key under install, and no script or run key anywhere" {
  # `command` is legitimate only as the argv arrays of detect, auth.check and verify.
  [ "$(jq '[.install | .. | objects | keys[] | select(. == "command" or . == "script" or . == "run")] | length' "$SB_JSON")" -eq 0 ]
  [ "$(jq '[.. | objects | keys[] | select(. == "script" or . == "run")] | length' "$SB_JSON")" -eq 0 ]
  # no hardcoded installer invocation or pipe-to-shell string anywhere in the file
  run grep -Eq 'brew install|npm (i|install)|scoop install|apt(-get)? install|curl |wget |\| *(ba)?sh' "$SB_JSON"
  [ "$status" -eq 1 ]
}

@test "register_mcp is the hosted http server: name supabase, official url, no env or headers" {
  [ "$(jq -c '.register_mcp' "$SB_JSON")" = '{"supported":true,"name":"supabase","type":"http","url":"https://mcp.supabase.com/mcp"}' ]
}

@test "no secrets block (hosted MCP uses OAuth, browser auth creates no env file) and nothing that looks like a credential" {
  # Design choice from the research doc: with auth.type browser and no secrets.env_file
  # the runner never creates an env file, so the .gitignore guardrail has nothing to guard.
  [ "$(jq 'has("secrets")' "$SB_JSON")" = "false" ]
  run grep -Eq 'sbp_[A-Za-z0-9]{10,}|gh[opsu]_[A-Za-z0-9]{16,}|sk-[A-Za-z0-9]{16,}|AKIA[0-9A-Z]{16}|eyJ[A-Za-z0-9_-]{10,}\.|-----BEGIN|[Bb]earer [A-Za-z0-9]' "$SB_JSON"
  [ "$status" -eq 1 ]
}

@test "requires is absent: a GitHub sign-in is not a prerequisite" {
  [ "$(jq 'has("requires")' "$SB_JSON")" = "false" ]
}

@test "list-services.sh with no arguments lists supabase (mcp true, no requires) and does not skip it, from any cwd" {
  cd "$BATS_TEST_TMPDIR"
  run --separate-stderr bash "$LIST"
  [ "$status" -eq 0 ]
  [ "$(jq -c '.services[] | select(.id == "supabase") | [.mcp, .requires, .unresolved_requires]' <<<"$output")" = '[true,[],[]]' ]
  [ "$(jq -c '[.skipped[] | select(tostring | test("supabase"))] | length' <<<"$output")" -eq 0 ]
}

@test "the .claude and .agents mirror copies are byte-identical to the source descriptor" {
  cmp "$SB_JSON" "$REPO_ROOT/.claude/skills/j-connect/descriptors/supabase.json"
  cmp "$SB_JSON" "$REPO_ROOT/.agents/skills/j-connect/descriptors/supabase.json"
}
