#!/usr/bin/env bats
#
# Coverage for skills/j-connect/scripts/run-descriptor.sh (E65_S01_T05).
#
# Every test runs against stub executables on a throwaway PATH (fakecli, brew,
# uname, a counting prerequisite tool) and a throwaway git project under
# $BATS_TEST_TMPDIR. No real vendor CLI or package manager is ever invoked.

bats_require_minimum_version 1.5.0
load helpers/assertions

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
RUN="$REPO_ROOT/skills/j-connect/scripts/run-descriptor.sh"
FX="$REPO_ROOT/tests/fixtures/connect/descriptors"
SENTINEL="SENTINEL-TOKEN-VALUE-77c0de12"

setup() {
  STUB="$BATS_TEST_TMPDIR/stub"          # state shared with stubs
  FAKE_BIN="$BATS_TEST_TMPDIR/bin"
  PROJ="$BATS_TEST_TMPDIR/proj"
  DESC="$BATS_TEST_TMPDIR/desc"
  mkdir -p "$STUB" "$FAKE_BIN" "$PROJ" "$DESC"
  git -C "$PROJ" init -q .
  git -C "$PROJ" config user.email t@example.invalid
  git -C "$PROJ" config user.name t

  # fakecli: installed iff $STUB/installed exists; whoami succeeds iff $STUB/authed exists.
  cat > "$FAKE_BIN/fakecli" <<EOF
#!/bin/sh
echo "fakecli \$*" >> "$STUB/fakecli.log"
[ -e "$STUB/installed" ] || exit 127
case "\$1" in
  --version) echo "fakecli 0.0.0"; exit 0 ;;
  whoami) [ -e "$STUB/authed" ] && { echo "user (token \$FAKESERVICE_TOKEN)"; exit 0; }; exit 1 ;;
esac
exit 0
EOF
  # brew: records the call and "installs" fakecli.
  cat > "$FAKE_BIN/brew" <<EOF
#!/bin/sh
echo "brew \$*" >> "$STUB/brew.log"
touch "$STUB/installed"
exit 0
EOF
  # prereqcli: counts --version (the detect check) invocations.
  cat > "$FAKE_BIN/prereqcli" <<EOF
#!/bin/sh
[ "\$1" = "--version" ] && echo x >> "$STUB/prereq.count"
exit 0
EOF
  chmod +x "$FAKE_BIN"/*
  export PATH="$FAKE_BIN:$PATH"
  export JENGA_CONNECT_PLATFORM=darwin
  cp "$FX/valid.json" "$DESC/fakeservice.json"
}

# jq edit of the working descriptor: edit '<filter>'
edit() { jq "$1" "$DESC/fakeservice.json" > "$DESC/.tmp" && mv "$DESC/.tmp" "$DESC/fakeservice.json"; }
run_it() { run --separate-stderr bash "$RUN" "$DESC/fakeservice.json" --project-root "$PROJ" "$@"; }
step_status() { jq -r --arg s "$1" 'select(.step == $s) | .status' <<<"$output" | head -n1; }
steps_in_order() { jq -r 'select(.step != null) | .step' <<<"$output" | paste -sd, -; }

@test "tool present: detect passes, install skipped, results are ordered JSON with the 4-value vocabulary" {
  touch "$STUB/installed" "$STUB/authed"
  run_it
  [ "$status" -eq 0 ]
  [ "$(steps_in_order)" = "detect,install,auth,register_mcp,verify" ]
  [ "$(step_status detect)" = "pass" ]
  [ "$(step_status install)" = "skipped" ]
  [ "$(step_status auth)" = "skipped" ]
  [ "$(step_status register_mcp)" = "pass" ]
  [ "$(step_status verify)" = "pass" ]
  # every line is JSON; every step has step/status/message; status in vocabulary
  [ "$(jq -c 'select(.step != null) | select((.status | IN("pass","fail","skipped","needs-user-action")) and (.step|type=="string") and (.message|type=="string"))' <<<"$output" | wc -l | tr -d ' ')" -eq 5 ]
  [ "$(jq -r 'select(.summary == true) | .status' <<<"$output")" = "pass" ]
  [ -f "$PROJ/.mcp.json" ]
}

@test "tool absent, no --allow-install: install returns needs-user-action, exit 3, installer not called, run stops" {
  run_it
  [ "$status" -eq 3 ]
  [ "$(step_status install)" = "needs-user-action" ]
  [ -z "$(step_status auth)" ]
  [ ! -e "$STUB/brew.log" ]
  [[ "$output" == *"https://example.invalid/fakeservice/install"* ]] || false
  [ "$(jq -r 'select(.summary == true) | .status' <<<"$output")" = "needs-user-action" ]
}

@test "tool absent with --allow-install: runs the package manager from descriptor fields, then re-detects" {
  touch "$STUB/authed"
  run_it --allow-install
  [ "$status" -eq 0 ]
  [ "$(step_status install)" = "pass" ]
  [ "$(cat "$STUB/brew.log")" = "brew install fakecli" ]
  [ "$(step_status verify)" = "pass" ]
}

@test "package manager that does not actually install yields fail, exit 1" {
  cat > "$FAKE_BIN/brew" <<EOF
#!/bin/sh
echo "brew \$*" >> "$STUB/brew.log"
exit 0
EOF
  run_it --allow-install
  [ "$status" -eq 1 ]
  [ "$(step_status install)" = "fail" ]
}

@test "unrecognised platform via env override: prints docs URL, needs-user-action, installer never called" {
  export JENGA_CONNECT_PLATFORM=plan9
  run_it --allow-install
  [ "$status" -eq 3 ]
  [ "$(step_status install)" = "needs-user-action" ]
  [[ "$output" == *"https://example.invalid/fakeservice/install"* ]] || false
  [ ! -e "$STUB/brew.log" ]
}

@test "unrecognised platform via a stub uname: same fallback, installer never called" {
  unset JENGA_CONNECT_PLATFORM
  printf '#!/bin/sh\necho Plan9\n' > "$FAKE_BIN/uname"; chmod +x "$FAKE_BIN/uname"
  run_it --allow-install
  [ "$status" -eq 3 ]
  [ "$(step_status install)" = "needs-user-action" ]
  [[ "$output" == *"https://example.invalid/fakeservice/install"* ]] || false
  [ ! -e "$STUB/brew.log" ]
}

@test "known platform but no install method for it: docs URL fallback, nothing run" {
  edit '.install.methods = [{"platform":"linux","manager":"npm","package":"fakecli"}]'
  run_it --allow-install
  [ "$status" -eq 3 ]
  [ "$(step_status install)" = "needs-user-action" ]
  [[ "$output" == *"https://example.invalid/fakeservice/install"* ]] || false
  [ ! -e "$STUB/brew.log" ]
}

@test "a prerequisite referenced by diamond and duplicate requires runs exactly once" {
  touch "$STUB/installed" "$STUB/authed"
  for id in prereq-c; do
    jq -n --arg id "$id" '{id:$id,name:"C",docs:["https://example.invalid/c"],
      detect:{command:["prereqcli","--version"]},
      install:{docs_url:"https://example.invalid/c/install"},
      auth:{type:"none"},register_mcp:{supported:false},
      verify:{command:["prereqcli","verify"]}}' > "$DESC/$id.json"
  done
  jq -n '{id:"prereq-b",name:"B",docs:["https://example.invalid/b"],requires:["prereq-c"],
      detect:{command:["prereqcli","verify"]},
      install:{docs_url:"https://example.invalid/b/install"},
      auth:{type:"none"},register_mcp:{supported:false},
      verify:{command:["prereqcli","verify"]}}' > "$DESC/prereq-b.json"
  edit '.requires = ["prereq-b","prereq-c","prereq-c"]'
  run_it
  [ "$status" -eq 0 ]
  [ "$(wc -l < "$STUB/prereq.count" | tr -d ' ')" -eq 1 ]
  # the repeat references are reported as reused, not re-run
  [ "$(jq -r 'select(.step == "requires:prereq-c") | .status' <<<"$output" | paste -sd, -)" = "pass,skipped,skipped" ]
}

@test "missing prerequisite descriptor fails the run before the service's own steps" {
  touch "$STUB/installed" "$STUB/authed"
  edit '.requires = ["does-not-exist"]'
  run_it
  [ "$status" -eq 1 ]
  [ "$(step_status "requires:does-not-exist")" = "fail" ]
  [ -z "$(step_status detect)" ]
}

@test "invalid descriptor is rejected before any step runs" {
  touch "$STUB/installed"
  run bash "$RUN" "$FX/invalid-missing-verify.json" --project-root "$PROJ" --allow-install
  [ "$status" -eq 2 ]
  [ -z "$(printf '%s' "$output" | jq -c 'select(.step != null)' 2>/dev/null)" ]
  [ ! -e "$STUB/fakecli.log" ]
  [ ! -e "$STUB/brew.log" ]
}

@test "env-token auth: guardrail ignores .env BEFORE the placeholder is written; sentinel never printed" {
  touch "$STUB/installed"
  export FAKESERVICE_TOKEN="$SENTINEL"
  run_it
  [ "$status" -eq 3 ]
  [ "$(step_status auth)" = "needs-user-action" ]
  git -C "$PROJ" check-ignore -q .env
  [ "$(cat "$PROJ/.env")" = "FAKESERVICE_TOKEN=" ]
  [[ "$output$stderr" != *"$SENTINEL"* ]] || false
  ! grep -rqF "$SENTINEL" "$PROJ" --include=.env --include=.gitignore --include=.mcp.json
}

@test "env-token auth: when the guardrail refuses (tracked .env) the step fails and nothing is written" {
  touch "$STUB/installed"
  printf 'EXISTING=1\n' > "$PROJ/.env"
  git -C "$PROJ" add -f .env && git -C "$PROJ" commit -q -m tracked
  cp "$PROJ/.env" "$BATS_TEST_TMPDIR/env.before"
  export FAKESERVICE_TOKEN="$SENTINEL"
  run_it
  [ "$status" -eq 1 ]
  [ "$(step_status auth)" = "fail" ]
  cmp "$PROJ/.env" "$BATS_TEST_TMPDIR/env.before"
  [ ! -e "$PROJ/.mcp.json" ]
  [[ "$output$stderr" != *"$SENTINEL"* ]] || false
}

@test "tool output containing a token never reaches the results" {
  touch "$STUB/installed" "$STUB/authed"
  export FAKESERVICE_TOKEN="$SENTINEL"   # the fakecli whoami stub echoes it
  run_it
  [ "$status" -eq 0 ]
  [[ "$output$stderr" != *"$SENTINEL"* ]] || false
  ! grep -qF "$SENTINEL" "$PROJ/.mcp.json"
}

@test "browser auth: needs-user-action with the docs URL; consent is never attempted" {
  touch "$STUB/installed"
  edit '.auth.type = "browser" | del(.auth.env_var)'
  run_it
  [ "$status" -eq 3 ]
  [ "$(step_status auth)" = "needs-user-action" ]
  [[ "$output" == *"https://example.invalid/fakeservice/auth"* ]] || false
  [ ! -e "$PROJ/.env" ]
}

@test "register_mcp not supported: skipped and no .mcp.json is created" {
  touch "$STUB/installed" "$STUB/authed"
  run bash "$RUN" "$FX/valid-no-mcp.json" --project-root "$PROJ"
  [ "$status" -eq 0 ]
  [ "$(step_status register_mcp)" = "skipped" ]
  [ ! -e "$PROJ/.mcp.json" ]
}

@test "second run: registration is reported unchanged and the file is identical" {
  touch "$STUB/installed" "$STUB/authed"
  run_it
  [ "$status" -eq 0 ]
  cp "$PROJ/.mcp.json" "$BATS_TEST_TMPDIR/first"
  run_it
  [ "$status" -eq 0 ]
  [ "$(step_status register_mcp)" = "skipped" ]
  [ "$(jq -r 'select(.step == "register_mcp") | .detail' <<<"$output")" = "unchanged" ]
  cmp "$PROJ/.mcp.json" "$BATS_TEST_TMPDIR/first"
}

@test "failing verify is a fail (exit 1); --continue still runs later steps after an earlier fail" {
  touch "$STUB/installed"   # authed missing => auth check fails => needs-user-action
  run_it --continue
  [ "$status" -eq 1 ]
  [ "$(step_status auth)" = "needs-user-action" ]
  [ "$(step_status register_mcp)" = "pass" ]
  [ "$(step_status verify)" = "fail" ]
}

@test "--step runs only the named step" {
  touch "$STUB/installed" "$STUB/authed"
  run_it --step verify
  [ "$status" -eq 0 ]
  [ "$(steps_in_order)" = "verify" ]
  [ ! -e "$PROJ/.mcp.json" ]
}

@test "usage errors exit 2" {
  run bash "$RUN"
  [ "$status" -eq 2 ]
  run bash "$RUN" "$DESC/fakeservice.json" --step bogus
  [ "$status" -eq 2 ]
  run bash "$RUN" "$DESC/nope.json"
  [ "$status" -eq 2 ]
}
