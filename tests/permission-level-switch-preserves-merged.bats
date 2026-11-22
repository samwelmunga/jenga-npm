#!/usr/bin/env bats
# bats file_tags=tier:unit
#
# E100_S04_T04: a permission-level switch in every direction class leaves the
# merged entries (hooks, permissions.allow, env, unrelated keys) of both
# settings files intact, and sets the level policy to the target template's.
# Sandbox only: never touches the repository's real .claude/, .agents/ or level file.

load helpers/assertions

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd -P)"
SWITCH="${SWITCH_SCRIPT:-$REPO_ROOT/scripts/jenga-permission-level-switch.sh}"
TPL_DIR="$REPO_ROOT/templates/permission-levels"

setup() {
  SANDBOX="$(cd "$(mktemp -d "$BATS_TEST_TMPDIR/sb.XXXXXX")" && pwd -P)"
  git init -q "$SANDBOX"
  mkdir -p "$SANDBOX/.claude" "$SANDBOX/.agents"
  for d in .claude .agents; do
    cat > "$SANDBOX/$d/settings.json" <<'JSON'
{"statusLine":{"type":"command","command":"x"},
 "env":{"CLIENT_VAR":"1","JENGA_X":"2"},
 "permissions":{"allow":["Bash(client *)","Bash(jenga *)"],"deny":["Bash(old *)"]},
 "hooks":{"PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"exec hooks/on_preflight_check.sh"},{"type":"command","command":"client-pre"}]}],"Stop":[{"hooks":[{"type":"command","command":"client-stop"}]}]},
 "defaultMode":"default"}
JSON
  done
  cp "$SANDBOX/.claude/settings.json" "$BATS_TEST_TMPDIR/before.json"
}

teardown() { rm -rf "$SANDBOX"; }

tpl() { ls "$TPL_DIR"/level-"$1"-*.json; }

switch() { bash -c 'cd "$1" && bash "$2" "$3"' _ "$SANDBOX" "$SWITCH" "$1"; }

# Asserts both files keep every merged key whole and carry level $1's policy.
assert_preserved_and_level() {
  local n="$1" d k T
  T="$(tpl "$n")"
  for d in .claude .agents; do
    local F="$SANDBOX/$d/settings.json"
    for k in .hooks .permissions.allow .env .statusLine; do
      [ "$(jq -S "$k" "$F")" = "$(jq -S "$k" "$BATS_TEST_TMPDIR/before.json")" ]
    done
    [ "$(jq -S .defaultMode "$F")" = "$(jq -S .defaultMode "$T")" ]
    [ "$(jq -S .permissions.deny "$F")" = "$(jq -S .permissions.deny "$T")" ]
    [ "$(jq -S .autoMode "$F")" = "$(jq -S .autoMode "$T")" ]
  done
  [ "$(jq .session_level "$SANDBOX/.jenga-permission-level.json")" = "$n" ]
}

@test "up (2 to 4) preserves merged entries" {
  run switch 2; [ "$status" -eq 0 ]
  run switch 4; [ "$status" -eq 0 ]
  assert_preserved_and_level 4
}

@test "down (4 to 2) preserves merged entries" {
  run switch 4; [ "$status" -eq 0 ]
  run switch 2; [ "$status" -eq 0 ]
  assert_preserved_and_level 2
}

@test "extremes (1 to 5 and 5 to 1) preserve merged entries" {
  run switch 1; [ "$status" -eq 0 ]
  run switch 5; [ "$status" -eq 0 ]
  assert_preserved_and_level 5
  run switch 1; [ "$status" -eq 0 ]
  assert_preserved_and_level 1
}

@test "same level (3 to 3) is a no-op for the preserved keys" {
  run switch 3; [ "$status" -eq 0 ]
  cp "$SANDBOX/.claude/settings.json" "$BATS_TEST_TMPDIR/after-first.json"
  run switch 3; [ "$status" -eq 0 ]
  assert_preserved_and_level 3
  [ "$(jq -S . "$SANDBOX/.claude/settings.json")" = "$(jq -S . "$BATS_TEST_TMPDIR/after-first.json")" ]
}

@test "a two-step sequence (2 to 5 to 1) erodes nothing" {
  run switch 2; [ "$status" -eq 0 ]
  assert_preserved_and_level 2
  run switch 5; [ "$status" -eq 0 ]
  assert_preserved_and_level 5
  run switch 1; [ "$status" -eq 0 ]
  assert_preserved_and_level 1
}

@test "edge: a destination with no settings files is created with owned keys only" {
  rm -rf "$SANDBOX/.claude" "$SANDBOX/.agents"
  run switch 4
  [ "$status" -eq 0 ]
  for d in .claude .agents; do
    run jq -c 'keys - ["autoMode","defaultMode","permissions"]' "$SANDBOX/$d/settings.json"
    [ "$output" = "[]" ]
    run jq -c '.permissions | keys - ["deny","ask"]' "$SANDBOX/$d/settings.json"
    [ "$output" = "[]" ]
  done
  [ "$(jq .session_level "$SANDBOX/.jenga-permission-level.json")" = "4" ]
}

@test "edge: an unparseable destination exits 3 and is left unchanged" {
  echo '{bad' > "$SANDBOX/.claude/settings.json"
  run switch 4
  [ "$status" -eq 3 ]
  [ "$(cat "$SANDBOX/.claude/settings.json")" = '{bad' ]
  [ "$(jq -S . "$SANDBOX/.agents/settings.json")" = "$(jq -S . "$BATS_TEST_TMPDIR/before.json")" ]
  [ ! -f "$SANDBOX/.jenga-permission-level.json" ]
}
