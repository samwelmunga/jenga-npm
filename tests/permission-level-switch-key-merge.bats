#!/usr/bin/env bats
# bats file_tags=tier:unit
#
# E100_S04_T01: the permission-level switch merges only the level-policy keys
# (defaultMode, permissions.deny, permissions.ask, autoMode) and leaves
# hooks, permissions.allow, env and every other key as they were.

load helpers/assertions

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
SWITCH="$REPO_ROOT/scripts/jenga-permission-level-switch.sh"
TPL_DIR="$REPO_ROOT/templates/permission-levels"

setup() {
  SANDBOX="$(mktemp -d)"
  git init -q "$SANDBOX"
  mkdir -p "$SANDBOX/.claude" "$SANDBOX/.agents"
  for d in .claude .agents; do
    cat > "$SANDBOX/$d/settings.json" <<'JSON'
{"statusLine":{"type":"command","command":"x"},
 "env":{"CLIENT_VAR":"1","JENGA_X":"2"},
 "permissions":{"allow":["Bash(client *)","Bash(jenga *)"],"deny":["Bash(old *)"],"ask":["Bash(stale *)"]},
 "hooks":{"PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"exec hooks/on_preflight_check.sh"}]}],"Stop":[{"hooks":[{"type":"command","command":"client-stop"}]}]},
 "defaultMode":"default"}
JSON
  done
}

teardown() { rm -rf "$SANDBOX"; }

tpl() { ls "$TPL_DIR"/level-"$1"-*.json; }

switch() { bash -c 'cd "$1" && bash "$2" "$3"' _ "$SANDBOX" "$SWITCH" "$1"; }

@test "hooks, permissions.allow and env are unchanged in both files after a switch" {
  for n in 1 3 5; do
    run switch "$n"
    [ "$status" -eq 0 ]
    for d in .claude .agents; do
      for k in .hooks .permissions.allow .env .statusLine; do
        [ "$(jq -S "$k" "$SANDBOX/$d/settings.json")" = "$(jq -S "$k" <<'JSON'
{"statusLine":{"type":"command","command":"x"},
 "env":{"CLIENT_VAR":"1","JENGA_X":"2"},
 "permissions":{"allow":["Bash(client *)","Bash(jenga *)"]},
 "hooks":{"PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"exec hooks/on_preflight_check.sh"}]}],"Stop":[{"hooks":[{"type":"command","command":"client-stop"}]}]}}
JSON
)" ]
      done
    done
  done
}

@test "defaultMode, permissions.deny and autoMode equal the template; stale permissions.ask is removed" {
  for n in 1 2 3 4 5; do
    run switch "$n"
    [ "$status" -eq 0 ]
    T="$(tpl "$n")"
    for d in .claude .agents; do
      F="$SANDBOX/$d/settings.json"
      [ "$(jq -S .defaultMode "$F")" = "$(jq -S .defaultMode "$T")" ]
      [ "$(jq -S .permissions.deny "$F")" = "$(jq -S .permissions.deny "$T")" ]
      [ "$(jq -S .autoMode "$F")" = "$(jq -S .autoMode "$T")" ]
      [ "$(jq '.permissions.ask' "$F")" = "$(jq '.permissions.ask' "$T")" ]
    done
  done
}

@test "a missing destination is created with only the owned keys" {
  rm -rf "$SANDBOX/.claude" "$SANDBOX/.agents"
  run switch 2
  [ "$status" -eq 0 ]
  for d in .claude .agents; do
    run jq -c 'keys - ["autoMode","defaultMode","permissions"]' "$SANDBOX/$d/settings.json"
    [ "$output" = "[]" ]
    run jq -c '.permissions | keys' "$SANDBOX/$d/settings.json"
    [ "$output" = '["deny"]' ]
  done
}

@test "an unparseable .claude file exits 3 and is unchanged" {
  echo '{bad' > "$SANDBOX/.claude/settings.json"
  run switch 3
  [ "$status" -eq 3 ]
  assert_output_contains ".claude/settings.json"
  [ "$(cat "$SANDBOX/.claude/settings.json")" = '{bad' ]
  [ ! -f "$SANDBOX/.jenga-permission-level.json" ]
}

@test "an unparseable .agents file exits 4 and is unchanged" {
  echo '{bad' > "$SANDBOX/.agents/settings.json"
  run switch 3
  [ "$status" -eq 4 ]
  assert_output_contains ".agents/settings.json"
  [ "$(cat "$SANDBOX/.agents/settings.json")" = '{bad' ]
}

@test "--help exits 0 and writes no file; invalid usage exits 1 and writes none" {
  rm -rf "$SANDBOX/.claude" "$SANDBOX/.agents"
  run bash -c 'cd "$1" && bash "$2" --help' _ "$SANDBOX" "$SWITCH"
  [ "$status" -eq 0 ]
  run bash -c 'cd "$1" && bash "$2" 9' _ "$SANDBOX" "$SWITCH"
  [ "$status" -eq 1 ]
  [ ! -e "$SANDBOX/.claude" ]
  [ ! -e "$SANDBOX/.agents" ]
  [ ! -e "$SANDBOX/.jenga-permission-level.json" ]
}

@test "a second identical switch is idempotent" {
  run switch 4
  A="$(cat "$SANDBOX/.claude/settings.json")"
  run switch 4
  [ "$A" = "$(cat "$SANDBOX/.claude/settings.json")" ]
}

@test "header states the owned keys and no longer says whole-file overwrite" {
  run grep -c "defaultMode, permissions.deny, permissions.ask, autoMode" "$SWITCH"
  [ "$output" -ge 1 ]
  run grep -ci "whole-file overwrite" "$SWITCH"
  [ "$output" = "0" ]
}
