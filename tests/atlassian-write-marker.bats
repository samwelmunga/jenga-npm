#!/usr/bin/env bats
#
# E71_S02_T02: scripts/atlassian-write-marker.sh is the only writer of the Atlassian marker, and it never records
# a claim the gate (scripts/atlassian-configured.sh) cannot confirm.
#
# Every case builds its own scratch project under $BATS_TEST_TMPDIR and points JENGA_PROJECT_ROOT at it, so the
# real project marker and .mcp.json are never read or written. The MCP server identity comes from a fixture
# descriptor (JENGA_ATLASSIAN_DESCRIPTOR); acli is a stub on PATH. Network tools are stubbed with a sentinel and
# teardown() asserts none was called.
#
# Mirror safety: depends only on scripts/atlassian-write-marker.sh, scripts/atlassian-configured.sh,
# scripts/resolve-root.sh, scripts/with-lock.sh and fixtures built here.

bats_require_minimum_version 1.5.0
load helpers/assertions

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
WRITER="$REPO_ROOT/scripts/atlassian-write-marker.sh"
GATE="$REPO_ROOT/scripts/atlassian-configured.sh"
MARKER_REL="project/configs/atlassian.json"

setup() {
  unset JENGA_ATLASSIAN_DESCRIPTOR JENGA_ATLASSIAN_ACLI_TIMEOUT ACLI_STUB_MODE
  SCRATCH="$BATS_TEST_TMPDIR/proj"
  CONFIGS="$SCRATCH/project/configs"
  MARKER="$SCRATCH/$MARKER_REL"
  mkdir -p "$CONFIGS"
  printf '{"paths":{"configs":"project/configs"}}\n' > "$CONFIGS/workflow.json"
  export JENGA_PROJECT_ROOT="$SCRATCH"

  DESC="$BATS_TEST_TMPDIR/atlassian-cloud.json"
  printf '{"register_mcp":{"supported":true,"name":"atlassian-fixture","type":"http","url":"https://mcp.atlassian.example/v1/mcp"}}\n' > "$DESC"
  export JENGA_ATLASSIAN_DESCRIPTOR="$DESC"

  NET_SENTINEL="$BATS_TEST_TMPDIR/network-was-called"
  NETBIN="$BATS_TEST_TMPDIR/netbin"
  mkdir -p "$NETBIN"
  local t
  for t in curl wget nc ncat telnet ssh scp ftp dig nslookup host ping; do
    printf '#!/bin/sh\necho "%s $*" >> "%s"\nexit 1\n' "$t" "$NET_SENTINEL" > "$NETBIN/$t"
    chmod +x "$NETBIN/$t"
  done

  ACLIBIN="$BATS_TEST_TMPDIR/aclibin"
  mkdir -p "$ACLIBIN"
  cat > "$ACLIBIN/acli" <<'EOF'
#!/bin/sh
case "${ACLI_STUB_MODE:-ok}" in
  ok) exit 0 ;;
  unauth) exit 1 ;;
esac
exit 2
EOF
  chmod +x "$ACLIBIN/acli"

  PATH="$NETBIN:$PATH"
  export PATH
}

teardown() {
  [ ! -e "$NET_SENTINEL" ]
}

write_mcp_entry() {
  printf '{"mcpServers":{"other":{"type":"stdio","command":"x"},"atlassian-fixture":{"type":"http","url":"https://mcp.atlassian.example/v1/mcp"}}}\n' > "$SCRATCH/.mcp.json"
}

# configs_listing: the sorted entries in the configs dir, used to prove nothing (not even a temp file) was left.
configs_listing() {
  ls -A "$CONFIGS" | sort | tr '\n' ' '
}

# run_writer <args...>: run the writer capturing stdout in $output and stderr in $stderr.
run_writer() {
  run --separate-stderr bash "$WRITER" "$@"
}

# valid_mcp [extra args]: a complete, valid MCP invocation.
valid_mcp() {
  run_writer --transport mcp --deployment cloud --site https://example.atlassian.net --products jira,confluence "$@"
}

run_gate() {
  run --separate-stderr bash "$GATE"
}

# --- happy path ---------------------------------------------------------------------------------------------

@test "valid MCP arguments with a confirmable connection: writes exactly the five fields and the gate reports configured" {
  write_mcp_entry
  valid_mcp
  [ "$status" -eq 0 ]
  [ -z "$stderr" ]
  [ -f "$MARKER" ]
  [ "$(jq -r 'keys | join(",")' "$MARKER")" = "deployment,enabled,products,site_base_url,transport" ]
  jq -e '.enabled == true and .transport == "mcp" and .deployment == "cloud"
         and .site_base_url == "https://example.atlassian.net" and .products == ["jira","confluence"]' "$MARKER" >/dev/null
  echo "$output" | jq -e '.written == true and .enabled == true' >/dev/null

  run_gate
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.configured == true and .transport == "mcp"' >/dev/null
}

@test "valid CLI arguments with an authenticated acli: written, and the gate reports configured via cli" {
  export PATH="$ACLIBIN:$PATH"
  export ACLI_STUB_MODE=ok
  run_writer --transport cli --deployment datacenter --site https://jira.corp.example/jira --products jira
  [ "$status" -eq 0 ]
  jq -e '.enabled == true and .transport == "cli" and .deployment == "datacenter"
         and .site_base_url == "https://jira.corp.example/jira" and .products == ["jira"]' "$MARKER" >/dev/null

  run_gate
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.configured == true and .transport == "cli"' >/dev/null
}

@test "products are stored de-duplicated in canonical order; a trailing slash on the site is stripped" {
  write_mcp_entry
  run_writer --transport mcp --deployment cloud --site https://example.atlassian.net/// --products bitbucket,jira,bitbucket,confluence
  [ "$status" -eq 0 ]
  jq -e '.products == ["jira","confluence","bitbucket"] and .site_base_url == "https://example.atlassian.net"' "$MARKER" >/dev/null
}

@test "leaves no temp file or lock behind in the configs directory" {
  write_mcp_entry
  valid_mcp
  [ "$status" -eq 0 ]
  [ "$(configs_listing)" = "atlassian.json workflow.json " ]
}

# --- idempotence --------------------------------------------------------------------------------------------

@test "running twice with identical arguments leaves identical content and exits 0 both times" {
  write_mcp_entry
  valid_mcp
  [ "$status" -eq 0 ]
  cp "$MARKER" "$BATS_TEST_TMPDIR/first.json"
  valid_mcp
  [ "$status" -eq 0 ]
  cmp "$MARKER" "$BATS_TEST_TMPDIR/first.json"
  [ "$(configs_listing)" = "atlassian.json workflow.json " ]
}

@test "different arguments replace the marker (the file is not append-only or sticky)" {
  write_mcp_entry
  valid_mcp
  [ "$status" -eq 0 ]
  run_writer --transport mcp --deployment cloud --site https://other.atlassian.net --products confluence
  [ "$status" -eq 0 ]
  jq -e '.site_base_url == "https://other.atlassian.net" and .products == ["confluence"]' "$MARKER" >/dev/null
}

# --- argument validation: exit 2 and nothing written ---------------------------------------------------------

assert_nothing_written() {
  [ ! -e "$MARKER" ]
  [ "$(configs_listing)" = "workflow.json " ]
}

@test "rejects an unknown product and writes nothing" {
  write_mcp_entry
  run_writer --transport mcp --deployment cloud --site https://example.atlassian.net --products jira,trello
  [ "$status" -eq 2 ]
  [ -n "$stderr" ]
  assert_nothing_written
}

@test "rejects an empty product list and a malformed one (empty items) and writes nothing" {
  write_mcp_entry
  run_writer --transport mcp --deployment cloud --site https://example.atlassian.net --products ""
  [ "$status" -eq 2 ]
  run_writer --transport mcp --deployment cloud --site https://example.atlassian.net --products "jira,,confluence"
  [ "$status" -eq 2 ]
  run_writer --transport mcp --deployment cloud --site https://example.atlassian.net --products "jira,"
  [ "$status" -eq 2 ]
  assert_nothing_written
}

@test "rejects a bad deployment and writes nothing" {
  write_mcp_entry
  run_writer --transport mcp --deployment hybrid --site https://example.atlassian.net --products jira
  [ "$status" -eq 2 ]
  assert_nothing_written
}

@test "rejects a bad transport and writes nothing" {
  write_mcp_entry
  run_writer --transport pigeon --deployment cloud --site https://example.atlassian.net --products jira
  [ "$status" -eq 2 ]
  assert_nothing_written
}

@test "rejects a non-https site (http, ftp, bare host) and writes nothing" {
  write_mcp_entry
  local site
  for site in http://example.atlassian.net ftp://example.atlassian.net example.atlassian.net https:// "https:///path"; do
    run_writer --transport mcp --deployment cloud --site "$site" --products jira
    [ "$status" -eq 2 ]
  done
  assert_nothing_written
}

@test "rejects a credential-bearing, query-bearing, fragment-bearing or whitespace site and writes nothing" {
  write_mcp_entry
  local site
  for site in "https://user:s3cr3tvalue@example.atlassian.net" "https://s3cr3tvalue@example.atlassian.net" \
              "https://example.atlassian.net?token=s3cr3tvalue" "https://example.atlassian.net/#s3cr3tvalue" \
              "https://example.atlassian.net/a b" "https://exa mple.atlassian.net"; do
    run_writer --transport mcp --deployment cloud --site "$site" --products jira
    [ "$status" -eq 2 ]
    assert_not_contains "$stderr" "s3cr3tvalue"
    assert_output_not_contains "s3cr3tvalue"
  done
  assert_nothing_written
}

@test "rejects a missing required option, an unknown option and a positional argument; nothing written" {
  write_mcp_entry
  run_writer --transport mcp --deployment cloud --site https://example.atlassian.net
  [ "$status" -eq 2 ]
  assert_contains "$stderr" "--products"
  run_writer --deployment cloud --site https://example.atlassian.net --products jira
  [ "$status" -eq 2 ]
  run_writer --transport mcp --deployment cloud --site https://example.atlassian.net --products jira --bogus x
  [ "$status" -eq 2 ]
  run_writer --transport mcp --deployment cloud --site https://example.atlassian.net --products jira stray
  [ "$status" -eq 2 ]
  run_writer --transport
  [ "$status" -eq 2 ]
  assert_nothing_written
}

@test "accepts and echoes no secret: a credential option is rejected naming only the flag" {
  write_mcp_entry
  run_writer --transport mcp --deployment cloud --site https://example.atlassian.net --products jira --token=s3cr3tvalue
  [ "$status" -eq 2 ]
  assert_contains "$stderr" "--token"
  assert_not_contains "$stderr" "s3cr3tvalue"
  run_writer --transport mcp --deployment cloud --site https://example.atlassian.net --products jira --api-key s3cr3tvalue
  [ "$status" -eq 2 ]
  assert_not_contains "$stderr" "s3cr3tvalue"
  assert_nothing_written
}

@test "a refused run does not touch an existing marker" {
  write_mcp_entry
  valid_mcp
  [ "$status" -eq 0 ]
  cp "$MARKER" "$BATS_TEST_TMPDIR/before.json"
  run_writer --transport mcp --deployment cloud --site http://nope.example --products jira
  [ "$status" -eq 2 ]
  cmp "$MARKER" "$BATS_TEST_TMPDIR/before.json"
}

# --- verify before claiming: exit 3 and nothing written -------------------------------------------------------

@test "MCP: refuses to claim enabled:true when the server entry is not in .mcp.json" {
  printf '{"mcpServers":{"other":{"type":"stdio","command":"x"}}}\n' > "$SCRATCH/.mcp.json"
  valid_mcp
  [ "$status" -eq 3 ]
  assert_contains "$stderr" "not confirmed"
  assert_contains "$stderr" "no marker written"
  assert_nothing_written
}

@test "MCP: refuses when .mcp.json does not exist at all" {
  [ ! -e "$SCRATCH/.mcp.json" ]
  valid_mcp
  [ "$status" -eq 3 ]
  assert_nothing_written
}

@test "CLI: refuses when acli is not authenticated" {
  export PATH="$ACLIBIN:$PATH"
  export ACLI_STUB_MODE=unauth
  run_writer --transport cli --deployment cloud --site https://example.atlassian.net --products jira
  [ "$status" -eq 3 ]
  assert_contains "$stderr" "not confirmed"
  assert_nothing_written
}

@test "a refused confirmation leaves an existing marker untouched" {
  write_mcp_entry
  valid_mcp
  [ "$status" -eq 0 ]
  cp "$MARKER" "$BATS_TEST_TMPDIR/before.json"
  rm -f "$SCRATCH/.mcp.json"
  valid_mcp
  [ "$status" -eq 3 ]
  cmp "$MARKER" "$BATS_TEST_TMPDIR/before.json"
}

# --- --disable ----------------------------------------------------------------------------------------------

@test "--disable round-trips: the marker becomes enabled:false and the gate reports not configured" {
  write_mcp_entry
  valid_mcp
  [ "$status" -eq 0 ]
  run_writer --disable
  [ "$status" -eq 0 ]
  jq -e '.enabled == false and .transport == "mcp" and .site_base_url == "https://example.atlassian.net"
         and .products == ["jira","confluence"] and .deployment == "cloud"' "$MARKER" >/dev/null
  [ "$(jq -r 'keys | join(",")' "$MARKER")" = "deployment,enabled,products,site_base_url,transport" ]

  run_gate
  [ "$status" -eq 1 ]
  [ -z "$stderr" ]
  echo "$output" | jq -e '.configured == false' >/dev/null
  assert_output_contains "not configured"
}

@test "--disable needs no confirmation (works with the MCP entry already gone)" {
  write_mcp_entry
  valid_mcp
  [ "$status" -eq 0 ]
  rm -f "$SCRATCH/.mcp.json"
  run_writer --disable
  [ "$status" -eq 0 ]
  jq -e '.enabled == false' "$MARKER" >/dev/null
}

@test "--disable with full arguments writes a disabled marker without any existing one or any connection" {
  run_writer --disable --transport cli --deployment cloud --site https://example.atlassian.net --products jira
  [ "$status" -eq 0 ]
  jq -e '.enabled == false and .transport == "cli"' "$MARKER" >/dev/null
  run_gate
  [ "$status" -eq 1 ]
  assert_output_contains "not configured"
}

@test "--disable with no marker and no arguments: nothing to disable, exit 0, nothing written" {
  run_writer --disable
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.written == false' >/dev/null
  assert_nothing_written
}

@test "--disable still validates what it is given" {
  run_writer --disable --site http://nope.example
  [ "$status" -eq 2 ]
  assert_nothing_written
}

@test "--disable is idempotent" {
  write_mcp_entry
  valid_mcp
  [ "$status" -eq 0 ]
  run_writer --disable
  [ "$status" -eq 0 ]
  cp "$MARKER" "$BATS_TEST_TMPDIR/first.json"
  run_writer --disable
  [ "$status" -eq 0 ]
  cmp "$MARKER" "$BATS_TEST_TMPDIR/first.json"
}

# --- the gate's --check-transport mode (the shared confirmation the writer relies on) -------------------------

@test "gate --check-transport mcp: confirmed with no marker present; JSON has configured, reason, transport only" {
  write_mcp_entry
  [ ! -e "$MARKER" ]
  run --separate-stderr bash "$GATE" --check-transport mcp
  [ "$status" -eq 0 ]
  [ -z "$stderr" ]
  echo "$output" | jq -e '.configured == true and .transport == "mcp"' >/dev/null
  [ "$(echo "$output" | jq -r 'keys | join(",")')" = "configured,reason,transport" ]
}

@test "gate --check-transport: not confirmed gives exit 1 with a 'not confirmed' reason (not marker drift); a malformed marker is ignored" {
  printf 'not json at all' > "$MARKER"
  run --separate-stderr bash "$GATE" --check-transport mcp
  [ "$status" -eq 1 ]
  [ -z "$stderr" ]
  echo "$output" | jq -e '.configured == false' >/dev/null
  assert_output_contains "not confirmed"
  assert_output_not_contains "marker drift"
}

@test "gate --check-transport cli: confirmed with an authenticated acli, refused when unauthenticated" {
  export PATH="$ACLIBIN:$PATH"
  export ACLI_STUB_MODE=ok
  run --separate-stderr bash "$GATE" --check-transport cli
  [ "$status" -eq 0 ]
  export ACLI_STUB_MODE=unauth
  run --separate-stderr bash "$GATE" --check-transport cli
  [ "$status" -eq 1 ]
  assert_output_contains "not confirmed"
}

@test "gate --check-transport with a missing or invalid transport: exit 1, one JSON object, never a crash" {
  run --separate-stderr bash "$GATE" --check-transport
  [ "$status" -eq 1 ]
  echo "$output" | jq -e '.configured == false' >/dev/null
  run --separate-stderr bash "$GATE" --check-transport pigeon
  [ "$status" -eq 1 ]
  [ "$(echo "$output" | jq -s 'length')" = "1" ]
}

# --- static properties ----------------------------------------------------------------------------------------

@test "the writer resolves the marker via resolve-root.sh, writes under with-lock.sh and hardcodes no project/ path" {
  run grep -n 'resolve-root.sh' "$WRITER"
  [ "$status" -eq 0 ]
  run grep -n 'with-lock.sh' "$WRITER"
  [ "$status" -eq 0 ]
  run bash -c 'grep -v -E "^[[:space:]]*#" "$1" | grep -n -E "(^|[^A-Za-z_./-])[.]?project/"' _ "$WRITER"
  [ "$status" -eq 1 ]
}

@test "the writer header documents the interface and the do-not-edit-by-hand rule" {
  run grep -n -i 'DO NOT EDIT THE MARKER BY HAND' "$WRITER"
  [ "$status" -eq 0 ]
  run grep -n -E -- '--transport.*--deployment|--disable' "$WRITER"
  [ "$status" -eq 0 ]
}

@test "the marker never contains a secret-looking key or value, whatever the arguments" {
  write_mcp_entry
  valid_mcp
  [ "$status" -eq 0 ]
  run grep -i -E 'token|password|secret|credential|api[_-]?key' "$MARKER"
  [ "$status" -eq 1 ]
  [ "$(jq -r 'keys | length' "$MARKER")" = "5" ]
}

@test "the writer is executable" {
  [ -x "$WRITER" ]
}
