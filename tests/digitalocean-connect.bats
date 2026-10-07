#!/usr/bin/env bats
#
# DigitalOcean-specific coverage of the j.connect runner (E65_S05_T03), run
# against the real skills/j-connect/descriptors/digitalocean.json with a STUBBED
# `doctl` on PATH. Generic runner mechanics are covered in run-descriptor.bats,
# register-mcp.bats, ensure-secret-safe.bats and connect-e2e.bats; this file only
# adds what the DigitalOcean story promises on top. Argv, URLs, names and package
# names are read from the descriptor with jq rather than copied here.
#
# The `doctl` stub counts calls, has independently switchable presence
# ($STUB/absent), `doctl version` result ($STUB/version-fails) and authenticated
# no-op `doctl account get` result ($STUB/authed), records `doctl auth init`
# without doing anything, prints a sentinel "token" to stdout and stderr, and
# also echoes the value of DIGITALOCEAN_ACCESS_TOKEN when that is set.
# Installers are log-only stubs (the brew stub also "installs" the stub CLI).
# doctl is not installed on the authoring machine; no real doctl, network,
# DigitalOcean account, token or ~/.config/doctl file is ever touched.
#
# What a stub CANNOT prove, and is therefore NOT asserted here
# (project/documentation/digitalocean-connect-research.md, "Could not verify"):
#   - real `doctl auth init` behaviour, where doctl stores the token, or that
#     DIGITALOCEAN_ACCESS_TOKEN is honoured by the current doctl;
#   - that `doctl account get` really exits non-zero when logged out, or that
#     `doctl version` works unauthenticated;
#   - that the hosted Droplets MCP endpoint loads in Claude Code or completes its
#     OAuth consent;
#   - that the `doctl` Homebrew formula still exists, or that Homebrew on Linux works.
# The story's "end-to-end run on a real DigitalOcean account" item is a human
# check and is NOT done by this file (not verifiable here: no doctl, no account).
#
# Design choice recorded here: the descriptor uses auth.type browser (the user runs
# `doctl auth init` themselves; the token lives in doctl's own credential store),
# has no `secrets` block and a token-free hosted OAuth MCP entry, so the runner
# never creates an env file and the pre-write .gitignore guardrail
# (ensure-secret-safe.sh) never runs for this descriptor. The guardrail test
# therefore asserts that no env file or .gitignore is created in ANY scenario, and
# fails loudly if the descriptor ever grows an env-token design (the ordering of
# the guardrail before an env-file write is covered generically in
# ensure-secret-safe.bats and run-descriptor.bats).

# Each @test runs in its own subshell, so per-test env changes are intentional.
# shellcheck disable=SC2030,SC2031
bats_require_minimum_version 1.5.0
load helpers/assertions

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
RUN="$REPO_ROOT/skills/j-connect/scripts/run-descriptor.sh"
DO_DESC="$REPO_ROOT/skills/j-connect/descriptors/digitalocean.json"
# A shape unlikely to match a real DigitalOcean token or the validator's credential heuristics.
SENTINEL="FAKESENTINELDO_0123456789abcdefABCDEF"

setup() {
  STUB="$BATS_TEST_TMPDIR/stub"
  FAKE_BIN="$BATS_TEST_TMPDIR/bin"
  BREW_BIN="$BATS_TEST_TMPDIR/brewbin"
  LEAN_BIN="$BATS_TEST_TMPDIR/lean"
  PROJ="$BATS_TEST_TMPDIR/proj"
  mkdir -p "$STUB" "$FAKE_BIN" "$BREW_BIN" "$LEAN_BIN" "$PROJ"
  git -C "$PROJ" init -q .

  # doctl: absent iff $STUB/absent exists; `version` fails iff $STUB/version-fails;
  # `account get` succeeds iff $STUB/authed; always prints the sentinel (and the
  # env token if set); counts calls.
  cat > "$FAKE_BIN/doctl" <<EOS
#!/bin/sh
[ -e "$STUB/absent" ] && exit 127
echo "doctl \$*" >> "$STUB/doctl.log"
case "\$1" in
  version)
    echo "doctl version 0.0.0-stub (token: $SENTINEL \${DIGITALOCEAN_ACCESS_TOKEN:-})"; echo "token: $SENTINEL" >&2
    [ -e "$STUB/version-fails" ] && exit 1
    exit 0 ;;
  auth) touch "$STUB/auth-init-called"; exit 0 ;;
  account)
    if [ "\$2" = "get" ]; then
      echo x >> "$STUB/noop.count"
      echo "account (token: $SENTINEL \${DIGITALOCEAN_ACCESS_TOKEN:-})"
      echo "token: $SENTINEL" >&2
      [ -e "$STUB/authed" ] && exit 0
      exit 1
    fi ;;
esac
exit 0
EOS
  # gh is never needed by digitalocean; if anything calls it, it fails and is logged.
  printf '#!/bin/sh\necho "gh $*" >> "%s/gh.log"\nexit 1\n' "$STUB" > "$FAKE_BIN/gh"
  # Non-brew installers only record that they were called.
  local t
  for t in npm apt apt-get dnf yum pacman snap scoop curl wget sudo; do
    printf '#!/bin/sh\necho "%s $*" >> "%s/installer.log"\nexit 0\n' "$t" "$STUB" > "$FAKE_BIN/$t"
  done
  # brew records the call and, on `install`, makes the stub CLI appear.
  cat > "$BREW_BIN/brew" <<EOS
#!/bin/sh
echo "brew \$*" >> "$STUB/installer.log"
[ "\$1" = "install" ] && rm -f "$STUB/absent"
exit 0
EOS
  chmod +x "$FAKE_BIN"/* "$BREW_BIN"/*

  # A PATH with no brew at all (the maintainer's real brew lives next to jq, so
  # symlink just the tools the runner needs instead of excluding a directory).
  local tool
  for tool in jq bash git; do ln -s "$(command -v "$tool")" "$LEAN_BIN/$tool"; done

  export PATH="$FAKE_BIN:$BREW_BIN:$PATH"
  export LEAN_PATH="$FAKE_BIN:$LEAN_BIN:/usr/bin:/bin:/usr/sbin:/sbin"
  export JENGA_CONNECT_PLATFORM=darwin
  unset DIGITALOCEAN_ACCESS_TOKEN DIGITALOCEAN_API_TOKEN
  DOCS_INSTALL="$(jq -r '.install.docs_url' "$DO_DESC")"
  DOCS_AUTH="$(jq -r '.auth.docs_url' "$DO_DESC")"
}

go() { run --separate-stderr bash "$RUN" "$DO_DESC" --project-root "$PROJ" "$@"; }
# step_status/message/detail <step>: fields of the first matching result line.
step_status() { jq -r --arg s "$1" 'select(.step == $s) | .status' <<<"$output" | head -n1; }
step_message() { jq -r --arg s "$1" 'select(.step == $s) | .message' <<<"$output" | head -n1; }
step_detail() { jq -r --arg s "$1" 'select(.step == $s) | .detail // empty' <<<"$output" | head -n1; }
step_count() { jq -r --arg s "$1" 'select(.step == $s) | .status' <<<"$output" | wc -l | tr -d ' '; }
noop_calls() { if [ -f "$STUB/noop.count" ]; then wc -l < "$STUB/noop.count" | tr -d ' '; else echo 0; fi; }

@test "already installed and authenticated via doctl's own store: satisfied steps skip or pass, register_mcp is added then unchanged, nothing installs, no auth init, no env file or other file written" {
  # Authenticated with no env var set and no env file: the CLI's own credential store path.
  touch "$STUB/authed"
  go
  [ "$status" -eq 0 ]
  [ "$(step_status detect)" = "pass" ]
  [ "$(step_detail detect)" = "present" ]
  [ "$(step_status install)" = "skipped" ]
  assert_contains "$(step_message install)" "already installed"
  [ "$(step_status auth)" = "skipped" ]
  assert_contains "$(step_message auth)" "already authenticated"
  [ "$(step_status register_mcp)" = "pass" ]
  [ "$(step_detail register_mcp)" = "added" ]
  [ "$(step_status verify)" = "pass" ]

  go
  [ "$status" -eq 0 ]
  [ "$(step_status register_mcp)" = "skipped" ]
  [ "$(step_detail register_mcp)" = "unchanged" ]
  assert_contains "$(step_message register_mcp)" "already registered"
  [ "$(step_status install)" = "skipped" ]
  [ "$(step_status auth)" = "skipped" ]
  [ "$(jq -r 'select(.summary == true) | .status' <<<"$output")" = "pass" ]
  [ ! -e "$STUB/installer.log" ]
  [ ! -e "$STUB/auth-init-called" ]
  # the only file written to the project besides .git is .mcp.json
  [ "$(find "$PROJ" -path "$PROJ/.git" -prune -o -type f -print | sed "s|$PROJ/||")" = ".mcp.json" ]
}

@test "unauthenticated: stops at auth with needs-user-action (exit 3), shows the descriptor instructions and docs URL, never runs doctl auth init, no later step runs" {
  go
  [ "$status" -eq 3 ]
  [ "$(step_status detect)" = "pass" ]
  [ "$(step_status install)" = "skipped" ]
  [ "$(step_status auth)" = "needs-user-action" ]
  msg="$(step_message auth)"
  assert_contains "$msg" "$(jq -r '.auth.instructions' "$DO_DESC")"
  assert_contains "$msg" "doctl auth init"
  assert_contains "$msg" "$DOCS_AUTH"
  [ "$(step_count register_mcp)" -eq 0 ]
  [ "$(step_count verify)" -eq 0 ]
  [ ! -e "$PROJ/.mcp.json" ]
  [ "$(jq -r 'select(.summary == true) | .status' <<<"$output")" = "needs-user-action" ]
  # the token is entered by the human at doctl's own prompt: the runner never invokes auth
  [ ! -e "$STUB/auth-init-called" ]
  [ "$(grep -c 'auth' "$STUB/doctl.log")" -eq 0 ]
}

@test "verify runs the authenticated no-op itself: a no-op that starts failing makes verify fail (exit 1) even though auth passed earlier" {
  touch "$STUB/authed"
  go
  [ "$status" -eq 0 ]
  [ "$(step_status verify)" = "pass" ]
  before="$(noop_calls)"

  rm -f "$STUB/authed"
  go --step verify
  [ "$status" -eq 1 ]
  [ "$(step_status verify)" = "fail" ]
  [ "$(noop_calls)" -gt "$before" ]
  # only the verify step ran: it did not lean on a stored auth result
  [ "$(step_count auth)" -eq 0 ]
  [ "$(jq -r 'select(.summary == true) | .status' <<<"$output")" = "fail" ]
}

@test "verify and the auth check are the descriptor's authenticated no-op argv, called exactly that way, and detect is the version command" {
  touch "$STUB/authed"
  go
  [ "$status" -eq 0 ]
  noop="$(jq -r '.verify.command | join(" ")' "$DO_DESC")"
  [ "$(jq -r '.auth.check.command | join(" ")' "$DO_DESC")" = "$noop" ]
  # auth check + verify = two calls of the no-op, each logged with that exact argv
  [ "$(grep -cFx "doctl ${noop#doctl }" "$STUB/doctl.log")" -eq 2 ]
  [ "$(noop_calls)" -eq 2 ]
  detect="$(jq -r '.detect.command | join(" ")' "$DO_DESC")"
  [ "$(grep -cFx "doctl ${detect#doctl }" "$STUB/doctl.log")" -ge 1 ]
}

@test "a failing doctl version is treated as not installed (detect is judged by exit status only): install is opt-in, and auth init is never run" {
  # detect is judged by exit status only (stub: `version` fails, so doctl counts as absent).
  touch "$STUB/version-fails" "$STUB/authed"
  go
  [ "$(step_detail detect)" = "absent" ]
  [ "$(step_status install)" = "needs-user-action" ]
  assert_contains "$(step_message install)" "--allow-install"
  [ ! -e "$STUB/auth-init-called" ]
}

@test ".mcp.json registration is idempotent: first added, second unchanged and byte-identical; other servers and top-level keys preserved; entry equals the descriptor shape" {
  touch "$STUB/authed"
  printf '%s\n' '{"mcpServers":{"other":{"type":"stdio","command":"/usr/bin/true","args":[]}},"someTopLevelKey":{"keep":true}}' > "$PROJ/.mcp.json"

  go
  [ "$status" -eq 0 ]
  [ "$(step_detail register_mcp)" = "added" ]
  name="$(jq -r '.register_mcp.name' "$DO_DESC")"
  [ "$(jq -cS --arg n "$name" '.mcpServers[$n]' "$PROJ/.mcp.json")" = "$(jq -cS '{type: .register_mcp.type, url: .register_mcp.url}' "$DO_DESC")" ]
  [ "$(jq -c '.mcpServers.other' "$PROJ/.mcp.json")" = '{"type":"stdio","command":"/usr/bin/true","args":[]}' ]
  [ "$(jq -c '.someTopLevelKey' "$PROJ/.mcp.json")" = '{"keep":true}' ]
  # the hosted OAuth entry carries no env/headers, so there is no token reference at all
  [ "$(jq --arg n "$name" '.mcpServers[$n] | keys | sort' -c "$PROJ/.mcp.json")" = '["type","url"]' ]
  # shellcheck disable=SC2016
  run grep -F '${' "$PROJ/.mcp.json"
  [ "$status" -eq 1 ]

  sum="$(cksum < "$PROJ/.mcp.json")"
  go
  [ "$status" -eq 0 ]
  [ "$(step_detail register_mcp)" = "unchanged" ]
  [ "$(cksum < "$PROJ/.mcp.json")" = "$sum" ]

  # registration goes to .mcp.json only (project/documentation/mcp-registration-decision.md)
  [ ! -e "$PROJ/.claude/settings.json" ]
  [ ! -e "$PROJ/.agents/settings.json" ]
}

@test "the one-endpoint-per-service limit is stated in the descriptor text, since register_mcp registers a single server" {
  [ "$(jq -r '.register_mcp.supported' "$DO_DESC")" = "true" ]
  go
  assert_contains "$(step_message auth)" "one endpoint per service"
}

@test "secrets guardrail: this descriptor can never create an env file or touch .gitignore, in any scenario" {
  # If the descriptor ever gains env-token auth or secrets.env_file, this test must
  # be extended to cover the pre-write .gitignore refusal, so fail loudly first.
  [ "$(jq -r '.auth.type' "$DO_DESC")" = "browser" ]
  [ "$(jq 'has("secrets")' "$DO_DESC")" = "false" ]

  local mode
  for mode in unauthenticated authenticated absent-allow-install; do
    rm -f "$STUB/authed" "$STUB/absent"
    case "$mode" in
      authenticated) touch "$STUB/authed" ;;
      absent-allow-install) touch "$STUB/absent" ;;
    esac
    if [ "$mode" = "absent-allow-install" ]; then go --allow-install; else go; fi
    [ "$(find "$PROJ" -path "$PROJ/.git" -prune -o -name '.env*' -print | wc -l | tr -d ' ')" -eq 0 ]
    # the guardrail never ran, so it did not touch .gitignore either
    [ ! -e "$PROJ/.gitignore" ]
    [ ! -e "$STUB/auth-init-called" ]
  done
}

@test "unknown platform: install is needs-user-action with the official docs URL; no installer is ever called, even with --allow-install" {
  touch "$STUB/absent"
  export JENGA_CONNECT_PLATFORM=plan9
  go
  [ "$status" -eq 3 ]
  [ "$(step_status detect)" = "pass" ]
  [ "$(step_detail detect)" = "absent" ]
  [ "$(step_status install)" = "needs-user-action" ]
  assert_contains "$(step_message install)" "$DOCS_INSTALL"
  [ "$(step_count auth)" -eq 0 ]
  [ ! -e "$STUB/installer.log" ]

  go --allow-install
  [ "$status" -eq 3 ]
  [ "$(step_status install)" = "needs-user-action" ]
  assert_contains "$(step_message install)" "$DOCS_INSTALL"
  [ ! -e "$STUB/installer.log" ]
}

@test "known platform with no usable install method (linux has no entry; darwin without brew): docs URL fallback, no installer is called even with --allow-install" {
  touch "$STUB/absent"
  # linux: brew IS on PATH here, but the descriptor has no linux method (Homebrew on Linux is not stated by the install page)
  export JENGA_CONNECT_PLATFORM=linux
  go --allow-install
  [ "$status" -eq 3 ]
  [ "$(step_status install)" = "needs-user-action" ]
  assert_contains "$(step_message install)" "$DOCS_INSTALL"
  [ ! -e "$STUB/installer.log" ]

  # darwin with no brew on PATH at all
  export JENGA_CONNECT_PLATFORM=darwin
  PATH="$LEAN_PATH" go --allow-install
  [ "$status" -eq 3 ]
  [ "$(step_status install)" = "needs-user-action" ]
  assert_contains "$(step_message install)" "$DOCS_INSTALL"
  [ ! -e "$STUB/installer.log" ]
}

@test "missing CLI on macOS with brew available: opt-in install only, and with --allow-install brew is run with the descriptor's own unpinned package" {
  touch "$STUB/absent"
  go
  [ "$status" -eq 3 ]
  [ "$(step_status install)" = "needs-user-action" ]
  assert_contains "$(step_message install)" "--allow-install"
  assert_contains "$(step_message install)" "$DOCS_INSTALL"
  [ ! -e "$STUB/installer.log" ]

  go --allow-install
  # install succeeds (the brew stub makes the stub CLI appear); the user then has to authenticate
  [ "$(step_status install)" = "pass" ]
  [ "$status" -eq 3 ]
  [ "$(step_status auth)" = "needs-user-action" ]
  pkg="$(jq -r '.install.methods[] | select(.platform == "darwin") | .package' "$DO_DESC")"
  [ "$(cat "$STUB/installer.log")" = "brew install $pkg" ]
  [ ! -e "$STUB/auth-init-called" ]
}

@test "unauthenticated gh has no effect: digitalocean does not require github, so gh is never called" {
  [ "$(jq 'has("requires")' "$DO_DESC")" = "false" ]
  touch "$STUB/authed"
  go
  [ "$status" -eq 0 ]
  [ "$(jq -c 'select(.step != null and (.step | startswith("requires:")))' <<<"$output" | wc -l | tr -d ' ')" -eq 0 ]
  [ ! -e "$STUB/gh.log" ]
}

@test "no token leak: the sentinel printed by the stub (and an env token the stub echoes) never reaches runner output, .mcp.json, any project file or the descriptor" {
  # DIGITALOCEAN_ACCESS_TOKEN is the name the doctl README states; the stub echoes its
  # value so any leak path from the process environment into output would show up.
  export DIGITALOCEAN_ACCESS_TOKEN="$SENTINEL"
  local mode
  for mode in unauthenticated authenticated; do
    rm -f "$STUB/authed"
    if [ "$mode" = "authenticated" ]; then touch "$STUB/authed"; fi
    go
    [ "$(noop_calls)" -ge 1 ]
    run grep -F "$SENTINEL" <<<"$output"
    [ "$status" -eq 1 ]
    run grep -F "$SENTINEL" <<<"$stderr"
    [ "$status" -eq 1 ]
    run grep -rF "$SENTINEL" "$PROJ"
    [ "$status" -eq 1 ]
  done
  # the stub did print it (the sentinel is real), and the descriptor holds no token value
  [ -f "$STUB/noop.count" ]
  run grep -F "$SENTINEL" "$DO_DESC"
  [ "$status" -eq 1 ]
  run grep -E "dop_v1_|DIGITALOCEAN_(ACCESS|API)_TOKEN" "$DO_DESC"
  [ "$status" -eq 1 ]
}
