#!/usr/bin/env bash
set -euo pipefail

EXIT_DEPLOY_FAILURE=3
EXIT_VALIDATION_FAILURE=4

usage() {
  cat <<'USAGE'
Usage: ios_pipeline.sh <target> <publish_json_path> [--dry-run] [--non-interactive]
USAGE
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel 2>/dev/null)"; then
  :
else
  REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
fi
VALIDATE_CONFIG_SCRIPT="$SCRIPT_DIR/validate_config.sh"
VALIDATE_ENV_SCRIPT="$SCRIPT_DIR/validate_ios_env.sh"
EXPORT_TEMPLATE="$SCRIPT_DIR/../assets/ExportOptions.plist.template"
HISTORY_FILE=""
HISTORY_LOCK=""
RUN_ID=""
RUN_STARTED_AT=""
SCRATCH_DIR=""
EXPORT_OPTIONS_PATH=""
RUN_OUTPUT=""
RUN_STATUS=0
LAST_COMMAND=""
APP_DISPLAY_NAME=""
TARGET_JSON=""
EXPORT_METHOD=""
BUNDLE_ID=""
TEAM_ID=""
ARCHIVE_PATH=""
EXPORT_PATH=""
SCHEME=""
CONFIGURATION=""
PROJECT_PATH=""
WORKSPACE_PATH=""
DESTINATION=""
SDK=""
APP_STORE_APP_ID=""
PROVIDER_SHORT_NAME=""
API_KEY_ID=""
ISSUER_ID=""
PRIVATE_KEY_PATH=""
CODE_SIGN_IDENTITY_VALUE=""
PROVISIONING_PROFILE_UUID_VALUE=""
SELECTED_UPLOAD_TOOL=""
IPA_PATH=""

cleanup() {
  if [[ -n "${SCRATCH_DIR:-}" && -d "$SCRATCH_DIR" ]]; then
    rm -rf "$SCRATCH_DIR"
  fi
}
trap cleanup EXIT

if [[ $# -lt 2 || $# -gt 4 ]]; then
  usage >&2
  exit 1
fi

TARGET_NAME="$1"
PUBLISH_JSON="$2"
DRY_RUN=0
NON_INTERACTIVE=0
shift 2

for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=1 ;;
    --non-interactive) NON_INTERACTIVE=1 ;;
    *) usage >&2; exit 1 ;;
  esac
done

if [[ ! -t 0 ]]; then
  NON_INTERACTIVE=1
fi

fail_validation() {
  printf 'iOS pipeline validation failed: %s\n' "$1" >&2
  exit "$EXIT_VALIDATION_FAILURE"
}

fail_deploy() {
  printf '%s\n' "$1" >&2
  exit "$EXIT_DEPLOY_FAILURE"
}

log_info() {
  printf '→ %s\n' "$1"
}

log_warn() {
  printf '⚠ %s\n' "$1" >&2
}

print_manual_steps() {
  cat <<EOF2
✅ Upload complete. Next manual steps:
1. Go to App Store Connect → Apps → [$APP_DISPLAY_NAME] → TestFlight (or App Store)
2. Find the new build and submit for review / release
3. Set release notes if required
EOF2
}

stat_mtime() {
  if [[ -e "$1" ]]; then
    stat -f %m "$1" 2>/dev/null || echo 0
  else
    echo 0
  fi
}

acquire_lock() {
  local lock_path="$1"
  local now mtime
  now="$(date +%s)"

  if [[ -e "$lock_path" ]]; then
    mtime="$(stat_mtime "$lock_path")"
    if (( now - mtime < 60 )); then
      sleep 10
      now="$(date +%s)"
      mtime="$(stat_mtime "$lock_path")"
      if [[ -e "$lock_path" ]] && (( now - mtime < 60 )); then
        fail_deploy "Could not acquire lock for $lock_path"
      fi
    fi
    rm -f "$lock_path"
  fi

  if ! ( set -o noclobber; : > "$lock_path" ) 2>/dev/null; then
    fail_deploy "Could not create lock file $lock_path"
  fi
}

release_lock() {
  rm -f "$1"
}

extract_env_name() {
  local ref="$1"
  ref="${ref#\$\{}"
  ref="${ref#\$}"
  ref="${ref%\}}"
  printf '%s' "$ref"
}

resolve_env_value_from_ref() {
  local ref="$1"
  local var_name
  var_name="$(extract_env_name "$ref")"
  printenv "$var_name" 2>/dev/null || true
}

ensure_history_file() {
  mkdir -p "$(dirname "$HISTORY_FILE")"
  acquire_lock "$HISTORY_LOCK"
  if [[ ! -f "$HISTORY_FILE" ]]; then
    echo '[]' > "$HISTORY_FILE"
  fi
  release_lock "$HISTORY_LOCK"
}

write_history_jq() {
  local filter="$1"
  shift
  local tmp_file="$HISTORY_FILE.tmp.$$"
  acquire_lock "$HISTORY_LOCK"
  if jq "$@" "$filter" "$HISTORY_FILE" > "$tmp_file"; then
    mv "$tmp_file" "$HISTORY_FILE"
    release_lock "$HISTORY_LOCK"
    return 0
  fi
  rm -f "$tmp_file"
  release_lock "$HISTORY_LOCK"
  fail_deploy "Failed to update publish history at $HISTORY_FILE"
}

append_history_entry() {
  local entry
  entry="$(jq -cn \
    --arg id "$RUN_ID" \
    --arg target "$TARGET_NAME" \
    --arg started_at "$RUN_STARTED_AT" \
    --arg export_method "$EXPORT_METHOD" \
    '{id:$id,target:$target,adapter:"mobile-ios",state:"building",started_at:$started_at,completed_at:null,export_method:$export_method,steps:[]}')"
  write_history_jq '. += [$entry]' --argjson entry "$entry"
}

append_step() {
  local step_name="$1"
  local step_status="$2"
  local step_timestamp
  step_timestamp="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
  write_history_jq 'map(if .id == $id then .steps += [{step:$step,status:$status,timestamp:$timestamp}] else . end)' \
    --arg id "$RUN_ID" \
    --arg step "$step_name" \
    --arg status "$step_status" \
    --arg timestamp "$step_timestamp"
}

update_state() {
  local new_state="$1"
  write_history_jq 'map(if .id == $id then .state = $state else . end)' \
    --arg id "$RUN_ID" \
    --arg state "$new_state"
}

complete_history() {
  local final_state="$1"
  local completed_at
  completed_at="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
  write_history_jq 'map(if .id == $id then .state = $state | .completed_at = $completed_at else . end)' \
    --arg id "$RUN_ID" \
    --arg state "$final_state" \
    --arg completed_at "$completed_at"
}

print_command() {
  printf '[DRY RUN]'
  while (($#)); do
    printf ' %q' "$1"
    shift
  done
  printf '\n'
}

run_command() {
  LAST_COMMAND=""
  local cmd=("$@")
  local rendered=""
  local arg
  for arg in "${cmd[@]}"; do
    rendered+=" $(printf '%q' "$arg")"
  done
  LAST_COMMAND="${rendered# }"

  if (( DRY_RUN )); then
    print_command "${cmd[@]}"
    RUN_OUTPUT=""
    RUN_STATUS=0
    return 0
  fi

  if RUN_OUTPUT="$("${cmd[@]}" 2>&1)"; then
    RUN_STATUS=0
    return 0
  fi

  RUN_STATUS=$?
  return "$RUN_STATUS"
}

print_failure_block() {
  local phase_name="$1"
  echo "========== IOS PIPELINE FAILURE ==========" >&2
  echo "Phase: $phase_name" >&2
  echo "Target: $TARGET_NAME" >&2
  echo "Command: ${LAST_COMMAND:-n/a}" >&2
  echo "Exit code: $RUN_STATUS" >&2
  echo "----------- output -----------" >&2
  if [[ -n "$RUN_OUTPUT" ]]; then
    printf '%s\n' "$RUN_OUTPUT" >&2
  else
    echo "(no output captured)" >&2
  fi
  echo "=========================================" >&2
}

load_target_config() {
  TARGET_JSON="$(jq -c --arg target "$TARGET_NAME" '.targets[]? | select(.name == $target)' "$PUBLISH_JSON")"
  [[ -n "$TARGET_JSON" ]] || fail_validation "target '$TARGET_NAME' was not found in '$PUBLISH_JSON'"

  local target_type target_platform
  target_type="$(printf '%s' "$TARGET_JSON" | jq -r '.type // empty')"
  target_platform="$(printf '%s' "$TARGET_JSON" | jq -r '.platform // empty')"
  [[ "$target_type" == "mobile-ios" ]] || fail_validation "target '$TARGET_NAME' is not a mobile-ios target"
  [[ "$target_platform" == "ios-app-store" ]] || fail_validation "target '$TARGET_NAME' is not an ios-app-store target"

  SCHEME="$(printf '%s' "$TARGET_JSON" | jq -r '.ios.scheme // empty')"
  CONFIGURATION="$(printf '%s' "$TARGET_JSON" | jq -r '.ios.configuration // empty')"
  ARCHIVE_PATH="$(printf '%s' "$TARGET_JSON" | jq -r '.ios.archive_path // empty')"
  EXPORT_PATH="$(printf '%s' "$TARGET_JSON" | jq -r '.ios.export_path // empty')"
  EXPORT_METHOD="$(printf '%s' "$TARGET_JSON" | jq -r '.ios.export_method // empty')"
  BUNDLE_ID="$(printf '%s' "$TARGET_JSON" | jq -r '.ios.bundle_id // empty')"
  TEAM_ID="$(printf '%s' "$TARGET_JSON" | jq -r '.ios.team_id // empty')"
  APP_STORE_APP_ID="$(printf '%s' "$TARGET_JSON" | jq -r '.ios.app_store_app_id // empty')"
  PROVIDER_SHORT_NAME="$(printf '%s' "$TARGET_JSON" | jq -r '.ios.provider_short_name // empty')"
  PROJECT_PATH="$(printf '%s' "$TARGET_JSON" | jq -r '.ios.project_path // empty')"
  WORKSPACE_PATH="$(printf '%s' "$TARGET_JSON" | jq -r '.ios.workspace_path // empty')"
  DESTINATION="$(printf '%s' "$TARGET_JSON" | jq -r '.ios.destination // empty')"
  SDK="$(printf '%s' "$TARGET_JSON" | jq -r '.ios.sdk // empty')"

  API_KEY_ID="$(resolve_env_value_from_ref "$(printf '%s' "$TARGET_JSON" | jq -r '.secrets.app_store_connect_api_key_id // empty')")"
  ISSUER_ID="$(resolve_env_value_from_ref "$(printf '%s' "$TARGET_JSON" | jq -r '.secrets.app_store_connect_issuer_id // empty')")"
  PRIVATE_KEY_PATH="$(resolve_env_value_from_ref "$(printf '%s' "$TARGET_JSON" | jq -r '.secrets.app_store_connect_private_key_path // empty')")"
  CODE_SIGN_IDENTITY_VALUE="$(resolve_env_value_from_ref "$(printf '%s' "$TARGET_JSON" | jq -r '.secrets.code_sign_identity // empty')")"
  PROVISIONING_PROFILE_UUID_VALUE="$(resolve_env_value_from_ref "$(printf '%s' "$TARGET_JSON" | jq -r '.secrets.provisioning_profile_uuid // empty')")"

  [[ -n "$SCHEME" && -n "$CONFIGURATION" && -n "$ARCHIVE_PATH" && -n "$EXPORT_PATH" && -n "$EXPORT_METHOD" && -n "$BUNDLE_ID" && -n "$TEAM_ID" && -n "$APP_STORE_APP_ID" ]] || fail_validation "target '$TARGET_NAME' is missing required ios fields"
  [[ -n "$PROJECT_PATH" || -n "$WORKSPACE_PATH" ]] || fail_validation "target '$TARGET_NAME' must define project_path or workspace_path"
  APP_DISPLAY_NAME="$BUNDLE_ID"
}

build_export_options() {
  mkdir -p "$SCRATCH_DIR"
  [[ -f "$EXPORT_TEMPLATE" ]] || fail_deploy "ExportOptions template not found at $EXPORT_TEMPLATE"

  sed \
    -e "s|{{EXPORT_METHOD}}|$EXPORT_METHOD|g" \
    -e "s|{{TEAM_ID}}|$TEAM_ID|g" \
    -e "s|{{SIGNING_IDENTITY}}|$CODE_SIGN_IDENTITY_VALUE|g" \
    -e "s|{{BUNDLE_ID}}|$BUNDLE_ID|g" \
    -e "s|{{PROVISIONING_PROFILE_UUID}}|$PROVISIONING_PROFILE_UUID_VALUE|g" \
    "$EXPORT_TEMPLATE" > "$EXPORT_OPTIONS_PATH"
}

run_build() {
  local cmd=(xcodebuild archive)
  if [[ -n "$WORKSPACE_PATH" ]]; then
    cmd+=( -workspace "$WORKSPACE_PATH" )
  else
    cmd+=( -project "$PROJECT_PATH" )
  fi
  cmd+=( -scheme "$SCHEME" -configuration "$CONFIGURATION" -archivePath "$ARCHIVE_PATH" )
  if [[ -n "$DESTINATION" ]]; then
    cmd+=( -destination "$DESTINATION" )
  fi
  if [[ -n "$SDK" ]]; then
    cmd+=( -sdk "$SDK" )
  fi

  if run_command "${cmd[@]}"; then
    append_step build passed
    update_state signing
  else
    append_step build failed
    complete_history failed
    print_failure_block build
    exit "$EXIT_DEPLOY_FAILURE"
  fi
}

run_sign() {
  if build_export_options; then
    append_step sign passed
    update_state exporting
  else
    RUN_STATUS=1
    RUN_OUTPUT="Failed to generate ExportOptions.plist"
    LAST_COMMAND="generate ExportOptions.plist"
    append_step sign failed
    complete_history failed
    print_failure_block sign
    exit "$EXIT_DEPLOY_FAILURE"
  fi
}

run_export() {
  mkdir -p "$EXPORT_PATH"
  local cmd=(xcodebuild -exportArchive -archivePath "$ARCHIVE_PATH" -exportPath "$EXPORT_PATH" -exportOptionsPlist "$EXPORT_OPTIONS_PATH")
  if run_command "${cmd[@]}"; then
    append_step export passed
    update_state uploading
  else
    append_step export failed
    complete_history failed
    print_failure_block export
    exit "$EXIT_DEPLOY_FAILURE"
  fi
}

resolve_ipa_path() {
  if (( DRY_RUN )); then
    IPA_PATH="$EXPORT_PATH/$SCHEME.ipa"
    return 0
  fi

  IPA_PATH="$(find "$EXPORT_PATH" -type f -name '*.ipa' | head -n 1)"
  [[ -n "$IPA_PATH" ]] || fail_deploy "No IPA was found under $EXPORT_PATH after export"
}

choose_upload_tool() {
  if (( DRY_RUN )); then
    SELECTED_UPLOAD_TOOL="notarytool"
    return 0
  fi

  if xcrun notarytool --help >/dev/null 2>&1; then
    SELECTED_UPLOAD_TOOL="notarytool"
  else
    SELECTED_UPLOAD_TOOL="altool"
    log_warn "xcrun notarytool is unavailable; falling back to xcrun altool."
  fi
}

run_upload() {
  resolve_ipa_path
  choose_upload_tool

  local cmd=(xcrun)
  if [[ "$SELECTED_UPLOAD_TOOL" == "notarytool" ]]; then
    cmd+=( notarytool submit "$IPA_PATH" --key-id "$API_KEY_ID" --issuer "$ISSUER_ID" --key "$PRIVATE_KEY_PATH" --wait )
  else
    cmd+=( altool --upload-app --type ios --file "$IPA_PATH" --apiKey "$API_KEY_ID" --apiIssuer "$ISSUER_ID" )
    if [[ -n "$PROVIDER_SHORT_NAME" ]]; then
      cmd+=( --asc-provider "$PROVIDER_SHORT_NAME" )
    fi
  fi

  if run_command "${cmd[@]}"; then
    append_step upload passed
    complete_history uploaded
  else
    append_step upload failed
    complete_history failed
    print_failure_block upload
    exit "$EXIT_DEPLOY_FAILURE"
  fi
}

main() {
  [[ -f "$PUBLISH_JSON" ]] || fail_validation "publish config not found at '$PUBLISH_JSON'"
  [[ -f "$VALIDATE_CONFIG_SCRIPT" ]] || fail_validation "validate_config.sh not found"
  [[ -f "$VALIDATE_ENV_SCRIPT" ]] || fail_validation "validate_ios_env.sh not found"
  command -v jq >/dev/null 2>&1 || fail_validation "jq is required"

  bash "$VALIDATE_CONFIG_SCRIPT" "$PUBLISH_JSON"
  bash "$VALIDATE_ENV_SCRIPT" "$PUBLISH_JSON" "$TARGET_NAME"

  HISTORY_FILE="$REPO_ROOT/$(jq -r '.defaults.history_file // "project/logs/publish-history.json"' "$PUBLISH_JSON")"
  HISTORY_LOCK="${HISTORY_FILE}.lock"
  RUN_ID="$(uuidgen | tr '[:upper:]' '[:lower:]')"
  RUN_STARTED_AT="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
  SCRATCH_DIR="$REPO_ROOT/.claude/publish-tmp/$RUN_ID"
  EXPORT_OPTIONS_PATH="$SCRATCH_DIR/ExportOptions.plist"
  RUN_OUTPUT=""
  RUN_STATUS=0
  LAST_COMMAND=""
  APP_DISPLAY_NAME="$TARGET_NAME"
  TARGET_JSON=""
  EXPORT_METHOD=""
  BUNDLE_ID=""
  TEAM_ID=""
  ARCHIVE_PATH=""
  EXPORT_PATH=""
  SCHEME=""
  CONFIGURATION=""
  PROJECT_PATH=""
  WORKSPACE_PATH=""
  DESTINATION=""
  SDK=""
  APP_STORE_APP_ID=""
  PROVIDER_SHORT_NAME=""
  API_KEY_ID=""
  ISSUER_ID=""
  PRIVATE_KEY_PATH=""
  CODE_SIGN_IDENTITY_VALUE=""
  PROVISIONING_PROFILE_UUID_VALUE=""
  SELECTED_UPLOAD_TOOL=""
  IPA_PATH=""

  load_target_config

  if [[ ! -f "$PRIVATE_KEY_PATH" && $DRY_RUN -eq 0 ]]; then
    fail_validation "private key path '$PRIVATE_KEY_PATH' does not exist"
  fi

  ensure_history_file
  append_history_entry
  log_info "Starting iOS publish pipeline for '$TARGET_NAME'..."

  run_build
  run_sign
  run_export
  run_upload
  print_manual_steps
}

main "$@"
