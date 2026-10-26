#!/usr/bin/env bats
#
# E85_S04_T04: /publish setup and the per-type env validation for npm and npm-ci targets end by showing the
# one-time dependency-audit opt-in notice from scripts/audit-notice.sh (through audit_notice_hook.sh). Whether it
# is due is audit-notice.sh's decision alone; these cases only prove the hook points, the shared marker, the
# target-type scoping and that the notice can never change an exit code.
#
# Every case runs against a throwaway project under BATS_TEST_TMPDIR with stubbed npm and gh on PATH: nothing is
# published or sent anywhere, and this repository's configs and data directory are never touched
# (JENGA_PROJECT_ROOT points at the throwaway project).

bats_require_minimum_version 1.5.0

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
NOTICE_TEXT="Dependency audits are not running yet"

setup() {
  unset CI GITHUB_ACTIONS NODE_AUTH_TOKEN
  P="$BATS_TEST_TMPDIR/proj"
  export JENGA_PROJECT_ROOT="$P"
  mkdir -p "$P/skills" "$P/scripts" "$P/project/configs" "$P/bin"
  cp -R "$REPO_ROOT/skills/j-publish" "$P/skills/j-publish"
  local s
  for s in audit-notice.sh resolve-root.sh with-lock.sh; do
    cp "$REPO_ROOT/scripts/$s" "$P/scripts/"
  done
  cp "$REPO_ROOT/project/configs/workflow.json" "$P/project/configs/workflow.json"
  SCRIPTS="$P/skills/j-publish/scripts"
  PUBLISH_JSON="$P/publish.json"
  MARKER="$P/project/data/audit-notice-shown"
  jq -n '{version:1,targets:[
    {name:"n",type:"npm",npm:{package_name:"fixture-pkg",access:"public"}},
    {name:"c",type:"npm-ci",github_repo:"owner/name",npm:{package_name:"fixture-pkg",access:"public"}},
    {name:"d",type:"droplet"},{name:"i",type:"mobile-ios"}]}' > "$PUBLISH_JSON"
  # npm needs only to exist on PATH; gh must report "signed in". Neither contacts anything.
  printf '#!/bin/sh\nexit 0\n' > "$P/bin/npm"
  printf '#!/bin/sh\nexit 0\n' > "$P/bin/gh"
  chmod +x "$P/bin/npm" "$P/bin/gh"
  export PATH="$P/bin:$PATH"
  export NPM_TOKEN="fixture-not-a-real-token"
  audit_mode ask
}

audit_mode() { # <mode>
  printf '{"config_version":2,"mode":"%s"}\n' "$1" > "$P/project/configs/audit-config.json"
}

# The four surfaces that must show the notice. setup is driven non-interactively: with a target name, --type and
# --config the npm and npm-ci branches never prompt.
npm_setup()         { bash "$SCRIPTS/setup_wizard.sh" n --type npm --config "$PUBLISH_JSON"; }
npm_ci_setup()      { bash "$SCRIPTS/setup_wizard.sh" c --type npm-ci --config "$PUBLISH_JSON"; }
npm_validate()      { bash "$SCRIPTS/validate_npm_env.sh" "$PUBLISH_JSON" n; }
npm_ci_validate()   { bash "$SCRIPTS/validate_npm_ci_env.sh" "$PUBLISH_JSON" c; }

count_notice() { # <text> -> number of notice headings in the text
  printf '%s\n' "$1" | grep -c "$NOTICE_TEXT" || true
}

assert_notice_once_then_silent() { # <surface function name>
  run --separate-stderr "$1"
  [ "$status" -eq 0 ]
  [ "$(count_notice "$output")" -eq 1 ]
  [ -f "$MARKER" ]
  run --separate-stderr "$1"
  [ "$status" -eq 0 ]
  [ "$(count_notice "$output")" -eq 0 ]
}

# ---- mode ask, no marker: printed once ------------------------------------------------------------------

@test "npm setup prints the notice once and exits 0; a second run prints nothing" {
  assert_notice_once_then_silent npm_setup
}

@test "npm-ci setup prints the notice once and exits 0; a second run prints nothing" {
  assert_notice_once_then_silent npm_ci_setup
}

@test "npm env validation prints the notice once and exits 0; a second run prints nothing" {
  assert_notice_once_then_silent npm_validate
}

@test "npm-ci env validation prints the notice once and exits 0; a second run prints nothing" {
  assert_notice_once_then_silent npm_ci_validate
}

@test "the notice comes after the setup hand-off message and after the validation OK line" {
  run npm_ci_validate
  [ "$status" -eq 0 ]
  [[ "$output" == *"[validate] environment OK"* ]]
  [[ "${output#*"[validate] environment OK"}" == *"$NOTICE_TEXT"* ]]
}

@test "the notice is shared across surfaces: seen from setup, validation stays silent" {
  run npm_setup
  [ "$status" -eq 0 ]
  [[ "$output" == *"$NOTICE_TEXT"* ]]
  run npm_validate
  [ "$status" -eq 0 ]
  [[ "$output" != *"$NOTICE_TEXT"* ]]
  run npm_ci_validate
  [ "$status" -eq 0 ]
  [[ "$output" != *"$NOTICE_TEXT"* ]]
}

@test "the notice works when the caller's cwd is elsewhere (resolution does not depend on \$PWD)" {
  cd "$BATS_TEST_TMPDIR"
  run npm_validate
  [ "$status" -eq 0 ]
  [[ "$output" == *"$NOTICE_TEXT"* ]]
}

# ---- modes on and off: never printed --------------------------------------------------------------------

@test "audit mode on never prints the notice on any npm surface" {
  audit_mode on
  local f
  for f in npm_setup npm_ci_setup npm_validate npm_ci_validate; do
    run "$f"
    [ "$status" -eq 0 ]
    [[ "$output" != *"$NOTICE_TEXT"* ]]
  done
  [ ! -f "$MARKER" ]
}

@test "audit mode off never prints the notice on any npm surface" {
  audit_mode off
  local f
  for f in npm_setup npm_ci_setup npm_validate npm_ci_validate; do
    run "$f"
    [ "$status" -eq 0 ]
    [[ "$output" != *"$NOTICE_TEXT"* ]]
  done
  [ ! -f "$MARKER" ]
}

# ---- shared marker with j.init -------------------------------------------------------------------------

@test "a marker written by j.init's notice suppresses the publish notice" {
  run bash "$P/scripts/audit-notice.sh" show --context init
  [ "$status" -eq 0 ]
  [[ "$output" == *"$NOTICE_TEXT"* ]]
  [ -f "$MARKER" ]
  local f
  for f in npm_setup npm_ci_setup npm_validate npm_ci_validate; do
    run "$f"
    [ "$status" -eq 0 ]
    [[ "$output" != *"$NOTICE_TEXT"* ]]
  done
}

# ---- target-type scoping ---------------------------------------------------------------------------------

@test "droplet env validation never prints the notice and the validator does not reference the hook" {
  run bash "$SCRIPTS/validate_droplet_env.sh" "$PUBLISH_JSON" d
  [[ "$output" != *"$NOTICE_TEXT"* ]]
  [ ! -f "$MARKER" ]
  run grep -q "audit_notice_hook\|audit-notice" "$REPO_ROOT/skills/j-publish/scripts/validate_droplet_env.sh"
  [ "$status" -ne 0 ]
}

@test "mobile-ios env validation never prints the notice and the validator does not reference the hook" {
  run bash "$SCRIPTS/validate_ios_env.sh" "$PUBLISH_JSON" i
  [[ "$output" != *"$NOTICE_TEXT"* ]]
  [ ! -f "$MARKER" ]
  run grep -q "audit_notice_hook\|audit-notice" "$REPO_ROOT/skills/j-publish/scripts/validate_ios_env.sh"
  [ "$status" -ne 0 ]
}

@test "setup for mobile-ios (cancelled at its first prompt) and for droplet (unsupported type) never prints the notice" {
  run bash "$SCRIPTS/setup_wizard.sh" i --type mobile-ios --config "$PUBLISH_JSON" </dev/null
  [[ "$output" != *"$NOTICE_TEXT"* ]]
  run bash "$SCRIPTS/setup_wizard.sh" d --type droplet --config "$PUBLISH_JSON" </dev/null
  [[ "$output" != *"$NOTICE_TEXT"* ]]
  [ ! -f "$MARKER" ]
}

# ---- the notice can never change an exit code ---------------------------------------------------------------

@test "a failing validation keeps its exit code and prints no notice" {
  unset NPM_TOKEN NODE_AUTH_TOKEN
  run npm_validate
  [ "$status" -eq 4 ]
  [[ "$output" != *"$NOTICE_TEXT"* ]]
  [ ! -f "$MARKER" ]
}

@test "a missing audit-notice.sh leaves every exit code at 0 and prints nothing extra" {
  rm -f "$P/scripts/audit-notice.sh"
  local f
  for f in npm_setup npm_ci_setup npm_validate npm_ci_validate; do
    run "$f"
    [ "$status" -eq 0 ]
    [[ "$output" != *"$NOTICE_TEXT"* ]]
    [[ "$output" != *"audit_notice_hook"* ]]
  done
}

@test "a failing audit-notice.sh leaves every exit code at 0 and leaves one stderr note" {
  printf '#!/bin/sh\necho boom >&2\nexit 1\n' > "$P/scripts/audit-notice.sh"
  local f
  for f in npm_setup npm_ci_setup npm_validate npm_ci_validate; do
    run "$f"
    [ "$status" -eq 0 ]
    [[ "$output" == *"audit_notice_hook: audit-notice.sh failed"* ]]
    [[ "$output" != *"boom"* ]]
  done
}

@test "a missing hook helper leaves validation and setup exit codes at 0" {
  rm -f "$SCRIPTS/audit_notice_hook.sh"
  local f
  for f in npm_setup npm_ci_setup npm_validate npm_ci_validate; do
    run "$f"
    [ "$status" -eq 0 ]
    [[ "$output" != *"$NOTICE_TEXT"* ]]
  done
}

@test "a malformed audit-config.json (audit-notice.sh exits 2) does not fail setup or validate" {
  printf 'not json\n' > "$P/project/configs/audit-config.json"
  local f
  for f in npm_setup npm_ci_setup npm_validate npm_ci_validate; do
    run "$f"
    [ "$status" -eq 0 ]
    [[ "$output" != *"$NOTICE_TEXT"* ]]
  done
}

# ---- scope guards on the change itself --------------------------------------------------------------------

@test "the hook helper is executable and run_gates.sh does not reference it" {
  [ -x "$REPO_ROOT/skills/j-publish/scripts/audit_notice_hook.sh" ]
  run grep -q "audit_notice_hook\|audit-notice.sh show" "$REPO_ROOT/skills/j-publish/scripts/run_gates.sh"
  [ "$status" -ne 0 ]
}
