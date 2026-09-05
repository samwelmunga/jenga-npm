#!/usr/bin/env bash
set -u

TARGET_NAME="${1:-}"
CONFIG_PATH="${2:-}"
EXIT_CONFIG_INVALID=4

fail() {
  printf 'target config check failed: %s\n' "$1" >&2
  exit "$EXIT_CONFIG_INVALID"
}

[[ -n "$TARGET_NAME" ]] || fail "missing target name argument"
[[ -n "$CONFIG_PATH" ]] || fail "missing publish.json path argument"
[[ -f "$CONFIG_PATH" ]] || fail "publish.json not found at '$CONFIG_PATH'"
command -v jq >/dev/null 2>&1 || fail "jq is required"
jq -e . "$CONFIG_PATH" >/dev/null 2>&1 || fail "publish.json is not valid JSON"

TARGET_JSON="$(jq -c --arg name "$TARGET_NAME" '.targets[]? | select(.name == $name)' "$CONFIG_PATH")"
[[ -n "$TARGET_JSON" ]] || fail "target '$TARGET_NAME' was not found in '$CONFIG_PATH'"

TARGET_TYPE="$(printf '%s\n' "$TARGET_JSON" | jq -r '.type // empty')"
[[ -n "$TARGET_TYPE" ]] || fail "target '$TARGET_NAME' is missing a type"

case "$TARGET_TYPE" in
  mobile-ios)
    MISSING="$(printf '%s\n' "$TARGET_JSON" | jq -r '
      def non_empty($value):
        ($value | type) == "string" and (($value | length) > 0);
      def env_ref($value):
        ($value | type) == "string" and ($value | test("^\\$\\{?[A-Z][A-Z0-9_]*\\}?$"));
      def missing_string($path; $value):
        if non_empty($value // "") then empty else $path end;
      def missing_env_ref($path; $value):
        if env_ref($value // "") then empty else $path end;
      [
        (if .platform == "ios-app-store" then empty else "platform" end),
        (if (.checks | type) == "object" then empty else "checks" end),
        (if (.checks.pre | type) == "array" then empty else "checks.pre" end),
        (if (.checks.post | type) == "array" then empty else "checks.post" end),
        (missing_env_ref("secrets.app_store_connect_api_key_id"; .secrets.app_store_connect_api_key_id)),
        (missing_env_ref("secrets.app_store_connect_issuer_id"; .secrets.app_store_connect_issuer_id)),
        (missing_env_ref("secrets.app_store_connect_private_key_path"; .secrets.app_store_connect_private_key_path)),
        (missing_env_ref("secrets.code_sign_identity"; .secrets.code_sign_identity)),
        (missing_env_ref("secrets.provisioning_profile_uuid"; .secrets.provisioning_profile_uuid)),
        (missing_string("ios.scheme"; .ios.scheme)),
        (missing_string("ios.configuration"; .ios.configuration)),
        (missing_string("ios.archive_path"; .ios.archive_path)),
        (missing_string("ios.export_path"; .ios.export_path)),
        (if (.ios.export_method == "ad-hoc" or .ios.export_method == "app-store") then empty else "ios.export_method" end),
        (missing_string("ios.bundle_id"; .ios.bundle_id)),
        (if ((.ios.team_id // "") | type) == "string" and ((.ios.team_id // "") | test("^[A-Z0-9]{6,}$")) then empty else "ios.team_id" end),
        (if ((.ios.app_store_app_id // "") | type) == "string" and ((.ios.app_store_app_id // "") | test("^[0-9]+$")) then empty else "ios.app_store_app_id" end),
        (if ((.ios.project_path // "") | length) > 0 or ((.ios.workspace_path // "") | length) > 0 then empty else "ios.project_path|ios.workspace_path" end)
      ]
      | map(select(. != null and . != ""))
      | .[]
    ' 2>/dev/null || true)"
    ;;
  npm-ci)
    MISSING="$(printf '%s\n' "$TARGET_JSON" | jq -r '
      def non_empty($value):
        ($value | type) == "string" and (($value | length) > 0);
      def missing_string($path; $value):
        if non_empty($value // "") then empty else $path end;
      [
        (missing_string("github_repo"; .github_repo)),
        (if (.npm | type) == "object" then empty else "npm" end),
        (missing_string("npm.package_name"; .npm.package_name)),
        (if ((.npm.access? // "") == "public" or (.npm.access? // "") == "restricted") then empty else "npm.access" end)
      ]
      | map(select(. != null and . != ""))
      | .[]
    ' 2>/dev/null || true)"
    ;;
  *)
    fail "unsupported target type '$TARGET_TYPE' for target '$TARGET_NAME'"
    ;;
esac

if [[ -n "$MISSING" ]]; then
  MESSAGE=""
  while IFS= read -r item; do
    [[ -n "$item" ]] || continue
    if [[ -z "$MESSAGE" ]]; then
      MESSAGE="$item"
    else
      MESSAGE="$MESSAGE, $item"
    fi
  done <<EOF_MISSING
$MISSING
EOF_MISSING
  fail "target '$TARGET_NAME' is incomplete. Missing or invalid: $MESSAGE"
fi

exit 0
