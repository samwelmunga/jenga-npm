#!/usr/bin/env bats
#
# Figma-specific coverage of the j.connect runner (E65_S06_T04), run against the real
# skills/j-connect/descriptors/figma.json with a STUBBED `claude` on PATH. Generic runner
# mechanics are covered in run-descriptor.bats, register-mcp.bats, ensure-secret-safe.bats
# and connect-e2e.bats; this file only adds what the Figma story promises on top: the
# duplicate-connection check ("detect and report"). Argv, URLs and names are read from the
# descriptor with jq rather than copied here, so the file follows whichever design the
# descriptor has.
#
# The `claude` stub answers `claude mcp get <name>`: exit 0 iff $STUB/connected exists AND the
# name asked for equals the connected name stored in that file (default "claude.ai Figma");
# otherwise exit 1. It records every call, prints a sentinel to stdout and stderr, and records
# (in claude-write.log) any `add`, `remove` or `reset` call, which must never happen. The real
# `claude` CLI is never invoked. Installers are log-only stubs. No Figma account, network,
# token or ~/.claude.json file is ever touched.
#
# What this models, per project/documentation/figma-expo-connect-research.md section A3:
#   (i)   claude.ai connector: the stub is "connected" under the exact name "claude.ai Figma"
#         (what a real `claude mcp get "claude.ai Figma"` was observed to resolve);
#   (ii)  project .mcp.json entry / (iii) user-local scope or plugin server: modelled as the
#         stub being connected under a DIFFERENT name ("figma"), which the descriptor's single
#         probe does not see; asserted as a documented limit, not as a feature.
# What a stub CANNOT prove, and is therefore NOT asserted here (research doc, "Could not verify"):
#   - the real `claude mcp get` behaviour for a claude.ai connector, its exact name string on
#     other machines or versions, or its exit status for a server needing authentication;
#   - the registered name of the Figma plugin's server;
#   - real Figma OAuth in Claude Code, or that exit 0 means "authorised" (it means "configured");
#   - an end-to-end run against a real Figma account and the real connector: a human check,
#     NOT done by this file (not verifiable here: no Figma account or tooling).

# Each @test runs in its own subshell, so per-test env changes are intentional.
# shellcheck disable=SC2030,SC2031
bats_require_minimum_version 1.5.0
load helpers/assertions

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
RUN="$REPO_ROOT/skills/j-connect/scripts/run-descriptor.sh"
FIGMA_DESC="$REPO_ROOT/skills/j-connect/descriptors/figma.json"
# A shape unlikely to match a real token or the validator's credential heuristics.
SENTINEL="FAKESENTINELFIGMA_0123456789abcdefABCDEF"

setup() {
  STUB="$BATS_TEST_TMPDIR/stub"
  FAKE_BIN="$BATS_TEST_TMPDIR/bin"
  PROJ="$BATS_TEST_TMPDIR/proj"
  mkdir -p "$STUB" "$FAKE_BIN" "$PROJ"
  git -C "$PROJ" init -q .

  CONNECTED_NAME="claude.ai Figma"
  # claude: `mcp get <name>` is judged by exit status; add/remove/reset are recorded as forbidden.
  cat > "$FAKE_BIN/claude" <<EOS
#!/bin/sh
echo "claude \$*" >> "$STUB/claude.log"
echo "token: $SENTINEL"; echo "token: $SENTINEL" >&2
if [ "\$1" = "mcp" ]; then
  case "\$2" in
    get)
      echo x >> "$STUB/get.count"
      [ -e "$STUB/connected" ] && [ "\$3" = "\$(cat "$STUB/connected")" ] && exit 0
      exit 1 ;;
    add|remove|reset) echo "claude \$*" >> "$STUB/claude-write.log"; exit 0 ;;
  esac
fi
exit 0
EOS
  # Installers only record that they were called.
  local t
  for t in brew npm apt apt-get dnf yum pacman snap scoop curl wget sudo; do
    printf '#!/bin/sh\necho "%s $*" >> "%s/installer.log"\nexit 0\n' "$t" "$STUB" > "$FAKE_BIN/$t"
  done
  chmod +x "$FAKE_BIN"/*

  export PATH="$FAKE_BIN:$PATH"
  export JENGA_CONNECT_PLATFORM=darwin
  DOCS_INSTALL="$(jq -r '.install.docs_url' "$FIGMA_DESC")"
}

go() { run --separate-stderr bash "$RUN" "$FIGMA_DESC" --project-root "$PROJ" "$@"; }
# connect <name>: make the stub report a Figma server connected under <name>.
connect() { printf '%s' "${1:-$CONNECTED_NAME}" > "$STUB/connected"; }
step_status() { jq -r --arg s "$1" 'select(.step == $s) | .status' <<<"$output" | head -n1; }
step_message() { jq -r --arg s "$1" 'select(.step == $s) | .message' <<<"$output" | head -n1; }
step_detail() { jq -r --arg s "$1" 'select(.step == $s) | .detail // empty' <<<"$output" | head -n1; }
step_count() { jq -r --arg s "$1" 'select(.step == $s) | .status' <<<"$output" | wc -l | tr -d ' '; }
get_calls() { if [ -f "$STUB/get.count" ]; then wc -l < "$STUB/get.count" | tr -d ' '; else echo 0; fi; }
# project_files: every file in the project besides .git
project_files() { find "$PROJ" -path "$PROJ/.git" -prune -o -type f -print | sed "s|$PROJ/||"; }

@test "the descriptor is detect-and-report: the probe is claude mcp get for the connector name, register_mcp is unsupported" {
  # If the design ever changes to a registering descriptor, the registration tests below
  # (not just this one) must be rewritten, so fail loudly first.
  [ "$(jq -r '.register_mcp.supported' "$FIGMA_DESC")" = "false" ]
  [ "$(jq -c '.detect.command[0:3]' "$FIGMA_DESC")" = '["claude","mcp","get"]' ]
  [ "$(jq -c '.verify.command' "$FIGMA_DESC")" = "$(jq -c '.detect.command' "$FIGMA_DESC")" ]
  [ "$(jq -r '.auth.type' "$FIGMA_DESC")" = "none" ]
}

@test "already connected (claude.ai connector): exit 0, detect pass/present, install skipped, nothing registered or written, no installer, no claude add/remove" {
  connect
  go
  [ "$status" -eq 0 ]
  [ "$(step_status detect)" = "pass" ]
  [ "$(step_detail detect)" = "present" ]
  [ "$(step_status install)" = "skipped" ]
  assert_contains "$(step_message install)" "already installed"
  [ "$(step_status auth)" = "skipped" ]
  [ "$(step_status register_mcp)" = "skipped" ]
  assert_contains "$(step_message register_mcp)" "no MCP server"
  [ "$(step_status verify)" = "pass" ]
  [ "$(jq -r 'select(.summary == true) | .status' <<<"$output")" = "pass" ]
  # the duplicate-connection check: no .mcp.json is created, nothing at all lands in the project
  [ ! -e "$PROJ/.mcp.json" ]
  [ -z "$(project_files)" ]
  [ ! -e "$STUB/installer.log" ]
  [ ! -e "$STUB/claude-write.log" ]
  # the probe is called exactly as the descriptor says (detect and verify: two calls)
  probe="$(jq -r '.detect.command | join(" ")' "$FIGMA_DESC")"
  [ "$(grep -cFx "$probe" "$STUB/claude.log")" -eq 2 ]
  [ "$(get_calls)" -eq 2 ]
  # re-running changes nothing
  go
  [ "$status" -eq 0 ]
  [ -z "$(project_files)" ]
  [ ! -e "$STUB/claude-write.log" ]
}

@test "already connected and the project .mcp.json already holds a figma entry: the file stays byte-identical, other servers and top-level keys preserved" {
  connect
  printf '%s\n' '{"mcpServers":{"figma":{"type":"http","url":"https://mcp.figma.com/mcp"},"other":{"type":"stdio","command":"/usr/bin/true","args":[]}},"someTopLevelKey":{"keep":true}}' > "$PROJ/.mcp.json"
  sum="$(cksum < "$PROJ/.mcp.json")"
  go
  [ "$status" -eq 0 ]
  [ "$(step_status register_mcp)" = "skipped" ]
  [ "$(cksum < "$PROJ/.mcp.json")" = "$sum" ]
  [ "$(jq -c '.mcpServers.figma' "$PROJ/.mcp.json")" = '{"type":"http","url":"https://mcp.figma.com/mcp"}' ]
  [ "$(jq -c '.mcpServers.other' "$PROJ/.mcp.json")" = '{"type":"stdio","command":"/usr/bin/true","args":[]}' ]
  [ "$(jq -c '.someTopLevelKey' "$PROJ/.mcp.json")" = '{"keep":true}' ]
  [ "$(project_files)" = ".mcp.json" ]
  [ ! -e "$STUB/claude-write.log" ]
}

@test "not connected: stops at install with needs-user-action (exit 3), prints the official Figma docs URL, calls no installer, writes nothing" {
  go
  [ "$status" -eq 3 ]
  [ "$(step_status detect)" = "pass" ]
  [ "$(step_detail detect)" = "absent" ]
  [ "$(step_status install)" = "needs-user-action" ]
  assert_contains "$(step_message install)" "$DOCS_INSTALL"
  [ "$(step_count auth)" -eq 0 ]
  [ "$(step_count register_mcp)" -eq 0 ]
  [ "$(step_count verify)" -eq 0 ]
  [ "$(jq -r 'select(.summary == true) | .status' <<<"$output")" = "needs-user-action" ]
  [ ! -e "$PROJ/.mcp.json" ]
  [ -z "$(project_files)" ]
  [ ! -e "$STUB/installer.log" ]
  [ ! -e "$STUB/claude-write.log" ]
}

@test "not connected with --continue: register_mcp is still skipped (detect and report, never a registration), no .mcp.json, verify fails" {
  go --continue
  [ "$status" -eq 1 ]
  [ "$(step_status install)" = "needs-user-action" ]
  [ "$(step_status register_mcp)" = "skipped" ]
  assert_contains "$(step_message register_mcp)" "no MCP server"
  [ "$(step_status verify)" = "fail" ]
  [ ! -e "$PROJ/.mcp.json" ]
  [ -z "$(project_files)" ]
  [ ! -e "$STUB/claude-write.log" ]
}

@test "documented limit: a Figma server connected under a different name (project .mcp.json, user/local scope or plugin) is NOT seen by the single probe, so the run reports absent and still registers nothing" {
  # Models cases (ii) and (iii) from the research doc: the stub is connected as "figma",
  # the descriptor probes "claude.ai Figma". Safe failure mode: docs guidance, no write.
  connect figma
  go
  [ "$status" -eq 3 ]
  [ "$(step_detail detect)" = "absent" ]
  [ "$(step_status install)" = "needs-user-action" ]
  assert_contains "$(step_message install)" "$DOCS_INSTALL"
  [ -z "$(project_files)" ]
  [ ! -e "$STUB/claude-write.log" ]
  # and the free text tells the user so
  assert_contains "$(jq -r '.install.hint' "$FIGMA_DESC")" "another name"
}

@test "verify runs its probe independently: flipping the stub to not connected after earlier steps passed makes verify fail (exit 1)" {
  connect
  go
  [ "$status" -eq 0 ]
  [ "$(step_status verify)" = "pass" ]
  before="$(get_calls)"

  rm -f "$STUB/connected"
  go --step verify
  [ "$status" -eq 1 ]
  [ "$(step_status verify)" = "fail" ]
  [ "$(get_calls)" -gt "$before" ]
  # only the verify step ran: it did not lean on a stored detect result
  [ "$(step_count detect)" -eq 0 ]
  [ "$(jq -r 'select(.summary == true) | .status' <<<"$output")" = "fail" ]
}

@test "unknown platform with nothing connected: needs-user-action with the official docs URL; no installer is ever called, even with --allow-install" {
  export JENGA_CONNECT_PLATFORM=plan9
  go
  [ "$status" -eq 3 ]
  [ "$(step_detail detect)" = "absent" ]
  [ "$(step_status install)" = "needs-user-action" ]
  assert_contains "$(step_message install)" "$DOCS_INSTALL"
  [ ! -e "$STUB/installer.log" ]

  go --allow-install
  [ "$status" -eq 3 ]
  [ "$(step_status install)" = "needs-user-action" ]
  assert_contains "$(step_message install)" "$DOCS_INSTALL"
  [ ! -e "$STUB/installer.log" ]
  [ ! -e "$STUB/claude-write.log" ]
}

@test "no install methods are declared, so even a known platform with --allow-install runs no installer and falls back to the docs URL" {
  [ "$(jq '.install | has("methods")' "$FIGMA_DESC")" = "false" ]
  go --allow-install
  [ "$status" -eq 3 ]
  [ "$(step_status install)" = "needs-user-action" ]
  assert_contains "$(step_message install)" "$DOCS_INSTALL"
  [ ! -e "$STUB/installer.log" ]
}

@test "no token leak: the sentinel printed by the stub never reaches runner output, any project file or the descriptor; the descriptor declares no env var or secret" {
  [ "$(jq 'has("secrets")' "$FIGMA_DESC")" = "false" ]
  local mode
  for mode in not-connected connected; do
    rm -f "$STUB/connected"
    if [ "$mode" = "connected" ]; then connect; fi
    go --continue
    [ "$(get_calls)" -ge 1 ]
    run grep -F "$SENTINEL" <<<"$output"
    [ "$status" -eq 1 ]
    run grep -F "$SENTINEL" <<<"$stderr"
    [ "$status" -eq 1 ]
    run grep -rF "$SENTINEL" "$PROJ"
    [ "$status" -eq 1 ]
  done
  # the stub did print it (the sentinel is real), and the descriptor holds no token value
  [ -f "$STUB/get.count" ]
  run grep -F "$SENTINEL" "$FIGMA_DESC"
  [ "$status" -eq 1 ]
}
