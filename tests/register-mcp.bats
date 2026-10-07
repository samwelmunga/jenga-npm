#!/usr/bin/env bats
#
# Coverage for skills/j-connect/scripts/register-mcp.sh (E65_S01_T04).
# The target is project-root .mcp.json, per project/documentation/mcp-registration-decision.md.

load helpers/assertions

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
REG="$REPO_ROOT/skills/j-connect/scripts/register-mcp.sh"
SENTINEL="SENTINEL-ENV-VALUE-5d2e8b01"

setup() {
  PROJ="$BATS_TEST_TMPDIR/proj"
  mkdir -p "$PROJ"
  TARGET="$PROJ/.mcp.json"
}

register() { # <name> [extra args...]
  local n="$1"; shift
  bash "$REG" --name "$n" --command fakecli --arg mcp --arg serve --project-root "$PROJ" "$@"
}

@test "writes to <project_root>/.mcp.json (the location named in the decision doc)" {
  grep -q '\.mcp\.json' "$REPO_ROOT/project/documentation/mcp-registration-decision.md"
  run register svc-a --env-name SVC_A_TOKEN
  [ "$status" -eq 0 ]
  [ "$(jq -r .status <<<"$output")" = "added" ]
  [ "$(jq -r .file <<<"$output")" = "$(cd "$PROJ" && pwd)/.mcp.json" ]
  [ "$(jq -r .server <<<"$output")" = "svc-a" ]
  [ -f "$TARGET" ]
  [ ! -e "$PROJ/.claude/settings.json" ]
  [ ! -e "$PROJ/.agents/settings.json" ]
  [ "$(jq -c '.mcpServers["svc-a"]' "$TARGET")" = '{"type":"stdio","command":"fakecli","args":["mcp","serve"],"env":{"SVC_A_TOKEN":"${SVC_A_TOKEN}"}}' ]
}

@test "re-run with identical input is unchanged and the file is byte-identical" {
  register svc-a --env-name SVC_A_TOKEN
  cp "$TARGET" "$BATS_TEST_TMPDIR/before"
  run register svc-a --env-name SVC_A_TOKEN
  [ "$status" -eq 0 ]
  [ "$(jq -r .status <<<"$output")" = "unchanged" ]
  cmp "$TARGET" "$BATS_TEST_TMPDIR/before"
}

@test "third server is added; two other servers and the hooks block are semantically preserved" {
  cat > "$TARGET" <<'EOF'
{
  "hooks": {"SessionEnd": [{"hooks": [{"type": "command", "command": "echo bye"}]}]},
  "mcpServers": {
    "one": {"type": "stdio", "command": "one-cmd", "args": ["x"]},
    "two": {"type": "http", "url": "https://example.invalid/mcp"}
  },
  "permissions": {"allow": ["Bash(ls)"]}
}
EOF
  jq -S . "$TARGET" > "$BATS_TEST_TMPDIR/orig.json"
  run register three
  [ "$status" -eq 0 ]
  [ "$(jq -r .status <<<"$output")" = "added" ]
  [ "$(jq -cS '.hooks' "$TARGET")" = "$(jq -cS '.hooks' "$BATS_TEST_TMPDIR/orig.json")" ]
  [ "$(jq -cS '.permissions' "$TARGET")" = "$(jq -cS '.permissions' "$BATS_TEST_TMPDIR/orig.json")" ]
  [ "$(jq -cS '.mcpServers.one' "$TARGET")" = "$(jq -cS '.mcpServers.one' "$BATS_TEST_TMPDIR/orig.json")" ]
  [ "$(jq -cS '.mcpServers.two' "$TARGET")" = "$(jq -cS '.mcpServers.two' "$BATS_TEST_TMPDIR/orig.json")" ]
  [ "$(jq -c '.mcpServers | keys_unsorted' "$TARGET")" = '["one","two","three"]' ]
  [ "$(jq -c 'keys' "$TARGET")" = '["hooks","mcpServers","permissions"]' ]
}

@test "same name with different config is updated in place, once, without duplicates" {
  register one
  register two
  run bash "$REG" --name one --command other-cmd --project-root "$PROJ"
  [ "$status" -eq 0 ]
  [ "$(jq -r .status <<<"$output")" = "updated" ]
  [ "$(jq -c '.mcpServers | keys_unsorted' "$TARGET")" = '["one","two"]' ]
  [ "$(jq -r '.mcpServers.one.command' "$TARGET")" = "other-cmd" ]
  [ "$(jq -r '.mcpServers.two.command' "$TARGET")" = "fakecli" ]
  [ "$(grep -c '"one"' "$TARGET")" -eq 1 ]
}

@test "http server entries are supported" {
  run bash "$REG" --name remote --type http --url https://example.invalid/mcp --project-root "$PROJ"
  [ "$status" -eq 0 ]
  [ "$(jq -c '.mcpServers.remote' "$TARGET")" = '{"type":"http","url":"https://example.invalid/mcp"}' ]
}

@test "unparseable existing JSON: non-zero, file unmodified, JSON error on stdout" {
  printf '{ this is not json' > "$TARGET"
  cp "$TARGET" "$BATS_TEST_TMPDIR/before"
  run register svc-a
  [ "$status" -eq 1 ]
  cmp "$TARGET" "$BATS_TEST_TMPDIR/before"
  [ "$(jq -r .status <<<"$(printf '%s\n' "$output" | head -n1)")" = "error" ]
}

@test "non-object mcpServers is refused and left untouched" {
  printf '{"mcpServers": []}\n' > "$TARGET"
  cp "$TARGET" "$BATS_TEST_TMPDIR/before"
  run register svc-a
  [ "$status" -eq 1 ]
  cmp "$TARGET" "$BATS_TEST_TMPDIR/before"
}

@test "no leftover temp files after success or failure" {
  register svc-a
  printf 'garbage' > "$TARGET"
  run register svc-b
  [ "$status" -eq 1 ]
  [ -z "$(ls -A "$PROJ" | grep -v '^\.mcp\.json$' || true)" ]
}

@test "sentinel env value present in the environment never reaches the file or output" {
  export SVC_A_TOKEN="$SENTINEL"
  run register svc-a --env-name SVC_A_TOKEN
  [ "$status" -eq 0 ]
  [[ "$output" != *"$SENTINEL"* ]] || false
  ! grep -qF "$SENTINEL" "$TARGET"
  grep -qF '${SVC_A_TOKEN}' "$TARGET"
}

@test "NAME=VALUE and credential-shaped inputs are refused without echoing the value" {
  run register svc-a --env-name "SVC_A_TOKEN=$SENTINEL"
  [ "$status" -eq 2 ]
  [[ "$output" != *"$SENTINEL"* ]] || false
  [ ! -e "$TARGET" ]
  local fake="gh""p_0123456789abcdefghijklmnopqrstuvwxyz0123"
  run register svc-a --arg "$fake"
  [ "$status" -eq 2 ]
  [[ "$output" != *"ghp_0123"* ]] || false
  [ ! -e "$TARGET" ]
}

@test "usage errors exit 2: missing name/command, bad type, bad name" {
  run bash "$REG" --command x --project-root "$PROJ"
  [ "$status" -eq 2 ]
  run bash "$REG" --name x --project-root "$PROJ"
  [ "$status" -eq 2 ]
  run bash "$REG" --name x --type bogus --command y --project-root "$PROJ"
  [ "$status" -eq 2 ]
  run bash "$REG" --name 'bad name' --command y --project-root "$PROJ"
  [ "$status" -eq 2 ]
  [ ! -e "$TARGET" ]
}

@test "--help prints usage and exits 0" {
  run bash "$REG" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"Usage:"* ]] || false
}
