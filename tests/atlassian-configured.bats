#!/usr/bin/env bats
#
# E71_S02_T01: scripts/atlassian-configured.sh is the single "is Atlassian configured?" gate.
#
# Every case builds its own scratch project under $BATS_TEST_TMPDIR and points JENGA_PROJECT_ROOT at it, so the
# real project marker and .mcp.json are never read or written. The MCP server identity comes from a fixture
# descriptor (JENGA_ATLASSIAN_DESCRIPTOR), so these tests do not depend on skills/j-connect/descriptors/.
#
# Offline proof: every test runs with network-tool stubs (curl, wget, nc, ssh, ...) first on PATH; each stub drops
# a sentinel file and fails. teardown() asserts the sentinel was never created, so any test that reached for the
# network fails. One test additionally runs with a PATH holding only the handful of tools the script needs.
#
# Mirror safety: depends only on scripts/atlassian-configured.sh, scripts/resolve-root.sh and fixtures built here.

bats_require_minimum_version 1.5.0
load helpers/assertions

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
GATE="$REPO_ROOT/scripts/atlassian-configured.sh"
MARKER_REL="project/configs/atlassian.json"

setup() {
  unset JENGA_ATLASSIAN_DESCRIPTOR JENGA_ATLASSIAN_ACLI_TIMEOUT ACLI_STUB_MODE
  SCRATCH="$BATS_TEST_TMPDIR/proj"
  mkdir -p "$SCRATCH/project/configs"
  printf '{"paths":{"configs":"project/configs"}}\n' > "$SCRATCH/project/configs/workflow.json"
  export JENGA_PROJECT_ROOT="$SCRATCH"

  # Fixture descriptor: the server name and URL the gate must look for in .mcp.json.
  DESC="$BATS_TEST_TMPDIR/atlassian-cloud.json"
  printf '{"register_mcp":{"supported":true,"name":"atlassian-fixture","type":"http","url":"https://mcp.atlassian.example/v1/mcp"}}\n' > "$DESC"
  export JENGA_ATLASSIAN_DESCRIPTOR="$DESC"

  # Network tool stubs: record any call, then fail.
  NET_SENTINEL="$BATS_TEST_TMPDIR/network-was-called"
  NETBIN="$BATS_TEST_TMPDIR/netbin"
  mkdir -p "$NETBIN"
  local t
  for t in curl wget nc ncat telnet ssh scp ftp dig nslookup host ping; do
    printf '#!/bin/sh\necho "%s $*" >> "%s"\nexit 1\n' "$t" "$NET_SENTINEL" > "$NETBIN/$t"
    chmod +x "$NETBIN/$t"
  done

  # acli stub: behaviour chosen by ACLI_STUB_MODE (ok | unauth | hang).
  ACLIBIN="$BATS_TEST_TMPDIR/aclibin"
  mkdir -p "$ACLIBIN"
  cat > "$ACLIBIN/acli" <<'EOF'
#!/bin/sh
case "${ACLI_STUB_MODE:-ok}" in
  ok) exit 0 ;;
  unauth) exit 1 ;;
  hang) exec sleep 30 ;;
esac
exit 2
EOF
  chmod +x "$ACLIBIN/acli"

  PATH="$NETBIN:$PATH"
  export PATH
}

teardown() {
  # No test, on any path, may have invoked a network tool.
  [ ! -e "$NET_SENTINEL" ]
}

# write_marker <enabled> <transport> [products-json]: a valid marker with the five documented fields.
write_marker() {
  local products="${3:-[\"jira\",\"confluence\"]}"
  printf '{"enabled":%s,"products":%s,"deployment":"cloud","site_base_url":"https://example.atlassian.net","transport":"%s"}\n' \
    "$1" "$products" "$2" > "$SCRATCH/$MARKER_REL"
}

# make_minbin: a PATH directory holding only the tools the gate needs (no network tools, no acli).
make_minbin() {
  MINBIN="$BATS_TEST_TMPDIR/minbin"
  mkdir -p "$MINBIN"
  local t p
  for t in bash jq dirname sed head tr grep cat sleep; do
    p=$(command -v "$t" 2>/dev/null || true)
    case "$p" in
      "$NETBIN"/*|"") ;;
      /*) ln -sf "$p" "$MINBIN/$t" ;;
    esac
  done
}

write_mcp_entry() {
  printf '{"mcpServers":{"other":{"type":"stdio","command":"x"},"atlassian-fixture":{"type":"http","url":"https://mcp.atlassian.example/v1/mcp"}}}\n' > "$SCRATCH/.mcp.json"
}

run_gate() {
  run --separate-stderr bash "$GATE"
}

# --- no marker / disabled ---------------------------------------------------------------------------------

@test "no marker: exit 1, not-configured reason, one JSON object, empty stderr" {
  run_gate
  [ "$status" -eq 1 ]
  [ -z "$stderr" ]
  echo "$output" | jq -e '.configured == false' >/dev/null
  echo "$output" | jq -e '(.reason | type) == "string"' >/dev/null
  assert_output_contains "not configured"
  [ "$(echo "$output" | jq -s 'length')" = "1" ]
}

@test "no marker and no .mcp.json and no registry: still exit 1, empty stderr" {
  rm -f "$SCRATCH/.mcp.json" "$SCRATCH/project/configs/workflow.json"
  unset JENGA_PROJECT_ROOT
  cd "$SCRATCH"
  run_gate
  [ "$status" -eq 1 ]
  [ -z "$stderr" ]
  echo "$output" | jq -e '.configured == false' >/dev/null
}

@test "disabled marker (enabled: false): exit 1, not-configured reason, empty stderr" {
  write_marker false mcp
  write_mcp_entry
  run_gate
  [ "$status" -eq 1 ]
  [ -z "$stderr" ]
  echo "$output" | jq -e '.configured == false' >/dev/null
  assert_output_contains "not configured"
}

# --- configured -------------------------------------------------------------------------------------------

@test "configured via MCP: exit 0, full JSON shape, transport reported" {
  write_marker true mcp
  write_mcp_entry
  run_gate
  [ "$status" -eq 0 ]
  [ -z "$stderr" ]
  echo "$output" | jq -e '.configured == true' >/dev/null
  echo "$output" | jq -e '.transport == "mcp"' >/dev/null
  echo "$output" | jq -e '.deployment == "cloud"' >/dev/null
  echo "$output" | jq -e '.site_base_url == "https://example.atlassian.net"' >/dev/null
  echo "$output" | jq -e '.products == ["jira","confluence"]' >/dev/null
  echo "$output" | jq -e '(.reason | type) == "string"' >/dev/null
  [ "$(echo "$output" | jq -s 'length')" = "1" ]
}

@test "configured via MCP: entry matched by URL (query ignored) when the name differs" {
  write_marker true mcp
  printf '{"mcpServers":{"renamed":{"type":"http","url":"https://mcp.atlassian.example/v1/mcp?read_only=true"}}}\n' > "$SCRATCH/.mcp.json"
  run_gate
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.configured == true' >/dev/null
}

@test "configured via MCP without a descriptor: any entry mentioning atlassian counts" {
  write_marker true mcp
  export JENGA_ATLASSIAN_DESCRIPTOR="$BATS_TEST_TMPDIR/does-not-exist.json"
  printf '{"mcpServers":{"my-atlassian":{"type":"http","url":"https://example.invalid/mcp"}}}\n' > "$SCRATCH/.mcp.json"
  run_gate
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.configured == true and .transport == "mcp"' >/dev/null
}

@test "configured via acli: exit 0, transport cli, full JSON shape" {
  write_marker true cli '["jira"]'
  export PATH="$ACLIBIN:$PATH"
  export ACLI_STUB_MODE=ok
  run_gate
  [ "$status" -eq 0 ]
  [ -z "$stderr" ]
  echo "$output" | jq -e '.configured == true' >/dev/null
  echo "$output" | jq -e '.transport == "cli"' >/dev/null
  echo "$output" | jq -e '.products == ["jira"]' >/dev/null
  echo "$output" | jq -e '.deployment == "cloud" and .site_base_url == "https://example.atlassian.net"' >/dev/null
}

# --- drift ------------------------------------------------------------------------------------------------

@test "drift (MCP): marker enabled but the entry is gone: exit 1, names drift and remedy" {
  write_marker true mcp
  printf '{"mcpServers":{"other":{"type":"stdio","command":"x"}}}\n' > "$SCRATCH/.mcp.json"
  run_gate
  [ "$status" -eq 1 ]
  [ -z "$stderr" ]
  echo "$output" | jq -e '.configured == false' >/dev/null
  assert_output_contains "drift"
  assert_output_contains "j.connect"
  assert_output_contains "enabled"
}

@test "drift (MCP): marker enabled and .mcp.json absent: exit 1, names drift and remedy" {
  write_marker true mcp
  [ ! -e "$SCRATCH/.mcp.json" ]
  run_gate
  [ "$status" -eq 1 ]
  [ -z "$stderr" ]
  echo "$output" | jq -e '.configured == false' >/dev/null
  assert_output_contains "drift"
  assert_output_contains "j.connect"
}

@test "drift (acli): not authenticated: exit 1, names drift and remedy" {
  write_marker true cli
  export PATH="$ACLIBIN:$PATH"
  export ACLI_STUB_MODE=unauth
  run_gate
  [ "$status" -eq 1 ]
  [ -z "$stderr" ]
  echo "$output" | jq -e '.configured == false' >/dev/null
  assert_output_contains "drift"
  assert_output_contains "j.connect"
}

@test "drift (acli): acli not installed: exit 1, reason names drift (never a crash)" {
  write_marker true cli
  make_minbin
  run --separate-stderr env PATH="$MINBIN" "$BASH" "$GATE"
  [ "$status" -eq 1 ]
  [ -z "$stderr" ]
  echo "$output" | jq -e '.configured == false' >/dev/null
  assert_output_contains "drift"
}

@test "acli check is bounded: a hanging acli yields exit 1 with a reason, well inside the bound" {
  write_marker true cli
  export PATH="$ACLIBIN:$PATH"
  export ACLI_STUB_MODE=hang
  export JENGA_ATLASSIAN_ACLI_TIMEOUT=1
  local start end
  start=$(date +%s)
  run_gate
  end=$(date +%s)
  [ "$status" -eq 1 ]
  [ -z "$stderr" ]
  echo "$output" | jq -e '.configured == false' >/dev/null
  assert_output_contains "drift"
  # two attempts at 1 s each plus slack; the stub itself would sleep 30 s
  [ $((end - start)) -lt 15 ]
}

# --- malformed marker -------------------------------------------------------------------------------------

@test "malformed marker JSON: exit 1, clear reason in the JSON, no crash" {
  printf '{"enabled": true, "products": [\n' > "$SCRATCH/$MARKER_REL"
  run_gate
  [ "$status" -eq 1 ]
  [ -z "$stderr" ]
  echo "$output" | jq -e '.configured == false' >/dev/null
  assert_output_contains "malformed"
  [ "$(echo "$output" | jq -s 'length')" = "1" ]
}

@test "marker that is not a JSON object: exit 1, malformed reason" {
  printf '["enabled"]\n' > "$SCRATCH/$MARKER_REL"
  run_gate
  [ "$status" -eq 1 ]
  assert_output_contains "malformed"
}

@test "marker with a wrong-typed enabled: exit 1, malformed reason" {
  printf '{"enabled":"yes"}\n' > "$SCRATCH/$MARKER_REL"
  run_gate
  [ "$status" -eq 1 ]
  assert_output_contains "malformed"
}

@test "marker with an unknown product or transport: exit 1, malformed reason" {
  write_marker true mcp '["jira","trello"]'
  run_gate
  [ "$status" -eq 1 ]
  assert_output_contains "malformed"
  assert_output_contains "products"

  printf '{"enabled":true,"products":["jira"],"deployment":"cloud","site_base_url":"https://x.atlassian.net","transport":"pigeon"}\n' > "$SCRATCH/$MARKER_REL"
  run_gate
  [ "$status" -eq 1 ]
  assert_output_contains "malformed"
  assert_output_contains "transport"
}

# --- offline / no secrets ---------------------------------------------------------------------------------

@test "offline: a PATH holding only the needed tools (no network tools at all) still gives the right result" {
  make_minbin
  local minbin="$MINBIN"
  write_marker true mcp
  write_mcp_entry
  run --separate-stderr env PATH="$minbin" "$BASH" "$GATE"
  [ "$status" -eq 0 ]
  [ -z "$stderr" ]
  echo "$output" | jq -e '.configured == true' >/dev/null

  rm -f "$SCRATCH/.mcp.json"
  run --separate-stderr env PATH="$minbin" "$BASH" "$GATE"
  [ "$status" -eq 1 ]
  [ -z "$stderr" ]
  echo "$output" | jq -e '.configured == false' >/dev/null
}

@test "the script resolves the marker via resolve-root.sh and hardcodes no project/ path" {
  run grep -n 'resolve-root.sh' "$GATE"
  [ "$status" -eq 0 ]
  run bash -c 'grep -v -E "^[[:space:]]*#" "$1" | grep -n -E "(^|[^A-Za-z_./-])[.]?project/"' _ "$GATE"
  [ "$status" -eq 1 ]
}

@test "output never contains secret-looking values and the marker holds only the five fields" {
  write_marker true mcp
  write_mcp_entry
  run_gate
  [ "$status" -eq 0 ]
  assert_output_not_contains "token"
  assert_output_not_contains "password"
  [ "$(jq -r 'keys | join(",")' "$SCRATCH/$MARKER_REL")" = "deployment,enabled,products,site_base_url,transport" ]
}
