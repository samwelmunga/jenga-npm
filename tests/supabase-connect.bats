#!/usr/bin/env bats
#
# Supabase-specific coverage of the j.connect runner (E65_S04_T03), run against
# the real skills/j-connect/descriptors/supabase.json with a STUBBED `supabase`
# on PATH. Generic runner mechanics are covered in run-descriptor.bats,
# register-mcp.bats, ensure-secret-safe.bats and connect-e2e.bats; this file only
# adds what the Supabase story promises on top. Argv, URLs and package names are
# read from the descriptor with jq rather than copied here.
#
# The `supabase` stub counts calls, has independently switchable presence
# ($STUB/absent) and authentication ($STUB/authed), records `supabase login`
# without doing anything, and prints a sentinel "token" to stdout and stderr.
# Installers are log-only stubs (the brew stub also "installs" the stub CLI).
# No real supabase, network or credential is ever touched.
#
# What a stub CANNOT prove, and is therefore NOT asserted here:
#   - real `supabase login` behaviour (the browser flow, what it prints, where the
#     token lands) or that `supabase projects list` really exits non-zero when
#     logged out (project/documentation/supabase-connect-research.md, "Could not verify");
#   - that the hosted MCP server loads in Claude Code, completes its own OAuth
#     consent, or is approved by the user;
#   - that the `supabase/tap/supabase` Homebrew formula still exists.
# The story's "end-to-end run on a real Supabase account" item is a human check.
#
# Design choice recorded here: the descriptor uses auth.type browser, has no
# `secrets` block and a token-free hosted (OAuth) MCP entry, so the runner never
# creates an env file and the pre-write .gitignore guardrail has nothing to guard.
# The guardrail test below therefore asserts that no env file is created in any
# scenario, and fails loudly if the descriptor ever grows an env-token design.

# Each @test runs in its own subshell, so per-test env changes are intentional.
# shellcheck disable=SC2030,SC2031
bats_require_minimum_version 1.5.0
load helpers/assertions

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
RUN="$REPO_ROOT/skills/j-connect/scripts/run-descriptor.sh"
SB_DESC="$REPO_ROOT/skills/j-connect/descriptors/supabase.json"
SENTINEL="sbp_FAKESENTINEL0123456789abcdefABCDEF"

setup() {
  STUB="$BATS_TEST_TMPDIR/stub"
  FAKE_BIN="$BATS_TEST_TMPDIR/bin"
  BREW_BIN="$BATS_TEST_TMPDIR/brewbin"
  LEAN_BIN="$BATS_TEST_TMPDIR/lean"
  PROJ="$BATS_TEST_TMPDIR/proj"
  mkdir -p "$STUB" "$FAKE_BIN" "$BREW_BIN" "$LEAN_BIN" "$PROJ"
  git -C "$PROJ" init -q .

  # supabase: absent iff $STUB/absent exists; `projects list` succeeds iff
  # $STUB/authed exists; always prints the sentinel; counts calls.
  cat > "$FAKE_BIN/supabase" <<EOS
#!/bin/sh
[ -e "$STUB/absent" ] && exit 127
echo "supabase \$*" >> "$STUB/supabase.log"
case "\$1" in
  --version) echo "2.0.0-stub (token: $SENTINEL)"; echo "token: $SENTINEL" >&2; exit 0 ;;
  login) touch "$STUB/login-called"; exit 0 ;;
  projects)
    if [ "\$2" = "list" ]; then
      echo x >> "$STUB/noop.count"
      echo "projects (token: $SENTINEL)"
      echo "token: $SENTINEL" >&2
      [ -e "$STUB/authed" ] && exit 0
      exit 1
    fi ;;
esac
exit 0
EOS
  # gh is never needed by supabase; if anything calls it, it fails and is logged.
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
  DOCS_INSTALL="$(jq -r '.install.docs_url' "$SB_DESC")"
  DOCS_LOGIN="$(jq -r '.auth.docs_url' "$SB_DESC")"
}

go() { run --separate-stderr bash "$RUN" "$SB_DESC" --project-root "$PROJ" "$@"; }
# step_status/message/detail <step>: fields of the first matching result line.
step_status() { jq -r --arg s "$1" 'select(.step == $s) | .status' <<<"$output" | head -n1; }
step_message() { jq -r --arg s "$1" 'select(.step == $s) | .message' <<<"$output" | head -n1; }
step_detail() { jq -r --arg s "$1" 'select(.step == $s) | .detail // empty' <<<"$output" | head -n1; }
step_count() { jq -r --arg s "$1" 'select(.step == $s) | .status' <<<"$output" | wc -l | tr -d ' '; }
noop_calls() { if [ -f "$STUB/noop.count" ]; then wc -l < "$STUB/noop.count" | tr -d ' '; else echo 0; fi; }

@test "already installed and authenticated: every satisfied step is skipped or passes, register_mcp is added then unchanged, nothing installs or logs in" {
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
  [ ! -e "$STUB/login-called" ]
}

@test "unauthenticated: stops at auth with needs-user-action (exit 3), shows the descriptor instructions and docs URL, never runs supabase login, no later step runs" {
  go
  [ "$status" -eq 3 ]
  [ "$(step_status detect)" = "pass" ]
  [ "$(step_status install)" = "skipped" ]
  [ "$(step_status auth)" = "needs-user-action" ]
  msg="$(step_message auth)"
  assert_contains "$msg" "$(jq -r '.auth.instructions' "$SB_DESC")"
  assert_contains "$msg" "supabase login"
  assert_contains "$msg" "$DOCS_LOGIN"
  [ "$(step_count register_mcp)" -eq 0 ]
  [ "$(step_count verify)" -eq 0 ]
  [ ! -e "$PROJ/.mcp.json" ]
  [ "$(jq -r 'select(.summary == true) | .status' <<<"$output")" = "needs-user-action" ]
  # consent is human-only: the runner never invokes login
  [ ! -e "$STUB/login-called" ]
  [ "$(grep -c 'login' "$STUB/supabase.log")" -eq 0 ]
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

@test "verify and the auth check are the descriptor's authenticated no-op argv, called exactly that way" {
  touch "$STUB/authed"
  go
  [ "$status" -eq 0 ]
  noop="$(jq -r '.verify.command | join(" ")' "$SB_DESC")"
  [ "$(jq -r '.auth.check.command | join(" ")' "$SB_DESC")" = "$noop" ]
  # auth check + verify = two calls of the no-op, each logged with that exact argv
  [ "$(grep -cFx "supabase ${noop#supabase }" "$STUB/supabase.log")" -eq 2 ]
  [ "$(noop_calls)" -eq 2 ]
}

@test ".mcp.json registration is idempotent: first added, second unchanged and byte-identical; other servers and top-level keys preserved; entry equals the descriptor shape" {
  touch "$STUB/authed"
  printf '%s\n' '{"mcpServers":{"other":{"type":"stdio","command":"/usr/bin/true","args":[]}},"someTopLevelKey":{"keep":true}}' > "$PROJ/.mcp.json"

  go
  [ "$status" -eq 0 ]
  [ "$(step_detail register_mcp)" = "added" ]
  name="$(jq -r '.register_mcp.name' "$SB_DESC")"
  [ "$(jq -cS --arg n "$name" '.mcpServers[$n]' "$PROJ/.mcp.json")" = "$(jq -cS '{type: .register_mcp.type, url: .register_mcp.url}' "$SB_DESC")" ]
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

@test "secrets guardrail: this descriptor can never create an env file, in any scenario" {
  # If the descriptor ever gains env-token auth or secrets.env_file, this test must
  # be extended to cover the pre-write .gitignore refusal, so fail loudly first.
  [ "$(jq -r '.auth.type' "$SB_DESC")" = "browser" ]
  [ "$(jq 'has("secrets")' "$SB_DESC")" = "false" ]

  local mode
  for mode in unauthenticated authenticated; do
    rm -f "$STUB/authed"
    if [ "$mode" = "authenticated" ]; then touch "$STUB/authed"; fi
    go
    [ "$(find "$PROJ" -path "$PROJ/.git" -prune -o -name '.env*' -print | wc -l | tr -d ' ')" -eq 0 ]
    # the guardrail never ran, so it did not touch .gitignore either
    [ ! -e "$PROJ/.gitignore" ]
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

@test "known platform with no usable install method (no brew on PATH): docs URL fallback, no installer is called even with --allow-install" {
  touch "$STUB/absent"
  local plat
  for plat in darwin linux; do
    export JENGA_CONNECT_PLATFORM="$plat"
    PATH="$LEAN_PATH" go
    [ "$status" -eq 3 ]
    [ "$(step_status install)" = "needs-user-action" ]
    assert_contains "$(step_message install)" "$DOCS_INSTALL"
    PATH="$LEAN_PATH" go --allow-install
    [ "$status" -eq 3 ]
    [ "$(step_status install)" = "needs-user-action" ]
    [ ! -e "$STUB/installer.log" ]
  done
}

@test "missing CLI with brew available: opt-in install only, and with --allow-install brew is run with the descriptor's own unpinned package" {
  touch "$STUB/absent"
  go
  [ "$status" -eq 3 ]
  [ "$(step_status install)" = "needs-user-action" ]
  assert_contains "$(step_message install)" "--allow-install"
  assert_contains "$(step_message install)" "$DOCS_INSTALL"
  [ ! -e "$STUB/installer.log" ]

  go --allow-install
  # install succeeds (the brew stub makes the stub CLI appear); the user then has to log in
  [ "$(step_status install)" = "pass" ]
  [ "$status" -eq 3 ]
  [ "$(step_status auth)" = "needs-user-action" ]
  pkg="$(jq -r '.install.methods[] | select(.platform == "darwin") | .package' "$SB_DESC")"
  [ "$(cat "$STUB/installer.log")" = "brew install $pkg" ]
  [ ! -e "$STUB/login-called" ]
}

@test "unauthenticated gh has no effect: supabase does not require github, so gh is never called" {
  [ "$(jq 'has("requires")' "$SB_DESC")" = "false" ]
  touch "$STUB/authed"
  go
  [ "$status" -eq 0 ]
  [ "$(jq -c 'select(.step != null and (.step | startswith("requires:")))' <<<"$output" | wc -l | tr -d ' ')" -eq 0 ]
  [ ! -e "$STUB/gh.log" ]
}

@test "no token leak: the sentinel printed by the stub never reaches runner output, .mcp.json, any project file or the descriptor" {
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
  run grep -F "$SENTINEL" "$SB_DESC"
  [ "$status" -eq 1 ]
  run grep -F "sbp_" "$SB_DESC"
  [ "$status" -eq 1 ]
}
