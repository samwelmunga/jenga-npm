#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/publish_common.sh"

VALIDATE_CONFIG_SCRIPT="$SCRIPT_DIR/validate_config.sh"
CHECK_TARGET_CONFIG_SCRIPT="$SCRIPT_DIR/check_target_config.sh"
SETUP_WIZARD_SCRIPT="$SCRIPT_DIR/setup_wizard.sh"
VALIDATE_IOS_ENV_SCRIPT="$SCRIPT_DIR/validate_ios_env.sh"
VALIDATE_NPM_ENV_SCRIPT="$SCRIPT_DIR/validate_npm_env.sh"
VALIDATE_DROPLET_ENV_SCRIPT="$SCRIPT_DIR/validate_droplet_env.sh"
VALIDATE_NPM_CI_ENV_SCRIPT="$SCRIPT_DIR/validate_npm_ci_env.sh"
DROPLET_PIPELINE_SCRIPT="$SCRIPT_DIR/droplet_pipeline.sh"
NPM_CI_PIPELINE_SCRIPT="$SCRIPT_DIR/npm_ci_pipeline.sh"
RUN_GATES_SCRIPT="$SCRIPT_DIR/run_gates.sh"
GENERATE_RELEASE_NOTES_SCRIPT="$SCRIPT_DIR/generate_release_notes.sh"
SUGGEST_SEMVER_SCRIPT="$SCRIPT_DIR/suggest_semver_bump.sh"
WRITE_LEDGER_ENTRY_SCRIPT="$SCRIPT_DIR/write_ledger_entry.sh"
IOS_PIPELINE_SCRIPT="$SCRIPT_DIR/ios_pipeline.sh"
NPM_PIPELINE_SCRIPT="$SCRIPT_DIR/npm_pipeline.sh"

EXIT_ABORTED=1
EXIT_GATE_FAILURE=2
EXIT_ADAPTER_FAILURE=3
EXIT_CONFIG_INVALID=4

TARGET_NAME=""
CONFIG_PATH=""
AUTO_YES=0
DRY_RUN=0
BUMP_OVERRIDE=""
RELEASE_NOTES_PATH=""
PROMPT_INPUT_FD=0
NON_INTERACTIVE=0
TARGET_TYPE=""
HISTORY_FILE=""
LAST_TAG=""
SELECTED_VERSION=""

usage() {
  cat <<'USAGE'
Usage: publish_deploy.sh [--target <name>] [--config <path>] [--yes] [--dry-run]
                         [--minor | --major] [--release-notes <path>]
USAGE
}

log_info() {
  printf '→ %s\n' "$1"
}

log_warn() {
  printf '⚠ %s\n' "$1" >&2
}

fail_with() {
  local exit_code="$1"
  shift
  printf '%s\n' "$*" >&2
  exit "$exit_code"
}

open_prompt_fd() {
  if [[ -t 0 ]]; then
    if exec 3</dev/tty 2>/dev/null; then
      PROMPT_INPUT_FD=3
      NON_INTERACTIVE=0
      return 0
    fi
  fi
  NON_INTERACTIVE=1
}

prompt_line() {
  local prompt="$1"
  local response=""
  printf '%s' "$prompt" >&2
  if ! IFS= read -r -u "$PROMPT_INPUT_FD" response; then
    printf '\n' >&2
    exit "$EXIT_ABORTED"
  fi
  printf '%s\n' "$response"
}

confirm_or_abort() {
  local prompt="$1"
  local response
  response="$(prompt_line "$prompt")"
  case "${response:-Y}" in
    y|Y|yes|YES)
      return 0
      ;;
    *)
      exit "$EXIT_ABORTED"
      ;;
  esac
}

resolve_default_config_path() {
  if [[ -n "$CONFIG_PATH" ]]; then
    publish_normalize_path "$CONFIG_PATH"
    return 0
  fi

  if [[ -f "$PUBLISH_REPO_ROOT/publish.json" ]]; then
    printf '%s\n' "$PUBLISH_REPO_ROOT/publish.json"
    return 0
  fi

  if [[ -f "$PUBLISH_REPO_ROOT/project/configs/publish.json" ]]; then
    printf '%s\n' "$PUBLISH_REPO_ROOT/project/configs/publish.json"
    return 0
  fi

  printf '%s\n' "$PUBLISH_REPO_ROOT/publish.json"
}

validate_config_file() {
  [[ -f "$CONFIG_PATH" ]] || fail_with "$EXIT_CONFIG_INVALID" "publish.json not found at '$CONFIG_PATH'."
  command -v jq >/dev/null 2>&1 || fail_with "$EXIT_CONFIG_INVALID" "jq is required."
  jq -e . "$CONFIG_PATH" >/dev/null 2>&1 || fail_with "$EXIT_CONFIG_INVALID" "publish.json is not valid JSON."
}

select_target_from_config() {
  local targets=()
  while IFS= read -r target; do
    [[ -n "$target" ]] && targets+=("$target")
  done < <(jq -r '.targets[]?.name // empty' "$CONFIG_PATH")
  [[ ${#targets[@]} -gt 0 ]] || fail_with "$EXIT_CONFIG_INVALID" "No targets were found in '$CONFIG_PATH'."

  echo "Available publish targets:" >&2
  local index=1
  local target
  for target in "${targets[@]}"; do
    printf '  %s. %s\n' "$index" "$target" >&2
    index=$((index + 1))
  done

  while true; do
    local selection
    selection="$(prompt_line "Select target [1-${#targets[@]}]: ")"
    [[ "$selection" =~ ^[0-9]+$ ]] || {
      echo "Enter a target number." >&2
      continue
    }
    if (( selection < 1 || selection > ${#targets[@]} )); then
      echo "Selection out of range." >&2
      continue
    fi
    TARGET_NAME="${targets[$((selection - 1))]}"
    return 0
  done
}

resolve_target_type() {
  TARGET_TYPE="$(jq -r --arg target "$TARGET_NAME" '.targets[]? | select(.name == $target) | .type // empty' "$CONFIG_PATH" | head -n 1)"
  [[ -n "$TARGET_TYPE" ]] || TARGET_TYPE="mobile-ios"
}

ensure_target_selected() {
  if [[ -n "$TARGET_NAME" ]]; then
    return 0
  fi

  if (( AUTO_YES || NON_INTERACTIVE )); then
    fail_with "$EXIT_CONFIG_INVALID" "Non-interactive deploy requires --target <name>."
  fi

  select_target_from_config
}

run_target_completeness_check() {
  local wizard_ran=0
  while true; do
    if bash "$CHECK_TARGET_CONFIG_SCRIPT" "$TARGET_NAME" "$CONFIG_PATH"; then
      return 0
    fi

    if (( AUTO_YES || NON_INTERACTIVE )); then
      exit "$EXIT_CONFIG_INVALID"
    fi

    if (( wizard_ran )); then
      exit "$EXIT_CONFIG_INVALID"
    fi

    resolve_target_type
    printf "⚠️  Target '%s' has missing or incomplete config. Running setup wizard...\n" "$TARGET_NAME" >&2
    local status=0
    if bash "$SETUP_WIZARD_SCRIPT" "$TARGET_NAME" --type "$TARGET_TYPE" --config "$CONFIG_PATH"; then
      :
    else
      status=$?
      exit "$status"
    fi
    wizard_ran=1
    validate_config_file
  done
}

validate_target_env() {
  case "$TARGET_TYPE" in
    mobile-ios)
      if ! bash "$VALIDATE_IOS_ENV_SCRIPT" "$CONFIG_PATH" "$TARGET_NAME"; then
        exit "$EXIT_CONFIG_INVALID"
      fi
      ;;
    npm)
      if ! bash "$VALIDATE_NPM_ENV_SCRIPT" "$CONFIG_PATH" "$TARGET_NAME"; then
        exit "$EXIT_CONFIG_INVALID"
      fi
      ;;
    npm-ci)
      if ! bash "$VALIDATE_NPM_CI_ENV_SCRIPT" "$CONFIG_PATH" "$TARGET_NAME"; then
        exit "$EXIT_CONFIG_INVALID"
      fi
      ;;
    droplet)
      if ! bash "$VALIDATE_DROPLET_ENV_SCRIPT" "$CONFIG_PATH" "$TARGET_NAME"; then
        exit "$EXIT_CONFIG_INVALID"
      fi
      ;;
    *)
      fail_with "$EXIT_CONFIG_INVALID" "Unsupported target type '$TARGET_TYPE'."
      ;;
  esac
}

resolve_last_tag() {
  LAST_TAG="$(publish_resolve_last_publish_tag "$HISTORY_FILE" HEAD 2>/dev/null || true)"
}

print_board_summary() {
  local stories_dir="$PUBLISH_REPO_ROOT/project/board/stories"
  local tasks_dir="$PUBLISH_REPO_ROOT/project/board/tasks"
  [[ -d "$stories_dir" || -d "$tasks_dir" ]] || return 0

  local cutoff_date=""
  if [[ -n "$LAST_TAG" ]]; then
    cutoff_date="$(git log -1 --format=%cI "$LAST_TAG" 2>/dev/null | cut -dT -f1)"
  fi

  local collected=""
  local file status completed_date item_id item_title label

  for label in story task; do
    local dir
    if [[ "$label" == "story" ]]; then
      dir="$stories_dir"
    else
      dir="$tasks_dir"
    fi

    [[ -d "$dir" ]] || continue
    while IFS= read -r -d '' file; do
      case "$file" in
        *_INSTRUCTIONS.md) continue ;;
      esac
      status="$(awk '/^status: /{sub(/^status: /, ""); print; exit}' "$file" 2>/dev/null || true)"
      case "$status" in
        "Passed"|"Passed with remarks") ;;
        *) continue ;;
      esac
      completed_date="$(awk '/^date_completed: /{sub(/^date_completed: /, ""); print; exit}' "$file" 2>/dev/null || true)"
      [[ -n "$completed_date" ]] || continue
      if [[ -n "$cutoff_date" && "$completed_date" < "$cutoff_date" ]]; then
        continue
      fi
      item_id="$(awk '/^id: /{sub(/^id: /, ""); print; exit}' "$file" 2>/dev/null || true)"
      item_title="$(awk '/^title: /{sub(/^title: /, ""); print; exit}' "$file" 2>/dev/null || true)"
      [[ -n "$item_id" ]] || continue
      if [[ "$label" == "story" ]]; then
        collected+="- [Story] $item_id — ${item_title:-$item_id} (${completed_date})"$'\n'
      else
        collected+="- [Task] $item_id — ${item_title:-$item_id} (${completed_date})"$'\n'
      fi
    done < <(find "$dir" -maxdepth 1 -type f -name '*.md' -print0 2>/dev/null)
  done

  [[ -n "$collected" ]] || return 0
  printf '\nBoard summary since last publish:\n%s\n' "$collected"
}

generate_release_notes() {
  if [[ -n "$RELEASE_NOTES_PATH" ]]; then
    if [[ "$RELEASE_NOTES_PATH" != /* ]]; then
      RELEASE_NOTES_PATH="$PUBLISH_REPO_ROOT/${RELEASE_NOTES_PATH#./}"
    fi
    [[ -f "$RELEASE_NOTES_PATH" ]] || fail_with "$EXIT_CONFIG_INVALID" "Release-notes file not found at '$RELEASE_NOTES_PATH'."
    return 0
  fi

  RELEASE_NOTES_PATH="$(publish_temp_release_notes_path)"
  local cmd=(bash "$GENERATE_RELEASE_NOTES_SCRIPT" --target "$TARGET_NAME" --output "$RELEASE_NOTES_PATH")
  if [[ -n "$LAST_TAG" ]]; then
    cmd+=(--from-tag "$LAST_TAG")
  fi
  cmd+=("$CONFIG_PATH")
  if ! "${cmd[@]}"; then
    fail_with "$EXIT_ADAPTER_FAILURE" "Failed to generate release notes."
  fi
}

review_release_notes() {
  (( AUTO_YES )) && return 0

  if [[ -n "${EDITOR:-}" ]]; then
    "${EDITOR}" "$RELEASE_NOTES_PATH"
  elif command -v less >/dev/null 2>&1; then
    less "$RELEASE_NOTES_PATH"
  else
    cat "$RELEASE_NOTES_PATH"
  fi

  confirm_or_abort "Use these release notes? [Y/n]: "
}

resolve_selected_version() {
  local current_version suggested_version
  current_version="$(publish_latest_ledger_version "$HISTORY_FILE" 2>/dev/null || true)"
  [[ -n "$current_version" ]] || current_version='v0.0.0'
  current_version="$(publish_normalize_version "$current_version")" || current_version='v0.0.0'

  suggested_version="$(bash "$SUGGEST_SEMVER_SCRIPT" --yes "$CONFIG_PATH" | tail -n 1 | tr -d '\r')"
  suggested_version="$(publish_normalize_version "$suggested_version")" || fail_with "$EXIT_ADAPTER_FAILURE" "Unable to determine a suggested version."

  case "$BUMP_OVERRIDE" in
    major|minor)
      SELECTED_VERSION="$(publish_bump_version "$current_version" "$BUMP_OVERRIDE")"
      ;;
    *)
      if (( AUTO_YES )); then
        SELECTED_VERSION="$(publish_bump_version "$current_version" patch)"
      else
        SELECTED_VERSION="$suggested_version"
      fi
      ;;
  esac

  if (( AUTO_YES )); then
    return 0
  fi

  printf 'Suggested version: %s\n' "$suggested_version"
  if [[ -n "$BUMP_OVERRIDE" ]]; then
    printf 'Using %s override: %s\n' "$BUMP_OVERRIDE" "$SELECTED_VERSION"
  fi
  confirm_or_abort "Use version $SELECTED_VERSION? [Y/n]: "
}

confirm_final_deploy() {
  (( AUTO_YES )) && return 0
  local response
  response="$(prompt_line "Deploy ${SELECTED_VERSION} to ${TARGET_NAME}? [y/N] ")"
  case "${response:-N}" in
    y|Y|yes|YES)
      return 0
      ;;
    *)
      exit "$EXIT_ABORTED"
      ;;
  esac
}

run_pre_gates() {
  local cmd=(bash "$RUN_GATES_SCRIPT" pre "$TARGET_NAME" "$CONFIG_PATH")
  (( AUTO_YES )) && cmd+=(--non-interactive)
  if ! "${cmd[@]}"; then
    exit "$EXIT_GATE_FAILURE"
  fi
}

run_adapter_pipeline() {
  local cmd
  case "$TARGET_TYPE" in
    mobile-ios)
      cmd=(bash "$IOS_PIPELINE_SCRIPT" "$TARGET_NAME" "$CONFIG_PATH")
      ;;
    npm)
      cmd=(bash "$NPM_PIPELINE_SCRIPT" "$TARGET_NAME" "$CONFIG_PATH")
      ;;
    npm-ci)
      cmd=(bash "$NPM_CI_PIPELINE_SCRIPT" --target "$TARGET_NAME" --config "$CONFIG_PATH")
      ;;
    droplet)
      cmd=(bash "$DROPLET_PIPELINE_SCRIPT" --target "$TARGET_NAME" --config "$CONFIG_PATH")
      ;;
    *)
      fail_with "$EXIT_CONFIG_INVALID" "Unsupported target type '$TARGET_TYPE'."
      ;;
  esac

  (( DRY_RUN )) && cmd+=(--dry-run)
  (( AUTO_YES )) && cmd+=(--non-interactive)

  local status=0
  if "${cmd[@]}"; then
    return 0
  else
    status=$?
  fi
  if [[ $status -eq $EXIT_CONFIG_INVALID ]]; then
    exit "$EXIT_CONFIG_INVALID"
  fi
  exit "$EXIT_ADAPTER_FAILURE"
}

run_post_gates() {
  local cmd=(bash "$RUN_GATES_SCRIPT" post "$TARGET_NAME" "$CONFIG_PATH")
  (( AUTO_YES )) && cmd+=(--non-interactive)

  local status=0
  if "${cmd[@]}"; then
    return 0
  else
    status=$?
  fi
  if [[ $status -eq $EXIT_GATE_FAILURE ]]; then
    log_warn "Post-deploy gates failed. The deploy will be recorded as partial."
  else
    log_warn "Post-deploy gate runner exited with status $status. The deploy will be recorded as partial."
  fi
  return 1
}

write_ledger_entry() {
  local platform_state="$1"
  local cmd=(bash "$WRITE_LEDGER_ENTRY_SCRIPT" "$TARGET_NAME" "$TARGET_TYPE" "$platform_state" "$RELEASE_NOTES_PATH" --version "$SELECTED_VERSION" --config "$CONFIG_PATH")
  (( AUTO_YES )) && cmd+=(--yes)
  (( DRY_RUN )) && cmd+=(--dry-run)
  "${cmd[@]}"
}

print_manual_steps() {
  local adapter_doc
  case "$TARGET_TYPE" in
    droplet)
      adapter_doc="$PUBLISH_REPO_ROOT/skills/publish/adapters/droplet.md"
      ;;
    *)
      adapter_doc="$PUBLISH_REPO_ROOT/skills/publish/adapters/mobile-ios.md"
      ;;
  esac
  [[ -f "$adapter_doc" ]] || return 0
  local manual_steps
  manual_steps="$(awk '
    /^## Post-deploy manual steps$/ {capture=1; next}
    capture && /^## / {exit}
    capture {print}
  ' "$adapter_doc")"
  [[ -n "$manual_steps" ]] || return 0
  printf '\n%s\n' "$manual_steps"
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --target)
        [[ $# -ge 2 ]] || { usage >&2; exit 1; }
        TARGET_NAME="$2"
        shift 2
        ;;
      --config)
        [[ $# -ge 2 ]] || { usage >&2; exit 1; }
        CONFIG_PATH="$2"
        shift 2
        ;;
      --yes)
        AUTO_YES=1
        shift
        ;;
      --dry-run)
        DRY_RUN=1
        shift
        ;;
      --minor)
        [[ -z "$BUMP_OVERRIDE" ]] || { usage >&2; exit 1; }
        BUMP_OVERRIDE="minor"
        shift
        ;;
      --major)
        [[ -z "$BUMP_OVERRIDE" ]] || { usage >&2; exit 1; }
        BUMP_OVERRIDE="major"
        shift
        ;;
      --release-notes)
        [[ $# -ge 2 ]] || { usage >&2; exit 1; }
        RELEASE_NOTES_PATH="$2"
        shift 2
        ;;
      --help|-h)
        usage
        exit 0
        ;;
      *)
        usage >&2
        exit 1
        ;;
    esac
  done
}

main() {
  parse_args "$@"
  open_prompt_fd

  CONFIG_PATH="$(resolve_default_config_path)"
  HISTORY_FILE="$(publish_resolve_history_file "$CONFIG_PATH")"

  (( DRY_RUN )) && printf '🔍 DRY RUN — no real deployment will occur\n'

  validate_config_file
  ensure_target_selected
  run_target_completeness_check
  resolve_target_type
  validate_target_env
  resolve_last_tag
  print_board_summary
  run_pre_gates
  generate_release_notes
  review_release_notes
  resolve_selected_version
  confirm_final_deploy
  run_adapter_pipeline

  local platform_state="uploaded"
  if ! run_post_gates; then
    platform_state="partial"
  fi
  if (( DRY_RUN )); then
    platform_state="dry-run"
  fi

  write_ledger_entry "$platform_state"
  print_manual_steps
}

main "$@"
