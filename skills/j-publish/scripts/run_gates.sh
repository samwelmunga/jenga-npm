#!/usr/bin/env bash
set -euo pipefail

# /publish quality gate runner
#
# Invocation:
#   run_gates.sh <phase> <target> <publish_json_path> [--non-interactive] [--ci]
#
# Arguments:
#   <phase>              pre | post
#   <target>             target name from publish.json
#   <publish_json_path>  path to publish.json
#   --non-interactive    disable prompts; any gate failure aborts immediately. Says nothing about audit consent
#   --ci                 the caller is a committed CI workflow: the standing consent for the dependency audit
#
# Exit codes:
#   0  all required gates passed (or were intentionally skipped with warnings)
#   2  one or more gates failed
#
# Built-in "audit" gate (pre phase, epic E85): npm and npm-ci targets run scripts/audit-deps.sh against
# $REPO_ROOT (the directory holding the package.json that npm_pipeline.sh publishes) after the mandatory
# gates. It passes --ci only when CI consent is present and never --approved. CI consent is exactly one of:
# this script's own --ci argument, CI=true in the environment, or GITHUB_ACTIONS=true in the environment.
# --non-interactive (which publish_deploy.sh also sends for a human's `deploy --yes`) and a missing tty are
# NOT consent, so under audit mode ask a --yes run reports "audit:skipped (no consent)". Outcomes: exit 0 passed (an
# "unavailable" result under offline_behavior warn is a pass with a visible warning); exit 1 (findings at or
# above the threshold) fails the gate, or, interactively, asks "proceed anyway / stop"; exit 2 or 3 fails;
# exit 4 (no consent: audit mode ask or off) is reported as skipped, never as passed or failed. Every result
# that carries JSON is handed to scripts/audit-record.sh. Other target types report
# "audit:skipped (not an npm target)".

usage() {
  cat <<'USAGE'
Usage: run_gates.sh <phase> <target> <publish_json_path> [--non-interactive] [--ci]
USAGE
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel 2>/dev/null)"; then
  :
else
  REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
fi
PUBLISH_HISTORY="$REPO_ROOT/project/logs/publish-history.json"
CUSTOM_SCRIPT_PATTERN='^[./a-zA-Z0-9_-]+$'

if [[ $# -lt 3 || $# -gt 5 ]]; then
  usage >&2
  exit 1
fi

PHASE="$1"
TARGET_NAME="$2"
PUBLISH_JSON="$3"
NON_INTERACTIVE=0
# 1 only on a genuine CI signal: this script's --ci argument, CI=true or GITHUB_ACTIONS=true. Neither
# --non-interactive (also sent for a human's `deploy --yes`) nor a missing tty is consent for a dependency
# audit, so the audit gate keys off this alone.
CI_CONSENT=0
PROMPT_INPUT_FD=0

if [[ "${CI:-}" == "true" || "${GITHUB_ACTIONS:-}" == "true" ]]; then
  CI_CONSENT=1
fi

for extra_arg in "${@:4}"; do
  case "$extra_arg" in
    --non-interactive) NON_INTERACTIVE=1 ;;
    --ci) CI_CONSENT=1 ;;
    *)
      usage >&2
      exit 1
      ;;
  esac
done

if [[ ! -t 0 ]]; then
  NON_INTERACTIVE=1
fi

if (( NON_INTERACTIVE == 0 )); then
  # The 2>/dev/null is scoped to a group: on a bare `exec`, a redirection is permanent, which silenced stderr
  # (failure blocks and prompts) for the rest of every interactive run.
  if { exec 3</dev/tty; } 2>/dev/null; then
    PROMPT_INPUT_FD=3
  else
    NON_INTERACTIVE=1
  fi
fi

if [[ "$PHASE" != "pre" && "$PHASE" != "post" ]]; then
  echo "Error: <phase> must be 'pre' or 'post'." >&2
  exit 1
fi

if [[ ! -f "$PUBLISH_JSON" ]]; then
  echo "Error: publish config not found at '$PUBLISH_JSON'." >&2
  exit 1
fi

if ! command -v jq >/dev/null 2>&1; then
  echo "Error: jq is required to run publish quality gates." >&2
  exit 1
fi

log_info() {
  printf '→ %s\n' "$1"
}

log_warn() {
  printf '⚠ %s\n' "$1" >&2
}

log_error() {
  printf '✗ %s\n' "$1" >&2
}

ensure_publish_history() {
  mkdir -p "$(dirname "$PUBLISH_HISTORY")"
  if [[ ! -f "$PUBLISH_HISTORY" ]]; then
    echo '[]' > "$PUBLISH_HISTORY"
  fi
}

append_gate_failure_history() {
  local gate_name="$1"
  local entry
  local history_tmp

  ensure_publish_history
  entry="$(jq -cn \
    --arg gate "$gate_name" \
    --arg phase "$PHASE" \
    --arg target "$TARGET_NAME" \
    --arg date "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" \
    '{event:"gate_failure",gate:$gate,phase:$phase,target:$target,date:$date,exit_code:2}')"

  history_tmp="$PUBLISH_HISTORY.tmp"
  jq --argjson entry "$entry" '. += [$entry]' "$PUBLISH_HISTORY" > "$history_tmp"
  mv "$history_tmp" "$PUBLISH_HISTORY"
}

print_results_summary() {
  local result

  if [[ ${#RESULTS[@]} -eq 0 ]]; then
    return 0
  fi

  echo "Gate results:"
  for result in "${RESULTS[@]}"; do
    printf '  - %s\n' "$result"
  done
}

jq_target_def() {
  cat <<'JQ'
def target_obj:
  if (.targets? | type) == "object" then
    .targets[$target]
  elif (.targets? | type) == "array" then
    (.targets[]? | select((.name // .id // .target // "") == $target))
  else
    empty
  end;
JQ
}

require_target() {
  local exists
  exists="$(jq -r --arg target "$TARGET_NAME" "$(jq_target_def) target_obj | if . == null or . == false then \"\" else \"yes\" end" "$PUBLISH_JSON")"
  if [[ -z "$exists" ]]; then
    log_error "Target '$TARGET_NAME' was not found in '$PUBLISH_JSON'."
    exit 1
  fi
}

TARGET_TYPE=""

resolve_target_type() {
  TARGET_TYPE="$(jq -r --arg target "$TARGET_NAME" "$(jq_target_def) target_obj | .type // empty" "$PUBLISH_JSON" | head -n 1)"
  # Default to mobile-ios when unset to preserve legacy behaviour.
  [[ -n "$TARGET_TYPE" ]] || TARGET_TYPE="mobile-ios"
}

get_gate_entries() {
  jq -c --arg target "$TARGET_NAME" --arg phase "$PHASE" "$(jq_target_def)
    target_obj as \$target_config |
    (\$target_config.checks[\$phase] // [])[]? |
    if type == \"string\" then
      {name: ., config: {}}
    elif type == \"object\" then
      if has(\"name\") then {name: .name, config: .}
      elif has(\"gate\") then {name: .gate, config: .}
      elif has(\"type\") then {name: .type, config: .}
      else empty end
    else
      empty
    end
  " "$PUBLISH_JSON"
}

get_value_from_config() {
  local key="$1"
  jq -r --arg target "$TARGET_NAME" --arg key "$key" "$(jq_target_def)
    target_obj as \$target_config |
    (
      \$target_config.checks[\$key] //
      \$target_config[\$key] //
      .checks[\$key] //
      .[\$key] //
      empty
    )
  " "$PUBLISH_JSON"
}

shell_quote() {
  printf '%q' "$1"
}

find_npm_script_command() {
  local script_name="$1"
  local package_file
  while IFS= read -r package_file; do
    if jq -e --arg script_name "$script_name" '.scripts[$script_name] // empty' "$package_file" >/dev/null 2>&1; then
      local package_dir
      package_dir="$(dirname "$package_file")"
      if [[ "$package_dir" == "$REPO_ROOT" ]]; then
        printf 'npm run %s\n' "$script_name"
      else
        printf 'npm --prefix %s run %s\n' "$(shell_quote "$package_dir")" "$script_name"
      fi
      return 0
    fi
  done < <(find "$REPO_ROOT" -name package.json -not -path '*/node_modules/*' -not -path '*/.git/*' | sort)
  return 1
}

# Resolve an npm script from the top-level package.json only (mirrors
# npm_pipeline.sh, which publishes $REPO_ROOT/package.json). Prints the
# command form npm uses for the built-in `test` script vs. `npm run <name>`.
find_npm_script_in_root() {
  local script_name="$1"
  local package_file="$REPO_ROOT/package.json"

  [[ -f "$package_file" ]] || return 1
  jq -e --arg script_name "$script_name" '.scripts[$script_name] // empty' "$package_file" >/dev/null 2>&1 || return 1

  # `npm test` is a first-class alias; everything else uses `npm run <name>`.
  if [[ "$script_name" == "test" ]]; then
    printf 'npm test\n'
  else
    printf 'npm run %s\n' "$script_name"
  fi
  return 0
}

find_xcodebuild_command() {
  local action="$1"
  if find "$REPO_ROOT" -maxdepth 4 \( -name '*.xcodeproj' -o -name '*.xcworkspace' \) | grep -q .; then
    printf 'xcodebuild %s\n' "$action"
    return 0
  fi
  return 1
}

resolve_default_command() {
  local gate_name="$1"

  # NPM targets: resolve strictly against $REPO_ROOT/package.json and never
  # fall through to iOS tooling. Missing scripts are announced with a clear
  # informational note (on stderr so it does not pollute the captured
  # command) before the gate is reported as skipped upstream.
  if [[ "$TARGET_TYPE" == "npm" || "$TARGET_TYPE" == "npm-ci" ]]; then
    case "$gate_name" in
      build|test|lint)
        if find_npm_script_in_root "$gate_name"; then
          return 0
        fi
        printf '→ npm gate %q skipped: no %q script defined in package.json\n' \
          "$gate_name" "$gate_name" >&2
        return 0
        ;;
      *)
        return 0
        ;;
    esac
  fi

  case "$gate_name" in
    build)
      find_npm_script_command build || find_xcodebuild_command build || true
      ;;
    test)
      find_npm_script_command test || find_xcodebuild_command test || true
      ;;
    lint)
      find_npm_script_command lint || true
      ;;
    type-check)
      find_npm_script_command typecheck || find_npm_script_command type-check || true
      ;;
    smoke-test)
      find_npm_script_command smoke-test || true
      ;;
    *)
      true
      ;;
  esac
}

RUN_OUTPUT=""
RUN_STATUS=0
LAST_GATE_COMMAND=""
RESOLVED_GATE_COMMAND=""

run_command_capture() {
  local command="$1"
  LAST_GATE_COMMAND="$command"
  set +e
  RUN_OUTPUT="$(bash -c "$command" 2>&1)"
  RUN_STATUS=$?
  set -e
}

print_failure_block() {
  local gate_name="$1"
  echo ""
  echo "========== GATE FAILURE ==========" >&2
  echo "Gate: $gate_name" >&2
  echo "Phase: $PHASE" >&2
  echo "Target: $TARGET_NAME" >&2
  echo "Command: ${LAST_GATE_COMMAND:-n/a}" >&2
  echo "Exit code: $RUN_STATUS" >&2
  echo "----------- output -----------" >&2
  if [[ -n "$RUN_OUTPUT" ]]; then
    printf '%s\n' "$RUN_OUTPUT" >&2
  else
    echo "(no output captured)" >&2
  fi
  echo "==================================" >&2
  echo "" >&2
}

attempt_gate() {
  local gate_json="$1"
  local gate_name="$2"
  local resolve_status

  if resolve_gate_command "$gate_name" "$gate_json"; then
    resolve_status=0
  else
    resolve_status=$?
  fi
  if [[ $resolve_status -ne 0 ]]; then
    return "$resolve_status"
  fi

  if [[ -z "$RESOLVED_GATE_COMMAND" ]]; then
    log_warn "No command resolved for gate '$gate_name'; skipping."
    return 1
  fi

  log_info "Running gate '$gate_name'..."
  run_command_capture "$RESOLVED_GATE_COMMAND"

  if [[ $RUN_STATUS -ne 0 ]]; then
    return 2
  fi

  return 0
}

handle_gate_failure() {
  local gate_name="$1"
  local gate_json="$2"
  local retry_count=0
  local choice
  local choice_lower
  local retry_status

  append_gate_failure_history "$gate_name"
  print_failure_block "$gate_name"

  if (( NON_INTERACTIVE )); then
    return 2
  fi

  while true; do
    if (( retry_count >= 3 )); then
      log_error "Retry limit reached for gate '$gate_name'. Aborting deploy."
      return 2
    fi

    read -r -u "$PROMPT_INPUT_FD" -p "[r] Retry after fixing / [a] Abort deploy: " choice || choice="a"
    choice_lower="$(printf '%s' "$choice" | tr '[:upper:]' '[:lower:]')"
    case "$choice_lower" in
      r)
        retry_count=$((retry_count + 1))
        log_info "Retrying gate '$gate_name' (attempt $retry_count of 3)..."
        if attempt_gate "$gate_json" "$gate_name"; then
          retry_status=0
        else
          retry_status=$?
        fi
        case $retry_status in
          0)
            return 0
          ;;
          1)
            return 1
          ;;
          2)
            append_gate_failure_history "$gate_name"
            print_failure_block "$gate_name"
          ;;
        esac
        ;;
      a)
        log_error "Deploy aborted after gate '$gate_name' failed."
        return 2
        ;;
      *)
        echo "Please enter 'r' or 'a'." >&2
        ;;
    esac
  done
}

resolve_custom_script_command() {
  local gate_json="$1"
  local script_path
  local resolved_path
  script_path="$(printf '%s' "$gate_json" | jq -r '.config.path // .config.script // .config.command // .config.custom_script_path // empty')"
  if [[ -z "$script_path" ]]; then
    script_path="$(get_value_from_config custom_script)"
  fi
  if [[ -z "$script_path" ]]; then
    script_path="$(get_value_from_config custom_script_path)"
  fi
  if [[ -z "$script_path" ]]; then
    script_path="$(get_value_from_config custom_script_command)"
  fi

  if [[ -z "$script_path" ]]; then
    log_warn "No custom script path configured for target '$TARGET_NAME'; skipping custom-script gate."
    return 1
  fi

  if [[ ! "$script_path" =~ $CUSTOM_SCRIPT_PATTERN ]]; then
    RUN_OUTPUT="Rejected custom-script path '$script_path': only [./a-zA-Z0-9_-] characters are allowed."
    RUN_STATUS=2
    LAST_GATE_COMMAND="$script_path"
    return 2
  fi

  if [[ "$script_path" = /* ]]; then
    resolved_path="$script_path"
  else
    resolved_path="$REPO_ROOT/${script_path#./}"
  fi

  if [[ ! -f "$resolved_path" ]]; then
    RUN_OUTPUT="Custom script '$resolved_path' does not exist."
    RUN_STATUS=2
    LAST_GATE_COMMAND="$resolved_path"
    return 2
  fi

  if [[ -x "$resolved_path" ]]; then
    RESOLVED_GATE_COMMAND="$(shell_quote "$resolved_path")"
  else
    RESOLVED_GATE_COMMAND="bash $(shell_quote "$resolved_path")"
  fi
  return 0
}

resolve_ping_command() {
  local gate_json="$1"
  local ping_url
  ping_url="$(printf '%s' "$gate_json" | jq -r '.config.url // .config.ping_url // empty')"
  if [[ -z "$ping_url" ]]; then
    ping_url="$(get_value_from_config ping_url)"
  fi

  if [[ -z "$ping_url" ]]; then
    log_warn "No ping URL configured for target '$TARGET_NAME'; skipping ping gate."
    return 1
  fi

  RESOLVED_GATE_COMMAND="curl -fsS -o /dev/null $(shell_quote "$ping_url")"
  return 0
}

resolve_gate_command() {
  local gate_name="$1"
  local gate_json="$2"
  local command_override=""
  RESOLVED_GATE_COMMAND=""

  case "$gate_name" in
    build)
      command_override="$(get_value_from_config build_command)"
      ;;
    test)
      command_override="$(get_value_from_config test_command)"
      ;;
    lint)
      command_override="$(get_value_from_config lint_command)"
      ;;
    type-check)
      command_override="$(get_value_from_config typecheck_command)"
      ;;
    smoke-test)
      command_override="$(get_value_from_config smoke_test_command)"
      ;;
    custom-script)
      resolve_custom_script_command "$gate_json"
      return $?
      ;;
    ping)
      resolve_ping_command "$gate_json"
      return $?
      ;;
    *)
      log_warn "Unsupported gate '$gate_name'; skipping."
      return 1
      ;;
  esac

  if [[ -n "$command_override" ]]; then
    RESOLVED_GATE_COMMAND="$command_override"
    return 0
  fi

  RESOLVED_GATE_COMMAND="$(resolve_default_command "$gate_name")"
  return 0
}

RESULTS=()

# Print the path of a repo-level script, trying the checkout layout first and the npm-installed layout second.
find_repo_script() {
  local name="$1"
  local candidate
  for candidate in \
    "$SCRIPT_DIR/../../../scripts/$name" \
    "$REPO_ROOT/scripts/$name" \
    "$REPO_ROOT/node_modules/@jenga-ai/agent/scripts/$name"; do
    if [[ -f "$candidate" ]]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done
  return 1
}

# Interactive choice after an audit with findings: [p] proceed anyway / [s] stop. Returns 0 to proceed, 2 to stop.
prompt_audit_proceed() {
  local choice choice_lower
  while true; do
    read -r -u "$PROMPT_INPUT_FD" -p "[p] Proceed anyway / [s] Stop: " choice || choice="s"
    choice_lower="$(printf '%s' "$choice" | tr '[:upper:]' '[:lower:]')"
    case "$choice_lower" in
      p) return 0 ;;
      s) return 2 ;;
      *) echo "Please enter 'p' or 's'." >&2 ;;
    esac
  done
}

# Runs the dependency audit gate. Appends one entry to RESULTS. Returns 0 to continue, 2 to abort the run.
run_audit_gate() {
  local audit_script record_script package_dir out_file err_file audit_status audit_json_status
  local -a audit_args

  if [[ "$TARGET_TYPE" != "npm" && "$TARGET_TYPE" != "npm-ci" ]]; then
    RESULTS+=("audit:skipped (not an npm target)")
    log_info "Gate 'audit' skipped: not an npm target."
    return 0
  fi

  if ! audit_script="$(find_repo_script audit-deps.sh)"; then
    log_warn "Dependency audit skipped: audit-deps.sh was not found."
    RESULTS+=("audit:skipped (audit-deps.sh not found)")
    return 0
  fi
  record_script="$(find_repo_script audit-record.sh || true)"

  # npm_pipeline.sh publishes $REPO_ROOT/package.json, so that is the directory to audit.
  package_dir="$REPO_ROOT"
  audit_args=(--dir "$package_dir" --json)
  if (( CI_CONSENT )); then
    audit_args+=(--ci)
  fi

  out_file="$(mktemp "${TMPDIR:-/tmp}/run-gates-audit.XXXXXX")"
  err_file="$(mktemp "${TMPDIR:-/tmp}/run-gates-audit-err.XXXXXX")"
  log_info "Running gate 'audit'..."
  set +e
  bash "$audit_script" "${audit_args[@]}" >"$out_file" 2>"$err_file"
  audit_status=$?
  set -e
  LAST_GATE_COMMAND="audit-deps.sh ${audit_args[*]}"

  audit_json_status=""
  if jq -e 'type == "object"' "$out_file" >/dev/null 2>&1; then
    audit_json_status="$(jq -r '.status // ""' "$out_file")"
    if [[ -n "$record_script" ]]; then
      bash "$record_script" result --file "$out_file" --agent j-publish >/dev/null 2>&1 \
        || log_warn "Could not record the audit result (audit-record.sh failed)."
    fi
  fi

  case $audit_status in
    0)
      if [[ "$audit_json_status" == "unavailable" ]]; then
        log_warn "Dependency audit unavailable (offline_behavior warn); continuing. $(tail -n 1 "$err_file")"
        RESULTS+=("audit:passed (unavailable, warning)")
      else
        RESULTS+=("audit:passed")
      fi
      log_info "Gate 'audit' passed."
      rm -f "$out_file" "$err_file"
      return 0
      ;;
    4)
      log_warn "Dependency audit skipped: no consent ($(tail -n 1 "$err_file")). To opt in, set mode to on in project/configs/audit-config.json (for example: jenga config set audit-config.mode on) or run the audit explicitly (scripts/audit-deps.sh --approved after you agree); publish does not decide consent."
      RESULTS+=("audit:skipped (no consent)")
      rm -f "$out_file" "$err_file"
      return 0
      ;;
    1)
      RUN_STATUS=1
      RUN_OUTPUT="$(jq -r '"threshold: \(.threshold)",
        (.findings[]? | "- \(.severity): \(.name) (fix available: \(.fix_available))")' "$out_file" 2>/dev/null || true)"
      ;;
    *)
      RUN_STATUS=$audit_status
      RUN_OUTPUT="$(cat "$err_file" 2>/dev/null || true)"
      ;;
  esac
  rm -f "$out_file" "$err_file"

  # Failure paths: findings at or above the threshold (1), config error (2), unavailable under fail (3).
  append_gate_failure_history "audit"
  print_failure_block "audit"
  if (( NON_INTERACTIVE )) || [[ $audit_status -ne 1 ]]; then
    return 2
  fi
  if prompt_audit_proceed; then
    log_warn "Proceeding despite dependency audit findings."
    RESULTS+=("audit:failed (proceeded anyway)")
    return 0
  fi
  log_error "Deploy stopped after the dependency audit reported findings."
  return 2
}

run_gate() {
  local gate_json="$1"
  local gate_name
  local gate_status

  gate_name="$(printf '%s' "$gate_json" | jq -r '.name')"
  if [[ "$gate_name" == "audit" && "$(printf '%s' "$gate_json" | jq -r '.source // ""')" == "audit" ]]; then
    run_audit_gate
    return $?
  fi
  if attempt_gate "$gate_json" "$gate_name"; then
    gate_status=0
  else
    gate_status=$?
  fi
  case $gate_status in
    0)
      RESULTS+=("$gate_name:passed")
      log_info "Gate '$gate_name' passed."
      return 0
      ;;
    1)
      RESULTS+=("$gate_name:skipped")
      return 0
      ;;
    2)
      if handle_gate_failure "$gate_name" "$gate_json"; then
        gate_status=0
      else
        gate_status=$?
      fi
      case $gate_status in
        0)
          RESULTS+=("$gate_name:passed")
          log_info "Gate '$gate_name' passed."
          return 0
          ;;
        1)
          RESULTS+=("$gate_name:skipped")
          return 0
          ;;
        2)
          return 2
          ;;
      esac
      ;;
  esac
}

build_gate_list() {
  local gate_json
  local -a mandatory_pre_gates=()

  if [[ "$PHASE" == "pre" ]]; then
    if [[ "$TARGET_TYPE" == "npm" || "$TARGET_TYPE" == "npm-ci" ]]; then
      # npm-specific mandatory gates: test, build, lint (per E26_S06_T03).
      mandatory_pre_gates=(test build lint)
    else
      mandatory_pre_gates=(build test)
    fi
    local gate
    for gate in "${mandatory_pre_gates[@]}"; do
      printf '{"name":"%s","config":{},"source":"mandatory"}\n' "$gate"
    done
    # Built-in dependency audit gate, after the mandatory gates (run_audit_gate reports non-npm targets as skipped).
    printf '{"name":"audit","config":{},"source":"audit"}\n'
  fi

  while IFS= read -r gate_json; do
    [[ -z "$gate_json" ]] && continue
    local gate_name
    gate_name="$(printf '%s' "$gate_json" | jq -r '.name')"
    if [[ "$PHASE" == "pre" ]]; then
      local is_mandatory=0
      local m_gate
      for m_gate in "${mandatory_pre_gates[@]}" audit; do
        if [[ "$gate_name" == "$m_gate" ]]; then
          is_mandatory=1
          break
        fi
      done
      if (( is_mandatory )); then
        log_warn "Ignoring configurable '$gate_name' gate for target '$TARGET_NAME'; mandatory global gates already enforce it."
        continue
      fi
    fi
    printf '%s\n' "$gate_json"
  done < <(get_gate_entries)
}

main() {
  local gate_json

  require_target
  resolve_target_type
  ensure_publish_history

  while IFS= read -r gate_json; do
    [[ -z "$gate_json" ]] && continue
    run_gate "$gate_json" || exit 2
  done < <(build_gate_list)

  print_results_summary
  log_info "All $PHASE-deploy gates completed successfully for target '$TARGET_NAME'."
}

main "$@"
