#!/usr/bin/env bats
#
# Coverage for the real DigitalOcean descriptor skills/j-connect/descriptors/digitalocean.json
# (E65_S05_T02). Pure data checks with jq, the validator and list-services.sh;
# no `doctl` is run (it is not installed on the authoring machine) and nothing
# touches the network.
#
# Design source: project/documentation/digitalocean-connect-research.md (E65_S05_T01). Facts that doc
# marks "could not verify" (exit status of `doctl account get` when logged out,
# where `doctl auth init` stores the token, hosted-MCP OAuth in a real Claude Code
# session, Homebrew on Linux) are NOT asserted here; see tests/digitalocean-connect.bats
# for the stubbed runner behaviour.

bats_require_minimum_version 1.5.0
load helpers/assertions

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
DO_JSON="$REPO_ROOT/skills/j-connect/descriptors/digitalocean.json"
VALIDATE="$REPO_ROOT/skills/j-connect/scripts/validate-descriptor.sh"
LIST="$REPO_ROOT/skills/j-connect/scripts/list-services.sh"
DOCS_INSTALL="https://docs.digitalocean.com/reference/doctl/how-to/install/"
DOCS_MCP="https://docs.digitalocean.com/reference/mcp/configure-mcp/"
DOCS_AUTH="https://docs.digitalocean.com/reference/doctl/reference/auth/init/"

@test "digitalocean.json exists, has id digitalocean and passes the descriptor validator" {
  [ -f "$DO_JSON" ]
  [ "$(jq -r '.id' "$DO_JSON")" = "digitalocean" ]
  run bash "$VALIDATE" "$DO_JSON"
  [ "$status" -eq 0 ]
}

@test "detect is doctl version; auth check and verify are the same authenticated no-op, not a version command" {
  [ "$(jq -c '.detect.command' "$DO_JSON")" = '["doctl","version"]' ]
  [ "$(jq -c '.auth.check.command' "$DO_JSON")" = '["doctl","account","get"]' ]
  [ "$(jq -c '.verify.command' "$DO_JSON")" = '["doctl","account","get"]' ]
  [ "$(jq -c '.auth.check.command' "$DO_JSON")" != "$(jq -c '.detect.command' "$DO_JSON")" ]
  [ "$(jq -r '.auth.type' "$DO_JSON")" = "browser" ]
  assert_contains "$(jq -r '.auth.instructions' "$DO_JSON")" "doctl auth init"
  assert_contains "$(jq -r '.auth.instructions' "$DO_JSON")" "do not paste it into this chat"
}

@test "docs, install.docs_url and auth.docs_url are the official docs.digitalocean.com URLs from the research doc" {
  [ "$(jq -c '.docs' "$DO_JSON")" = "[\"$DOCS_INSTALL\",\"$DOCS_MCP\"]" ]
  [ "$(jq -r '.install.docs_url' "$DO_JSON")" = "$DOCS_INSTALL" ]
  [ "$(jq -r '.auth.docs_url' "$DO_JSON")" = "$DOCS_AUTH" ]
  [ "$(jq -r '[.docs[], .install.docs_url, .auth.docs_url] | map(select(test("^https://docs\\.digitalocean\\.com/reference/"))) | length' "$DO_JSON")" -eq 4 ]
}

@test "install.methods is only the bare unpinned darwin brew package (Linux and Windows fall back to the docs URL)" {
  # Homebrew on Linux is not stated by the install page (research doc, could not verify), so no linux entry.
  [ "$(jq -c '.install.methods' "$DO_JSON")" = '[{"platform":"darwin","manager":"brew","package":"doctl"}]' ]
  [ "$(jq '[.install.methods[].package | select(test("[@ ]|--|:[0-9]|=="))] | length' "$DO_JSON")" -eq 0 ]
}

@test "no command, script or run key under install, and no script or run key anywhere" {
  # `command` is legitimate only as the argv arrays of detect, auth.check and verify.
  [ "$(jq '[.install | .. | objects | keys[] | select(. == "command" or . == "script" or . == "run")] | length' "$DO_JSON")" -eq 0 ]
  [ "$(jq '[.. | objects | keys[] | select(. == "script" or . == "run")] | length' "$DO_JSON")" -eq 0 ]
  # no hardcoded installer invocation or pipe-to-shell string anywhere in the file
  run grep -Eq 'brew install|snap install|pacman -S|dnf install|npm (i|install)|apt(-get)? install|go install|curl |wget |\| *(ba)?sh' "$DO_JSON"
  [ "$status" -eq 1 ]
}

@test "register_mcp is the hosted OAuth http server: droplets endpoint, no env or headers; the one-endpoint limit is stated in text" {
  [ "$(jq -c '.register_mcp' "$DO_JSON")" = '{"supported":true,"name":"digitalocean-droplets","type":"http","url":"https://droplets.mcp.digitalocean.com/mcp"}' ]
  assert_contains "$(jq -r '.auth.instructions' "$DO_JSON")" "one endpoint per service"
}

@test "no secrets block (CLI credential store, hosted OAuth MCP: no env file is ever declared) and nothing that looks like a credential" {
  # Design choice from the research doc: auth.type browser with no secrets.env_file means
  # the runner never creates an env file, so the .gitignore guardrail has nothing to guard.
  [ "$(jq 'has("secrets")' "$DO_JSON")" = "false" ]
  [ "$(jq '.auth | has("env_var")' "$DO_JSON")" = "false" ]
  [ "$(jq '.register_mcp | has("env")' "$DO_JSON")" = "false" ]
  run grep -Eq 'dop_v1_[A-Za-z0-9]{10,}|doo_v1_|dor_v1_|gh[opsu]_[A-Za-z0-9]{16,}|sk-[A-Za-z0-9]{16,}|AKIA[0-9A-Z]{16}|eyJ[A-Za-z0-9_-]{10,}\.|-----BEGIN|[Bb]earer [A-Za-z0-9]' "$DO_JSON"
  [ "$status" -eq 1 ]
}

@test "requires is absent: a GitHub sign-in is not a prerequisite" {
  [ "$(jq 'has("requires")' "$DO_JSON")" = "false" ]
}

@test "list-services.sh with no arguments lists digitalocean (mcp true, no requires) and does not skip it, from any cwd" {
  cd "$BATS_TEST_TMPDIR"
  run --separate-stderr bash "$LIST"
  [ "$status" -eq 0 ]
  [ "$(jq -c '.services[] | select(.id == "digitalocean") | [.mcp, .requires, .unresolved_requires]' <<<"$output")" = '[true,[],[]]' ]
  [ "$(jq -c '[.skipped[] | select(tostring | test("digitalocean"))] | length' <<<"$output")" -eq 0 ]
}

@test "the .claude and .agents mirror copies are byte-identical to the source descriptor" {
  cmp "$DO_JSON" "$REPO_ROOT/.claude/skills/j-connect/descriptors/digitalocean.json"
  cmp "$DO_JSON" "$REPO_ROOT/.agents/skills/j-connect/descriptors/digitalocean.json"
}

@test "the droplet.md pointer: three byte-identical copies, at most 6 added lines, states the split and copies no credential setup" {
  src="$REPO_ROOT/skills/j-publish/adapters/droplet.md"
  cmp "$src" "$REPO_ROOT/.claude/skills/j-publish/adapters/droplet.md"
  cmp "$src" "$REPO_ROOT/.agents/skills/j-publish/adapters/droplet.md"
  assert_contains "$(cat "$src")" "project/documentation/digitalocean-connect-research.md"
  assert_contains "$(cat "$src")" "j.connect"
  # the pointer section is short and carries no credential-setup commands
  see_also="$(sed -n '/^## See also/,$p' "$src")"
  [ "$(printf '%s\n' "$see_also" | grep -c .)" -le 6 ]
  run grep -Eq 'gh secret set|ssh-keygen|ssh-keyscan|doctl auth init' <<<"$see_also"
  [ "$status" -eq 1 ]
}
