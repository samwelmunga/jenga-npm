#!/usr/bin/env bash
set -u

EXIT_ENV_INVALID=4

# Usage: validate_droplet_env.sh <publish_json_path> <target_name>

CONFIG_PATH="${1:-}"
TARGET_NAME="${2:-}"

fail() {
  printf 'droplet env validation failed: %s\n' "$1" >&2
  exit "$EXIT_ENV_INVALID"
}

[[ -n "$CONFIG_PATH" ]] || fail "missing publish.json path argument"
[[ -f "$CONFIG_PATH" ]] || fail "publish config not found at '$CONFIG_PATH'"
command -v jq >/dev/null 2>&1 || fail "jq is required but not found on PATH"
[[ -n "$TARGET_NAME" ]] || fail "missing target name argument"

# Extract the droplet target block
TARGET_JSON="$(jq -c --arg t "$TARGET_NAME" \
  '.targets[]? | select(.name == $t and .type == "droplet")' \
  "$CONFIG_PATH")"
[[ -n "$TARGET_JSON" ]] || fail "target '$TARGET_NAME' was not found or is not type 'droplet' in '$CONFIG_PATH'"

check_field() {
  local label="$1"
  local value
  value="$(printf '%s' "$TARGET_JSON" | jq -r "$2 // empty" 2>/dev/null || true)"
  if [[ -z "$value" ]]; then
    fail "missing required field '$label'"
  fi
}

check_field "host"              '.droplet.host'
check_field "ssh_user"          '.droplet.ssh_user'
check_field "deploy_path"       '.droplet.deploy_path'
check_field "github_repo"       '.droplet.github_repo'
check_field "deploy_branch"     '.droplet.deploy_branch'
check_field "start_cmd"         '.droplet.start_cmd'
check_field "ssh_key_secret"    '.secrets.ssh_key_secret'
check_field "known_hosts_secret" '.secrets.known_hosts_secret'

exit 0
