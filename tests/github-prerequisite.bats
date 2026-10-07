#!/usr/bin/env bats
#
# GitHub-specific coverage for `github` as a shared j.connect prerequisite
# (E65_S03_T02), run against the real skills/j-connect/descriptors/github.json.
#
# The once-per-invocation mechanism itself is proven in run-descriptor.bats and
# connect-e2e.bats; this file only adds what the GitHub story promises on top:
# reuse by dependents, no re-prompting once gh is authenticated, the
# unknown-platform / no-method install fallback, and that no token leaks.
#
# `gh` is a stub on PATH (counting, with a switchable auth state and a sentinel
# "token" printed to stdout and stderr). The installers are stubs that only log.
# No real gh, network or credential is ever touched.

bats_require_minimum_version 1.5.0
load helpers/assertions

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
RUN="$REPO_ROOT/skills/j-connect/scripts/run-descriptor.sh"
REAL_DESC_DIR="$REPO_ROOT/skills/j-connect/descriptors"
SENTINEL="gho_FAKESENTINEL0123456789abcdefABCDEF"
DOCS_INSTALL="https://github.com/cli/cli#installation"
DOCS_LOGIN="https://cli.github.com/manual/gh_auth_login"

setup() {
  STUB="$BATS_TEST_TMPDIR/stub"
  FAKE_BIN="$BATS_TEST_TMPDIR/bin"
  PROJ="$BATS_TEST_TMPDIR/proj"
  DESC="$BATS_TEST_TMPDIR/desc"
  mkdir -p "$STUB" "$FAKE_BIN" "$PROJ" "$DESC"
  git -C "$PROJ" init -q .
  cp "$REAL_DESC_DIR/github.json" "$DESC/github.json"

  # gh: absent iff $STUB/absent exists; `auth status` succeeds iff $STUB/authed
  # exists; always prints the sentinel to stdout and stderr; counts calls.
  cat > "$FAKE_BIN/gh" <<EOS
#!/bin/sh
[ -e "$STUB/absent" ] && exit 127
echo "gh \$*" >> "$STUB/gh.log"
case "\$1 \$2" in
  "auth status")
    echo x >> "$STUB/auth-status.count"
    echo "Logged in as someone (token: $SENTINEL)"
    echo "token: $SENTINEL" >&2
    [ -e "$STUB/authed" ] && exit 0
    exit 1 ;;
  "auth login") touch "$STUB/login-called"; exit 0 ;;
esac
[ "\$1" = "--version" ] && { echo "gh version 0.0.0 (stub)"; exit 0; }
exit 0
EOS
  # Every installer-ish tool just records that it was called.
  local t
  for t in brew npm apt apt-get dnf yum pacman snap curl wget sudo; do
    printf '#!/bin/sh\necho "%s $*" >> "%s/installer.log"\nexit 0\n' "$t" "$STUB" > "$FAKE_BIN/$t"
  done
  chmod +x "$FAKE_BIN"/*
  export PATH="$FAKE_BIN:$PATH"
  export JENGA_CONNECT_PLATFORM=darwin

  # Dependent services that declare the GitHub prerequisite.
  make_dependent svc-a '["github"]'
  make_dependent svc-b '["github"]'
}

# make_dependent <id> <requires-json>: throwaway descriptor whose own steps trivially pass.
make_dependent() {
  jq -n --arg id "$1" --argjson req "$2" '{
    id: $id, name: ("Dependent " + $id), docs: ["https://example.invalid/docs"],
    requires: $req,
    detect: {command: ["true"]},
    install: {docs_url: "https://example.invalid/install"},
    auth: {type: "none"},
    register_mcp: {supported: false},
    verify: {command: ["true"]}
  }' > "$DESC/$1.json"
}

go() { # <id> [runner args...]
  local id="$1"; shift
  run --separate-stderr bash "$RUN" "$DESC/$id.json" --project-root "$PROJ" "$@"
}
# step_status <descriptor> <step>: status of the first matching result line.
step_status() { jq -r --arg d "$1" --arg s "$2" 'select(.descriptor == $d and .step == $s) | .status' <<<"$output" | head -n1; }
step_count() { jq -r --arg d "$1" --arg s "$2" 'select(.descriptor == $d and .step == $s) | .status' <<<"$output" | wc -l | tr -d ' '; }
step_message() { jq -r --arg d "$1" --arg s "$2" 'select(.descriptor == $d and .step == $s) | .message' <<<"$output" | head -n1; }
auth_status_calls() { if [ -f "$STUB/auth-status.count" ]; then wc -l < "$STUB/auth-status.count" | tr -d ' '; else echo 0; fi; }

@test "authenticated gh: dependent passes, github auth is skipped, gh auth status is called only for the auth check and verify" {
  touch "$STUB/authed"
  go svc-a --descriptors-dir "$REAL_DESC_DIR"
  [ "$status" -eq 0 ]
  [ "$(step_status svc-a requires:github)" = "pass" ]
  [ "$(step_status github detect)" = "pass" ]
  [ "$(step_status github install)" = "skipped" ]
  [ "$(step_status github auth)" = "skipped" ]
  [ "$(step_status github register_mcp)" = "skipped" ]
  [ "$(step_status github verify)" = "pass" ]
  [ "$(jq -r 'select(.summary == true) | .status' <<<"$output")" = "pass" ]
  # exactly the auth check + verify; the dependent adds no extra prerequisite run
  [ "$(auth_status_calls)" -eq 2 ]
  [ ! -e "$STUB/login-called" ]
  [ ! -e "$STUB/installer.log" ]
}

@test "github listed twice, and through a diamond, runs the prerequisite once; later references are skipped" {
  touch "$STUB/authed"
  make_dependent svc-twice '["github","github"]'
  go svc-twice
  [ "$status" -eq 0 ]
  [ "$(step_count github detect)" -eq 1 ]
  [ "$(jq -r 'select(.step == "requires:github") | .status' <<<"$output" | paste -sd, -)" = "pass,skipped" ]
  [ "$(auth_status_calls)" -eq 2 ]

  rm -f "$STUB/auth-status.count"
  make_dependent svc-mid '["github"]'
  make_dependent svc-top '["svc-mid","github"]'
  go svc-top
  [ "$status" -eq 0 ]
  [ "$(step_count github detect)" -eq 1 ]
  [ "$(jq -r 'select(.descriptor == "svc-mid" and .step == "requires:github") | .status' <<<"$output")" = "pass" ]
  [ "$(jq -r 'select(.descriptor == "svc-top" and .step == "requires:github") | .status' <<<"$output")" = "skipped" ]
  [ "$(auth_status_calls)" -eq 2 ]
}

@test "a separate invocation after gh is authenticated reports auth skipped and never re-asks the user" {
  # First service: gh is not authenticated yet, so the human is asked once.
  go svc-a
  [ "$status" -eq 3 ]
  [ "$(step_status github auth)" = "needs-user-action" ]

  # The user signs in (outside the runner), then the next service is connected.
  touch "$STUB/authed"
  go svc-b
  [ "$status" -eq 0 ]
  [ "$(step_status github auth)" = "skipped" ]
  [ "$(step_status svc-b requires:github)" = "pass" ]
  [ "$(jq -c 'select(.status == "needs-user-action")' <<<"$output" | wc -l | tr -d ' ')" -eq 0 ]
  [ "$(jq -r 'select(.summary == true) | .counts["needs-user-action"]' <<<"$output")" -eq 0 ]
}

@test "unauthenticated gh: stops with needs-user-action (exit 3), shows instructions and docs URL, never runs gh auth login" {
  go svc-a
  [ "$status" -eq 3 ]
  [ "$(step_status github detect)" = "pass" ]
  [ "$(step_status github auth)" = "needs-user-action" ]
  msg="$(step_message github auth)"
  assert_contains "$msg" "gh auth login"
  assert_contains "$msg" "one-time code"
  assert_contains "$msg" "$DOCS_LOGIN"
  [ "$(step_status svc-a requires:github)" = "needs-user-action" ]
  # the run stops: no verify for github, no dependent steps
  [ "$(step_count github verify)" -eq 0 ]
  [ "$(step_count svc-a detect)" -eq 0 ]
  [ "$(jq -r 'select(.summary == true) | .status' <<<"$output")" = "needs-user-action" ]
  # consent is human-only
  [ ! -e "$STUB/login-called" ]
  [ "$(grep -c 'auth login' "$STUB/gh.log")" -eq 0 ]
}

@test "missing gh on an unknown platform: install is needs-user-action with the official docs URL and no installer runs" {
  touch "$STUB/absent"
  export JENGA_CONNECT_PLATFORM=plan9
  go svc-a
  [ "$status" -eq 3 ]
  [ "$(step_status github detect)" = "pass" ]
  [ "$(step_status github install)" = "needs-user-action" ]
  assert_contains "$(step_message github install)" "$DOCS_INSTALL"
  [ "$(step_count github auth)" -eq 0 ]
  [ ! -e "$STUB/installer.log" ]

  # even with --allow-install, an unknown platform never guesses an installer
  go svc-a --allow-install
  [ "$status" -eq 3 ]
  [ "$(step_status github install)" = "needs-user-action" ]
  [ ! -e "$STUB/installer.log" ]
}

@test "missing gh on linux (no matching install method): docs URL fallback, no installer runs even with --allow-install" {
  touch "$STUB/absent"
  export JENGA_CONNECT_PLATFORM=linux
  go svc-a
  [ "$status" -eq 3 ]
  [ "$(step_status github install)" = "needs-user-action" ]
  assert_contains "$(step_message github install)" "$DOCS_INSTALL"
  [ ! -e "$STUB/installer.log" ]

  go svc-a --allow-install
  [ "$status" -eq 3 ]
  [ "$(step_status github install)" = "needs-user-action" ]
  [ ! -e "$STUB/installer.log" ]
}

@test "missing gh on darwin: install is opt-in, so without --allow-install brew is not called" {
  touch "$STUB/absent"
  go svc-a
  [ "$status" -eq 3 ]
  [ "$(step_status github install)" = "needs-user-action" ]
  assert_contains "$(step_message github install)" "$DOCS_INSTALL"
  [ ! -e "$STUB/installer.log" ]
}

@test "no token leak: the sentinel printed by gh auth status never reaches runner output or any file" {
  local mode
  for mode in unauthenticated authenticated; do
    rm -f "$STUB/authed"
    if [ "$mode" = "authenticated" ]; then touch "$STUB/authed"; fi
    go svc-a
    [ "$(auth_status_calls)" -ge 1 ]
    run grep -F "$SENTINEL" <<<"$output"
    [ "$status" -eq 1 ]
    run grep -F "$SENTINEL" <<<"$stderr"
    [ "$status" -eq 1 ]
    # nothing under the project root (including any .env / .mcp.json) holds it
    run grep -rF "$SENTINEL" "$PROJ"
    [ "$status" -eq 1 ]
  done
  # the descriptor itself holds no token value
  run grep -rF "gho_" "$REAL_DESC_DIR"
  [ "$status" -eq 1 ]
}
