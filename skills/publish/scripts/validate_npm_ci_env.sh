#!/usr/bin/env bash
set -u

EXIT_ENV_INVALID=4

# Usage: validate_npm_ci_env.sh <publish_json_path> <target_name>

CONFIG_PATH="${1:-}"
TARGET_NAME="${2:-}"

fail() {
  printf '[validate] ERROR: %s\n' "$1" >&2
  exit "$EXIT_ENV_INVALID"
}

# ── runtime dependency checks ──────────────────────────────────────────────────

command -v gh >/dev/null 2>&1 || fail "gh CLI is required but not found on PATH. Install it from https://cli.github.com/ and re-run."

gh auth status >/dev/null 2>&1 || fail "gh CLI is not authenticated. Run 'gh auth login' and re-run."

command -v jq >/dev/null 2>&1 || fail "jq is required but not found on PATH. Install it from https://stedolan.github.io/jq/ and re-run."

# ── config argument checks ─────────────────────────────────────────────────────

[[ -n "$CONFIG_PATH" ]] || fail "missing publish.json path argument"
[[ -f "$CONFIG_PATH" ]] || fail "publish config not found at '$CONFIG_PATH'"
[[ -n "$TARGET_NAME" ]] || fail "missing target name argument"

# ── extract the npm-ci target block ───────────────────────────────────────────

TARGET_JSON="$(jq -c --arg t "$TARGET_NAME" \
  '.targets[]? | select(.name == $t and .type == "npm-ci")' \
  "$CONFIG_PATH")"
[[ -n "$TARGET_JSON" ]] || fail "target '$TARGET_NAME' was not found or is not type 'npm-ci' in '$CONFIG_PATH'"

# ── field validators ───────────────────────────────────────────────────────────

check_field() {
  local label="$1"
  local value
  value="$(printf '%s' "$TARGET_JSON" | jq -r "$2 // empty" 2>/dev/null || true)"
  if [[ -z "$value" ]]; then
    fail "missing required field '$label'"
  fi
}

# github_repo — required at the target level (not nested under .npm)
check_field "github_repo" '.github_repo'

# Verify github_repo contains exactly one '/'
GITHUB_REPO="$(printf '%s' "$TARGET_JSON" | jq -r '.github_repo // empty' 2>/dev/null || true)"
SLASH_COUNT="${GITHUB_REPO//[!\/]}"
if [[ ${#SLASH_COUNT} -ne 1 ]]; then
  fail "field 'github_repo' must be in 'owner/name' format (contains exactly one '/'), got: '$GITHUB_REPO'"
fi

# npm.package_name — required
check_field "npm.package_name" '.npm.package_name'

# npm.access — required; must be 'public' or 'restricted'
check_field "npm.access" '.npm.access'
NPM_ACCESS="$(printf '%s' "$TARGET_JSON" | jq -r '.npm.access // empty' 2>/dev/null || true)"
if [[ "$NPM_ACCESS" != "public" && "$NPM_ACCESS" != "restricted" ]]; then
  fail "field 'npm.access' must be 'public' or 'restricted', got: '$NPM_ACCESS'"
fi

# ── all checks passed ──────────────────────────────────────────────────────────

printf '[validate] environment OK\n'
exit 0
