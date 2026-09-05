#!/usr/bin/env bash
set -u

CONFIG_PATH="${1:-}"
TARGET_NAME="${2:-}"
EXIT_ENV_INVALID=4

fail() {
  printf 'iOS env validation failed: %s\n' "$1" >&2
  exit "$EXIT_ENV_INVALID"
}

[[ -n "$CONFIG_PATH" ]] || fail "missing publish.json path argument"
[[ -f "$CONFIG_PATH" ]] || fail "publish config not found at '$CONFIG_PATH'"
command -v jq >/dev/null 2>&1 || fail "jq is required"

if [[ -n "$TARGET_NAME" ]]; then
  jq -e --arg target "$TARGET_NAME" '.targets[]? | select(.name == $target and .type == "mobile-ios")' "$CONFIG_PATH" >/dev/null 2>&1 || \
    fail "target '$TARGET_NAME' was not found or is not mobile-ios"
fi

REQUIRED_VARS=()
while IFS= read -r var_name; do
  [[ -n "$var_name" ]] && REQUIRED_VARS+=("$var_name")
done < <(
  jq -r --arg target "$TARGET_NAME" '
    [
      .targets[]?
      | select(.type == "mobile-ios")
      | if $target == "" then . else select(.name == $target) end
      | [
          .secrets.app_store_connect_api_key_id?,
          .secrets.app_store_connect_issuer_id?,
          .secrets.app_store_connect_private_key_path?,
          .secrets.code_sign_identity?,
          .secrets.provisioning_profile_uuid?
        ][]
      | select(type == "string" and length > 0)
      | sub("^\\$\\{"; "")
      | sub("^\\$"; "")
      | sub("\\}$"; "")
    ]
    | unique
    | .[]
  ' "$CONFIG_PATH"
)

if [[ ${#REQUIRED_VARS[@]} -eq 0 ]]; then
  if [[ -n "$TARGET_NAME" ]]; then
    fail "no mobile-ios env-var references were found for target '$TARGET_NAME'"
  fi
  fail "no mobile-ios env-var references were found in '$CONFIG_PATH'"
fi

MISSING_VARS=()
for var_name in "${REQUIRED_VARS[@]}"; do
  value="$(printenv "$var_name" 2>/dev/null || true)"
  if [[ -z "$value" ]]; then
    MISSING_VARS+=("$var_name")
  fi
done

if [[ ${#MISSING_VARS[@]} -gt 0 ]]; then
  printf 'Missing required iOS environment variables: %s\n' "${MISSING_VARS[*]}" >&2
  exit "$EXIT_ENV_INVALID"
fi

exit 0
