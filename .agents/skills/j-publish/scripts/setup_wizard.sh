#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
REPO_ROOT="$(cd "${SKILL_DIR}/../.." && pwd)"
SECRETS_GUIDE_PATH="${SKILL_DIR}/assets/secrets-guide.md"
VALIDATE_SCRIPT="${SCRIPT_DIR}/validate_config.sh"
DEFAULT_CONFIG_PATH="${REPO_ROOT}/publish.json"
EXIT_ABORTED=1
EXIT_CONFIG_INVALID=4

TARGET_NAME=""
DEPLOY_TYPE=""
CONFIG_PATH="$DEFAULT_CONFIG_PATH"
PROMPT_RESULT=""

usage() {
  cat <<'EOF_USAGE'
Usage: setup_wizard.sh [<target_name>] [--type <deployment_type>] [--config <path>]
EOF_USAGE
}

fail() {
  printf 'setup wizard error: %s\n' "$1" >&2
  exit "$EXIT_CONFIG_INVALID"
}

prompt_line() {
  local prompt="$1"
  local value=""
  printf '%s' "$prompt"
  if ! IFS= read -r value; then
    printf '\nSetup cancelled before input was completed.\n' >&2
    exit "$EXIT_ABORTED"
  fi
  PROMPT_RESULT="$value"
}

prompt_required() {
  local prompt="$1"
  while :; do
    prompt_line "$prompt"
    if [[ -n "$PROMPT_RESULT" ]]; then
      return 0
    fi
    printf 'Value is required.\n' >&2
  done
}

prompt_target_name() {
  while :; do
    prompt_required "Target name: "
    if printf '%s' "$PROMPT_RESULT" | grep -Eq '^[a-z0-9][a-z0-9-]*$'; then
      TARGET_NAME="$PROMPT_RESULT"
      return 0
    fi
    printf 'Target name must be lowercase kebab-case.\n' >&2
  done
}

prompt_deploy_type() {
  printf 'Available deployment types:\n'
  printf '1. mobile-ios\n'
  printf '2. npm\n'
  printf '3. npm-ci\n'
  prompt_line 'Choose type [1]: '
  case "${PROMPT_RESULT:-1}" in
    1|mobile-ios|"") DEPLOY_TYPE="mobile-ios" ;;
    2|npm) DEPLOY_TYPE="npm" ;;
    3|npm-ci) DEPLOY_TYPE="npm-ci" ;;
    *) printf 'Unsupported type. Choose mobile-ios, npm, or npm-ci.\n' >&2; prompt_deploy_type ;;
  esac
}

question_section() {
  local field="$1"
  awk -v field="$field" '
    $0 == "## Question: " field {capture=1}
    capture {
      if ($0 ~ /^## Question: / && $0 != "## Question: " field) {
        exit
      }
      print
    }
  ' "$TEMPLATE_PATH"
}

validate_env_var_name() {
  printf '%s' "$1" | grep -Eq '^[A-Z][A-Z0-9_]*$'
}

warn_if_missing_env() {
  local var_name="$1"
  if [[ -z "${!var_name:-}" ]]; then
    printf "⚠️  Env var '%s' is not set. Set it before deploying.\n" "$var_name" >&2
  fi
}

capture_question_answer() {
  local field="$1"
  printf '\n%s\n' "$(question_section "$field")"
  while :; do
    case "$field" in
      configuration)
        prompt_line '> [Release] '
        PROMPT_RESULT="${PROMPT_RESULT:-Release}"
        ;;
      provider_short_name)
        prompt_line '> '
        return 0
        ;;
      *)
        prompt_required '> '
        ;;
    esac

    case "$field" in
      export_method)
        if [[ "$PROMPT_RESULT" == "ad-hoc" || "$PROMPT_RESULT" == "app-store" ]]; then
          return 0
        fi
        printf 'Enter ad-hoc or app-store.\n' >&2
        ;;
      team_id)
        if printf '%s' "$PROMPT_RESULT" | grep -Eq '^[A-Z0-9]{6,}$'; then
          return 0
        fi
        printf 'Enter a valid Apple team identifier such as ABCDE12345.\n' >&2
        ;;
      app_store_app_id)
        if printf '%s' "$PROMPT_RESULT" | grep -Eq '^[0-9]+$'; then
          return 0
        fi
        printf 'Enter a numeric App Store app identifier.\n' >&2
        ;;
      project_or_workspace_path)
        if printf '%s' "$PROMPT_RESULT" | grep -Eq '\.(xcodeproj|xcworkspace)$'; then
          return 0
        fi
        printf 'Enter a path ending in .xcodeproj or .xcworkspace.\n' >&2
        ;;
      api_key_id_env_var|issuer_id_env_var|private_key_path_env_var|code_sign_identity_env_var|provisioning_profile_uuid_env_var)
        if validate_env_var_name "$PROMPT_RESULT"; then
          warn_if_missing_env "$PROMPT_RESULT"
          return 0
        fi
        printf 'Enter an uppercase environment-variable name.\n' >&2
        ;;
      *)
        return 0
        ;;
    esac
  done
}

build_target_json() {
  local project_path=""
  local workspace_path=""
  if [[ "$PROJECT_OR_WORKSPACE_PATH" == *.xcworkspace ]]; then
    workspace_path="$PROJECT_OR_WORKSPACE_PATH"
  else
    project_path="$PROJECT_OR_WORKSPACE_PATH"
  fi

  jq -n \
    --arg name "$TARGET_NAME" \
    --arg type "$DEPLOY_TYPE" \
    --arg project_path "$project_path" \
    --arg workspace_path "$workspace_path" \
    --arg scheme "$SCHEME" \
    --arg configuration "$CONFIGURATION" \
    --arg archive_path "$ARCHIVE_PATH" \
    --arg export_path "$EXPORT_PATH" \
    --arg export_method "$EXPORT_METHOD" \
    --arg bundle_id "$BUNDLE_ID" \
    --arg team_id "$TEAM_ID" \
    --arg app_store_app_id "$APP_STORE_APP_ID" \
    --arg provider_short_name "$PROVIDER_SHORT_NAME" \
    --arg api_key_id_ref "\$$API_KEY_ID_ENV_VAR" \
    --arg issuer_id_ref "\$$ISSUER_ID_ENV_VAR" \
    --arg private_key_ref "\$$PRIVATE_KEY_PATH_ENV_VAR" \
    --arg code_sign_identity_ref "\$$CODE_SIGN_IDENTITY_ENV_VAR" \
    --arg provisioning_profile_ref "\$$PROVISIONING_PROFILE_UUID_ENV_VAR" \
    '{
      name: $name,
      type: $type,
      platform: "ios-app-store",
      checks: {
        pre: [],
        post: []
      },
      secrets: {
        app_store_connect_api_key_id: $api_key_id_ref,
        app_store_connect_issuer_id: $issuer_id_ref,
        app_store_connect_private_key_path: $private_key_ref,
        code_sign_identity: $code_sign_identity_ref,
        provisioning_profile_uuid: $provisioning_profile_ref
      },
      ios: {
        scheme: $scheme,
        configuration: $configuration,
        archive_path: $archive_path,
        export_path: $export_path,
        export_method: $export_method,
        bundle_id: $bundle_id,
        team_id: $team_id,
        app_store_app_id: $app_store_app_id
      }
    }
    | if $project_path != "" then .ios.project_path = $project_path else . end
    | if $workspace_path != "" then .ios.workspace_path = $workspace_path else . end
    | if $provider_short_name != "" then .ios.provider_short_name = $provider_short_name else . end'
}

save_config() {
  local target_json="$1"
  local backup_path="${CONFIG_PATH}.setup-wizard.bak"
  local merged_json=""
  local defaults_json='{"history_file":"project/logs/publish-history.json","mandatory_checks":["build","test"],"optional_checks":["lint","type-check","custom-script","smoke-test","ping"]}'

  mkdir -p "$(dirname "$CONFIG_PATH")"

  if [[ -f "$CONFIG_PATH" ]]; then
    jq -e . "$CONFIG_PATH" >/dev/null 2>&1 || fail "existing publish.json is not valid JSON"
    cp "$CONFIG_PATH" "$backup_path"
    merged_json="$(jq \
      --argjson new_target "$target_json" \
      --argjson defaults "$defaults_json" '
      .version = (.version // 1)
      | .defaults = (.defaults // $defaults)
      | .targets = (
          (.targets // [])
          | if any(.name == $new_target.name) then
              map(if .name == $new_target.name then $new_target else . end)
            else
              . + [$new_target]
            end
        )
    ' "$CONFIG_PATH")" || {
      rm -f "$backup_path"
      fail "could not merge target into existing publish.json"
    }
  else
    merged_json="$(jq -n \
      --argjson new_target "$target_json" \
      --argjson defaults "$defaults_json" \
      '{version: 1, defaults: $defaults, targets: [$new_target]}')" || fail "could not create publish.json payload"
  fi

  printf '%s\n' "$merged_json" > "$CONFIG_PATH"

  if ! bash "$VALIDATE_SCRIPT" "$CONFIG_PATH"; then
    printf 'publish.json failed validation after save. Rolling back.\n' >&2
    if [[ -f "$backup_path" ]]; then
      mv "$backup_path" "$CONFIG_PATH"
    else
      rm -f "$CONFIG_PATH"
    fi
    exit "$EXIT_CONFIG_INVALID"
  fi

  rm -f "$backup_path"
  printf 'Saved config to %s\n' "$CONFIG_PATH"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --type)
      [[ $# -ge 2 ]] || { usage >&2; exit "$EXIT_CONFIG_INVALID"; }
      DEPLOY_TYPE="$2"
      shift 2
      ;;
    --config)
      [[ $# -ge 2 ]] || { usage >&2; exit "$EXIT_CONFIG_INVALID"; }
      CONFIG_PATH="$2"
      shift 2
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    --*)
      usage >&2
      exit "$EXIT_CONFIG_INVALID"
      ;;
    *)
      if [[ -z "$TARGET_NAME" ]]; then
        TARGET_NAME="$1"
      else
        usage >&2
        exit "$EXIT_CONFIG_INVALID"
      fi
      shift
      ;;
  esac
done

[[ -f "$SECRETS_GUIDE_PATH" ]] || fail "secrets guide not found at '$SECRETS_GUIDE_PATH'"
[[ -f "$VALIDATE_SCRIPT" ]] || fail "validate_config.sh not found at '$VALIDATE_SCRIPT'"

if [[ "$CONFIG_PATH" != /* ]]; then
  CONFIG_PATH="$REPO_ROOT/${CONFIG_PATH#./}"
fi

if [[ -z "$TARGET_NAME" ]]; then
  prompt_target_name
elif ! printf '%s' "$TARGET_NAME" | grep -Eq '^[a-z0-9][a-z0-9-]*$'; then
  fail "target name must be lowercase kebab-case"
fi

if [[ -z "$DEPLOY_TYPE" ]]; then
  prompt_deploy_type
elif [[ "$DEPLOY_TYPE" != "mobile-ios" && "$DEPLOY_TYPE" != "npm" && "$DEPLOY_TYPE" != "npm-ci" ]]; then
  fail "unsupported deployment type '$DEPLOY_TYPE'"
fi

TEMPLATE_PATH="${SKILL_DIR}/wizards/${DEPLOY_TYPE}.md"
[[ -f "$TEMPLATE_PATH" ]] || fail "wizard template not found at '$TEMPLATE_PATH'"

printf '📦 /publish setup — %s (%s)\n' "$TARGET_NAME" "$DEPLOY_TYPE"
printf 'Secrets guide: %s\n\n' "$SECRETS_GUIDE_PATH"
awk '
  /^## Never do this/ {capture=1; print; next}
  capture && /^## / {exit}
  capture {print}
' "$SECRETS_GUIDE_PATH"
printf '\nUsing wizard template: %s\n' "$TEMPLATE_PATH"

# The npm and npm-ci wizards (wizards/npm.md, wizards/npm-ci.md) are
# agent-driven templates: they specify question prompts, post-collection
# actions, and JSON assembly rules that the /publish skill agent executes
# directly. Unlike the iOS wizard, their questions do not map onto a
# shell-side JSON build loop. Hand off by printing the resolved template
# path and exiting; the caller reads the template and drives the flow.
if [[ "$DEPLOY_TYPE" == "npm" ]]; then
  printf '\nnpm setup: follow the prompts in %s to collect answers,\n' "$TEMPLATE_PATH"
  printf 'then perform the "Post-collection actions" section (write target block\n'
  printf 'to publish.json and generate the NPM_TOKEN instructions file).\n'
  exit 0
fi

if [[ "$DEPLOY_TYPE" == "npm-ci" ]]; then
  printf '\nnpm-ci setup: follow the prompts in %s to collect answers,\n' "$TEMPLATE_PATH"
  printf 'then perform the "Post-collection actions" section (write target block\n'
  printf 'to publish.json). No NPM_TOKEN is required — publishing uses OIDC.\n'
  exit 0
fi

QUESTION_FIELDS="$(awk '/^## Question: /{sub(/^## Question: /, ""); print}' "$TEMPLATE_PATH")"
[[ -n "$QUESTION_FIELDS" ]] || fail "no questions found in template"

OLD_IFS="$IFS"
IFS='
'
set -f
for field in $QUESTION_FIELDS; do
  capture_question_answer "$field"
  case "$field" in
    bundle_id) BUNDLE_ID="$PROMPT_RESULT" ;;
    team_id) TEAM_ID="$PROMPT_RESULT" ;;
    scheme) SCHEME="$PROMPT_RESULT" ;;
    configuration) CONFIGURATION="$PROMPT_RESULT" ;;
    archive_path) ARCHIVE_PATH="$PROMPT_RESULT" ;;
    export_path) EXPORT_PATH="$PROMPT_RESULT" ;;
    export_method) EXPORT_METHOD="$PROMPT_RESULT" ;;
    app_store_app_id) APP_STORE_APP_ID="$PROMPT_RESULT" ;;
    project_or_workspace_path) PROJECT_OR_WORKSPACE_PATH="$PROMPT_RESULT" ;;
    provider_short_name) PROVIDER_SHORT_NAME="$PROMPT_RESULT" ;;
    api_key_id_env_var) API_KEY_ID_ENV_VAR="$PROMPT_RESULT" ;;
    issuer_id_env_var) ISSUER_ID_ENV_VAR="$PROMPT_RESULT" ;;
    private_key_path_env_var) PRIVATE_KEY_PATH_ENV_VAR="$PROMPT_RESULT" ;;
    code_sign_identity_env_var) CODE_SIGN_IDENTITY_ENV_VAR="$PROMPT_RESULT" ;;
    provisioning_profile_uuid_env_var) PROVISIONING_PROFILE_UUID_ENV_VAR="$PROMPT_RESULT" ;;
    *) fail "unsupported question field '$field'" ;;
  esac
done
set +f
IFS="$OLD_IFS"

TARGET_JSON="$(build_target_json)" || fail "could not assemble target config"

printf '\nConfig preview:\n'
printf '%s\n' "$TARGET_JSON" | jq .
prompt_line 'Save this config to publish.json? [y/N] '
case "${PROMPT_RESULT:-N}" in
  y|Y|yes|YES)
    save_config "$TARGET_JSON"
    ;;
  *)
    printf 'Config not saved. Re-run /publish setup any time.\n'
    exit "$EXIT_ABORTED"
    ;;
esac
