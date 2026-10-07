#!/usr/bin/env bats
#
# Expo-specific coverage of the j.connect runner (E65_S06_T04), run against the real
# skills/j-connect/descriptors/expo.json with STUBBED `eas` and `expo` CLIs on PATH. Generic
# runner mechanics are covered in run-descriptor.bats, register-mcp.bats,
# ensure-secret-safe.bats and connect-e2e.bats; this file only adds what the Expo story
# promises on top. Argv, URLs, names and package names are read from the descriptor with jq
# rather than copied here.
#
# The `eas` stub counts calls, has independently switchable presence ($STUB/absent), version
# result ($STUB/version-fails) and authenticated no-op `eas whoami` result ($STUB/authed),
# records `eas login` without doing anything (eas-login-called), records any `build`, `submit`,
# `credentials` or `testflight` call in eas-forbidden.log (must never happen), prints a
# sentinel "token" to stdout and stderr, and also echoes the value of EXPO_TOKEN when that is
# set. The `expo` stub only records calls (the descriptor never runs it). Installers are
# log-only stubs, except the npm stub which also "installs" the stub CLI. Neither eas nor expo
# is installed on the authoring machine; no real CLI, network, Expo account or token is touched.
#
# What a stub CANNOT prove, and is therefore NOT asserted here
# (project/documentation/figma-expo-connect-research.md, "Could not verify"):
#   - that `eas --version` is the documented version command, or real `eas login` behaviour;
#   - that `eas whoami` really exits non-zero when logged out, or where credentials are stored;
#   - that EAS CLI honours EXPO_TOKEN (the stub only echoes it to catch leaks);
#   - a Node.js prerequisite for EAS CLI, or that the eas-cli npm package installs cleanly;
#   - that Expo's hosted MCP server loads in Claude Code or completes OAuth (it is not registered
#     by this descriptor at all, see the register_mcp test).
# The story's "end-to-end run on a real Expo account" item is a human check and is NOT done by
# this file (not verifiable here: no eas/expo tooling, no account).
#
# Design choices recorded here: auth.type browser (the user runs `eas login` themselves; the
# CLI keeps its own credentials), no `secrets` block, and register_mcp {"supported": false}
# (the Expo plugin already registers the hosted server, and its tools reach EAS builds and
# store data). So the runner never creates an env file, the pre-write .gitignore guardrail
# (ensure-secret-safe.sh) never runs for this descriptor, and no .mcp.json is ever written. The
# guardrail test asserts that no env file or .gitignore appears in ANY scenario and fails loudly
# if the descriptor ever grows an env-token design (the guardrail ordering is covered
# generically in ensure-secret-safe.bats and run-descriptor.bats).

# Each @test runs in its own subshell, so per-test env changes are intentional.
# shellcheck disable=SC2030,SC2031
bats_require_minimum_version 1.5.0
load helpers/assertions

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
RUN="$REPO_ROOT/skills/j-connect/scripts/run-descriptor.sh"
EXPO_DESC="$REPO_ROOT/skills/j-connect/descriptors/expo.json"
# A shape unlikely to match a real Expo token or the validator's credential heuristics.
SENTINEL="FAKESENTINELEXPO_0123456789abcdefABCDEF"

setup() {
  STUB="$BATS_TEST_TMPDIR/stub"
  FAKE_BIN="$BATS_TEST_TMPDIR/bin"
  NPM_BIN="$BATS_TEST_TMPDIR/npmbin"
  LEAN_BIN="$BATS_TEST_TMPDIR/lean"
  PROJ="$BATS_TEST_TMPDIR/proj"
  mkdir -p "$STUB" "$FAKE_BIN" "$NPM_BIN" "$LEAN_BIN" "$PROJ"
  git -C "$PROJ" init -q .

  # eas: absent iff $STUB/absent exists; `--version` fails iff $STUB/version-fails; `whoami`
  # succeeds iff $STUB/authed; always prints the sentinel (and the env token if set); counts calls.
  cat > "$FAKE_BIN/eas" <<EOS
#!/bin/sh
[ -e "$STUB/absent" ] && exit 127
echo "eas \$*" >> "$STUB/eas.log"
echo "token: $SENTINEL \${EXPO_TOKEN:-}"; echo "token: $SENTINEL" >&2
case "\$1" in
  --version)
    [ -e "$STUB/version-fails" ] && exit 1
    exit 0 ;;
  login|account:login) touch "$STUB/eas-login-called"; exit 0 ;;
  build|submit|credentials|testflight|build:*|submit:*|credentials:*) echo "eas \$*" >> "$STUB/eas-forbidden.log"; exit 0 ;;
  whoami|account:view)
    echo x >> "$STUB/noop.count"
    [ -e "$STUB/authed" ] && exit 0
    exit 1 ;;
esac
exit 0
EOS
  # expo is never run by the descriptor; any call is recorded.
  printf '#!/bin/sh\necho "expo $*" >> "%s/expo.log"\nexit 0\n' "$STUB" > "$FAKE_BIN/expo"
  # Non-npm installers only record that they were called.
  local t
  for t in brew yarn pnpm bun npx apt apt-get dnf yum pacman snap scoop curl wget sudo; do
    printf '#!/bin/sh\necho "%s $*" >> "%s/installer.log"\nexit 0\n' "$t" "$STUB" > "$FAKE_BIN/$t"
  done
  # npm records the call and, on `install`, makes the stub CLI appear.
  cat > "$NPM_BIN/npm" <<EOS
#!/bin/sh
echo "npm \$*" >> "$STUB/installer.log"
[ "\$1" = "install" ] && rm -f "$STUB/absent"
exit 0
EOS
  chmod +x "$FAKE_BIN"/* "$NPM_BIN"/*

  # A PATH with no npm at all (the maintainer's real npm lives under nvm, so symlink just
  # the tools the runner needs instead of excluding a directory).
  local tool
  for tool in jq bash git; do ln -s "$(command -v "$tool")" "$LEAN_BIN/$tool"; done

  export PATH="$FAKE_BIN:$NPM_BIN:$PATH"
  export LEAN_PATH="$FAKE_BIN:$LEAN_BIN:/usr/bin:/bin:/usr/sbin:/sbin"
  export JENGA_CONNECT_PLATFORM=darwin
  unset EXPO_TOKEN
  DOCS_INSTALL="$(jq -r '.install.docs_url' "$EXPO_DESC")"
  DOCS_AUTH="$(jq -r '.auth.docs_url' "$EXPO_DESC")"
}

go() { run --separate-stderr bash "$RUN" "$EXPO_DESC" --project-root "$PROJ" "$@"; }
# step_status/message/detail <step>: fields of the first matching result line.
step_status() { jq -r --arg s "$1" 'select(.step == $s) | .status' <<<"$output" | head -n1; }
step_message() { jq -r --arg s "$1" 'select(.step == $s) | .message' <<<"$output" | head -n1; }
step_detail() { jq -r --arg s "$1" 'select(.step == $s) | .detail // empty' <<<"$output" | head -n1; }
step_count() { jq -r --arg s "$1" 'select(.step == $s) | .status' <<<"$output" | wc -l | tr -d ' '; }
noop_calls() { if [ -f "$STUB/noop.count" ]; then wc -l < "$STUB/noop.count" | tr -d ' '; else echo 0; fi; }
# project_files: every file in the project besides .git
project_files() { find "$PROJ" -path "$PROJ/.git" -prune -o -type f -print | sed "s|$PROJ/||"; }

@test "already installed and authenticated: satisfied steps skip or pass, register_mcp is skipped, nothing installs, no login call, no file written; a re-run is identical" {
  touch "$STUB/authed"
  go
  [ "$status" -eq 0 ]
  [ "$(step_status detect)" = "pass" ]
  [ "$(step_detail detect)" = "present" ]
  [ "$(step_status install)" = "skipped" ]
  assert_contains "$(step_message install)" "already installed"
  [ "$(step_status auth)" = "skipped" ]
  assert_contains "$(step_message auth)" "already authenticated"
  [ "$(step_status register_mcp)" = "skipped" ]
  assert_contains "$(step_message register_mcp)" "no MCP server"
  [ "$(step_status verify)" = "pass" ]
  [ "$(jq -r 'select(.summary == true) | .status' <<<"$output")" = "pass" ]

  go
  [ "$status" -eq 0 ]
  [ "$(step_status register_mcp)" = "skipped" ]
  [ "$(step_status install)" = "skipped" ]
  [ "$(step_status auth)" = "skipped" ]
  [ ! -e "$STUB/installer.log" ]
  [ ! -e "$STUB/eas-login-called" ]
  # no env file, no .mcp.json, no other file at all
  [ -z "$(project_files)" ]
}

@test "unauthenticated: stops at auth with needs-user-action (exit 3), shows the descriptor instructions and docs URL, never runs eas login, no later step runs" {
  go
  [ "$status" -eq 3 ]
  [ "$(step_status detect)" = "pass" ]
  [ "$(step_status install)" = "skipped" ]
  [ "$(step_status auth)" = "needs-user-action" ]
  msg="$(step_message auth)"
  assert_contains "$msg" "$(jq -r '.auth.instructions' "$EXPO_DESC")"
  assert_contains "$msg" "eas login"
  assert_contains "$msg" "$DOCS_AUTH"
  [ "$(step_count register_mcp)" -eq 0 ]
  [ "$(step_count verify)" -eq 0 ]
  [ "$(jq -r 'select(.summary == true) | .status' <<<"$output")" = "needs-user-action" ]
  # the human signs in at the CLI's own prompt: the runner never invokes login
  [ ! -e "$STUB/eas-login-called" ]
  [ "$(grep -c 'login' "$STUB/eas.log")" -eq 0 ]
  [ -z "$(project_files)" ]
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

@test "detect, the auth check and verify are the descriptor's argv, called exactly that way; the no-op is not the version command" {
  touch "$STUB/authed"
  go
  [ "$status" -eq 0 ]
  noop="$(jq -r '.verify.command | join(" ")' "$EXPO_DESC")"
  [ "$(jq -r '.auth.check.command | join(" ")' "$EXPO_DESC")" = "$noop" ]
  # auth check + verify = two calls of the no-op, each logged with that exact argv
  [ "$(grep -cFx "eas ${noop#eas }" "$STUB/eas.log")" -eq 2 ]
  [ "$(noop_calls)" -eq 2 ]
  detect="$(jq -r '.detect.command | join(" ")' "$EXPO_DESC")"
  [ "$detect" != "$noop" ]
  [ "$(grep -cFx "eas ${detect#eas }" "$STUB/eas.log")" -ge 1 ]
}

@test "a failing eas version probe is treated as not installed (detect is judged by exit status only): install is opt-in, and login is never run" {
  touch "$STUB/version-fails" "$STUB/authed"
  go
  [ "$(step_detail detect)" = "absent" ]
  [ "$(step_status install)" = "needs-user-action" ]
  assert_contains "$(step_message install)" "--allow-install"
  [ ! -e "$STUB/eas-login-called" ]
}

@test "secrets guardrail: this descriptor can never create an env file or touch .gitignore, in any scenario (the CLI keeps its own credentials)" {
  # If the descriptor ever gains env-token auth or secrets.env_file, this test must be
  # extended to cover the pre-write .gitignore refusal, so fail loudly first.
  [ "$(jq -r '.auth.type' "$EXPO_DESC")" = "browser" ]
  [ "$(jq 'has("secrets")' "$EXPO_DESC")" = "false" ]

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
    [ ! -e "$STUB/eas-login-called" ]
  done
}

@test "MCP registration: register_mcp is unsupported, so no .mcp.json is created or modified and nothing is written to .claude/settings.json or .agents/settings.json; the reason is in descriptor text" {
  [ "$(jq -c '.register_mcp' "$EXPO_DESC")" = '{"supported":false}' ]
  touch "$STUB/authed"
  printf '%s\n' '{"mcpServers":{"other":{"type":"stdio","command":"/usr/bin/true","args":[]}},"someTopLevelKey":{"keep":true}}' > "$PROJ/.mcp.json"
  sum="$(cksum < "$PROJ/.mcp.json")"
  go
  [ "$status" -eq 0 ]
  [ "$(step_status register_mcp)" = "skipped" ]
  [ "$(cksum < "$PROJ/.mcp.json")" = "$sum" ]
  [ ! -e "$PROJ/.claude/settings.json" ]
  [ ! -e "$PROJ/.agents/settings.json" ]
  [ "$(project_files)" = ".mcp.json" ]
  assert_contains "$(jq -r '.auth.instructions' "$EXPO_DESC")" "not registered here"
}

@test "unknown platform: install is needs-user-action with the official Expo docs URL; no installer is ever called, even with --allow-install" {
  touch "$STUB/absent"
  export JENGA_CONNECT_PLATFORM=plan9
  go
  [ "$status" -eq 3 ]
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

@test "known platform with no npm on PATH: docs URL fallback, no installer is called even with --allow-install" {
  touch "$STUB/absent"
  export JENGA_CONNECT_PLATFORM=linux
  PATH="$LEAN_PATH" go --allow-install
  [ "$status" -eq 3 ]
  [ "$(step_status install)" = "needs-user-action" ]
  assert_contains "$(step_message install)" "$DOCS_INSTALL"
  [ ! -e "$STUB/installer.log" ]
}

@test "missing CLI with npm available: opt-in install only, and with --allow-install npm is run with the descriptor's own unpinned package and nothing else is called" {
  touch "$STUB/absent"
  go
  [ "$status" -eq 3 ]
  [ "$(step_status install)" = "needs-user-action" ]
  assert_contains "$(step_message install)" "--allow-install"
  assert_contains "$(step_message install)" "$DOCS_INSTALL"
  [ ! -e "$STUB/installer.log" ]

  go --allow-install
  # install succeeds (the npm stub makes the stub CLI appear); the user then has to sign in
  [ "$(step_status install)" = "pass" ]
  [ "$status" -eq 3 ]
  [ "$(step_status auth)" = "needs-user-action" ]
  pkg="$(jq -r '.install.methods[] | select(.platform == "darwin") | .package' "$EXPO_DESC")"
  [ "$(cat "$STUB/installer.log")" = "npm install -g $pkg" ]
  [ ! -e "$STUB/eas-login-called" ]
}

@test "EAS / store-submission boundary: across every scenario no eas build, submit or credentials call, no expo call, and no publish.json is read or created" {
  # descriptor side (also asserted as data in expo-descriptor.bats)
  [ "$(jq '[.. | strings | select(test("APP_STORE_CONNECT|CODE_SIGN_IDENTITY|PROVISIONING_PROFILE|PLAY_CONSOLE"))] | length' "$EXPO_DESC")" -eq 0 ]
  assert_contains "$(jq -r '.install.hint' "$EXPO_DESC")" "j.publish"
  assert_contains "$(jq -r '.install.hint' "$EXPO_DESC")" "mobile-ios"

  local mode
  for mode in authenticated unauthenticated absent absent-allow-install version-fails; do
    rm -f "$STUB/authed" "$STUB/absent" "$STUB/version-fails"
    case "$mode" in
      authenticated) touch "$STUB/authed" ;;
      absent|absent-allow-install) touch "$STUB/absent" ;;
      version-fails) touch "$STUB/version-fails" "$STUB/authed" ;;
    esac
    if [ "$mode" = "absent-allow-install" ]; then go --allow-install --continue; else go --continue; fi
  done
  [ ! -e "$STUB/eas-forbidden.log" ]
  [ ! -e "$STUB/expo.log" ]
  if [ -f "$STUB/eas.log" ]; then
    run grep -Eq '^eas (build|submit|credentials|testflight)' "$STUB/eas.log"
    [ "$status" -eq 1 ]
  fi
  [ -z "$(find "$PROJ" -name 'publish.json' -print)" ]
  [ -z "$(project_files)" ]
}

@test "no token leak: the sentinel printed by the stub (and an env token the stub echoes) never reaches runner output, any project file or the descriptor" {
  # EXPO_TOKEN is the non-interactive variable the programmatic-access page names (research doc);
  # the stub echoes its value so any leak path from the process environment into output would show up.
  export EXPO_TOKEN="$SENTINEL"
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
  # the stub did print it (the sentinel is real), and the descriptor holds no token value or token variable name
  [ -f "$STUB/noop.count" ]
  run grep -F "$SENTINEL" "$EXPO_DESC"
  [ "$status" -eq 1 ]
  run grep -E "EXPO_TOKEN" "$EXPO_DESC"
  [ "$status" -eq 1 ]
}
