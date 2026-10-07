#!/usr/bin/env bats
#
# End-to-end proof that the j.connect pieces compose (E65_S01_T06):
# validate-descriptor.sh + run-descriptor.sh + ensure-secret-safe.sh +
# register-mcp.sh, driven by a throwaway fixture descriptor (a fake "fakeservice"
# with a stub CLI on a fixture PATH) in a temp git project. The fixture lives
# under tests/fixtures/ only; nothing here is a shipped service descriptor.

bats_require_minimum_version 1.5.0
load helpers/assertions

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
FX="$REPO_ROOT/tests/fixtures/connect/e2e"
SENTINEL="SENTINEL-E2E-TOKEN-3b9d41aa"

setup() {
  STUB="$BATS_TEST_TMPDIR/stub"; FAKE_BIN="$BATS_TEST_TMPDIR/bin"; PROJ="$BATS_TEST_TMPDIR/proj"
  SCRIPTS="$BATS_TEST_TMPDIR/scripts"
  mkdir -p "$STUB" "$FAKE_BIN" "$PROJ"
  git -C "$PROJ" init -q .

  # Copy the scripts and interpose on the guardrail so the test can observe
  # whether .env already existed when the guardrail ran.
  cp -R "$REPO_ROOT/skills/j-connect/scripts" "$SCRIPTS"
  mv "$SCRIPTS/ensure-secret-safe.sh" "$SCRIPTS/ensure-secret-safe.real.sh"
  cat > "$SCRIPTS/ensure-secret-safe.sh" <<EOS
#!/usr/bin/env bash
if [ -e "$PROJ/.env" ]; then echo "env-existed-before-guard" >> "$STUB/guard.log"; else echo "env-absent-before-guard" >> "$STUB/guard.log"; fi
exec bash "$SCRIPTS/ensure-secret-safe.real.sh" "\$@"
EOS

  cat > "$FAKE_BIN/fakecli" <<EOS
#!/bin/sh
[ -e "$STUB/installed" ] || exit 127
case "\$1" in
  --version) echo "fakecli 0.0.0" ;;
  whoami) [ -e "$STUB/authed" ] && { echo "signed in with \$FAKESERVICE_TOKEN"; exit 0; }; exit 1 ;;
esac
exit 0
EOS
  printf '#!/bin/sh\nexit 0\n' > "$FAKE_BIN/prereqcli"
  chmod +x "$FAKE_BIN"/*
  export PATH="$FAKE_BIN:$PATH"
  export JENGA_CONNECT_PLATFORM=darwin
  export FAKESERVICE_TOKEN="$SENTINEL"
}

go() { run --separate-stderr bash "$SCRIPTS/run-descriptor.sh" "$FX/fakeservice.json" --project-root "$PROJ" "$@"; }
st() { jq -r --arg s "$1" 'select(.descriptor == "fakeservice" and .step == $s) | .status' <<<"$output" | paste -sd, -; }

@test "fixture descriptors pass the validator" {
  run bash "$SCRIPTS/validate-descriptor.sh" "$FX/fakeservice.json"
  [ "$status" -eq 0 ]
  run bash "$SCRIPTS/validate-descriptor.sh" "$FX/fake-prereq.json"
  [ "$status" -eq 0 ]
}

@test "full flow: install gap, auth gap, then a complete pass, then an unchanged second run" {
  # 1. CLI absent: install is a human step (no --allow-install).
  go
  [ "$status" -eq 3 ]
  [ "$(st detect)" = "pass" ]
  [ "$(st install)" = "needs-user-action" ]
  [ "$(st "requires:fake-prereq")" = "pass" ]

  # 2. CLI installed, not authenticated: guardrail runs BEFORE .env exists, then a placeholder is written.
  touch "$STUB/installed"
  go
  [ "$status" -eq 3 ]
  [ "$(st install)" = "skipped" ]
  [ "$(st auth)" = "needs-user-action" ]
  [ "$(cat "$STUB/guard.log")" = "env-absent-before-guard" ]
  git -C "$PROJ" check-ignore -q .env
  [ "$(cat "$PROJ/.env")" = "FAKESERVICE_TOKEN=" ]

  # 3. Authenticated: every step reports its expected status.
  touch "$STUB/authed"
  go
  [ "$status" -eq 0 ]
  [ "$(st detect)" = "pass" ]
  [ "$(st install)" = "skipped" ]
  [ "$(st auth)" = "skipped" ]
  [ "$(st register_mcp)" = "pass" ]
  [ "$(jq -r 'select(.descriptor == "fakeservice" and .step == "register_mcp") | .detail' <<<"$output")" = "added" ]
  [ "$(st verify)" = "pass" ]
  [ "$(jq -r 'select(.summary == true) | .status' <<<"$output")" = "pass" ]
  # MCP entry landed in the location named by project/documentation/mcp-registration-decision.md
  [ "$(jq -c '.mcpServers.fakeservice.env' "$PROJ/.mcp.json")" = '{"FAKESERVICE_TOKEN":"${FAKESERVICE_TOKEN}"}' ]
  cp "$PROJ/.mcp.json" "$BATS_TEST_TMPDIR/mcp.after-first"

  # 4. Second run: registration unchanged, file untouched.
  go
  [ "$status" -eq 0 ]
  [ "$(st register_mcp)" = "skipped" ]
  [ "$(jq -r 'select(.descriptor == "fakeservice" and .step == "register_mcp") | .detail' <<<"$output")" = "unchanged" ]
  cmp "$PROJ/.mcp.json" "$BATS_TEST_TMPDIR/mcp.after-first"
}

@test "no secret sentinel in any output or any file written to the project" {
  touch "$STUB/installed"
  go
  [[ "$output$stderr" != *"$SENTINEL"* ]] || false
  touch "$STUB/authed"
  go
  [[ "$output$stderr" != *"$SENTINEL"* ]] || false
  go
  [[ "$output$stderr" != *"$SENTINEL"* ]] || false
  ! grep -rqF "$SENTINEL" "$PROJ" --exclude-dir=.git
}
