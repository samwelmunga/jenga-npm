#!/usr/bin/env bash
set -u

CONFIG_PATH="${1:-}"
TARGET_NAME="${2:-}"
EXIT_ENV_INVALID=4

fail() {
  printf 'iOS env validation failed: %s\n' "$1" >&2
  exit "$EXIT_ENV_INVALID"
}

# Presence test only (E85_S02_T03). Succeeds when $1 names an exported variable that has a non-empty value; the value
# itself is never assigned to a variable, printed, logged or passed to another command. It reproduces the contract of
# the earlier value-capturing check exactly:
#   - set but empty counts as missing (a bare existence test of the variable would succeed for an empty value);
#   - a name that is not a valid shell identifier counts as missing and never aborts the script (the names come from
#     publish.json strings), which is why the identifier test runs before any indirect expansion;
#   - only exported variables count (the case statement matches the NAME list from compgen -e, so a
#     script-internal shell variable of the same name is not mistaken for the user's environment);
#   - a value made up only of newlines counts as empty, as it did when it was captured with command substitution.
env_var_has_value() {
  [[ "${1:-}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 1
  case $'\n'"$(compgen -e)"$'\n' in
    *$'\n'"$1"$'\n'*) ;;
    *) return 1 ;;
  esac
  [[ -n "${!1:-}" ]] || return 1
  [[ -n "${!1//$'\n'/}" ]]
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
  if ! env_var_has_value "$var_name"; then
    MISSING_VARS+=("$var_name")
  fi
done

if [[ ${#MISSING_VARS[@]} -gt 0 ]]; then
  printf 'Missing required iOS environment variables: %s\n' "${MISSING_VARS[*]}" >&2
  exit "$EXIT_ENV_INVALID"
fi

exit 0
