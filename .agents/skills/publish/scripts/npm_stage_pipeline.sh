#!/usr/bin/env bash
# npm_stage_pipeline.sh — `/publish stage publish`: submit a version to npm's
# staged-publishing area, gated by the mandatory build/test pre-deploy gates.
#
# Six ordered phases — the order is the point, since gates that ran after
# staging would be verifying nothing:
#   1. validate — validate_npm_stage_env.sh (T01); abort on non-zero
#   2. gates    — run_gates.sh pre <target> <config> [--non-interactive]
#                 (build/test are mandatory, global, non-disableable)
#   3. pack     — resolve <name>@<version>, confirm unless --non-interactive
#   4. stage    — for `npm` targets: `npm stage publish --tag ... --access
#                 ... [--otp ...]` run locally. For `npm-ci` targets,
#                 `--provenance` needs a GitHub Actions OIDC token that only
#                 exists inside an Actions run, so this phase instead
#                 dispatches the `stage` job of the target's generated
#                 workflow (see npm_ci_pipeline.sh) via `gh workflow run
#                 ... -f mode=stage` and waits on it with `gh run watch`.
#   5. capture  — parse the stage id, falling back to `npm stage list --json`
#   6. ledger   — write_ledger_entry.sh ... staged ... --stage-id <id> --dist-tag <tag>
#
# Usage:
#   npm_stage_pipeline.sh <target> <path-to-publish.json> [--dry-run] [--non-interactive] [--otp <otp>]
#
# Exit codes:
#   0  success (staged, or --dry-run completed cleanly)
#   1  user declined the pack confirmation prompt (or no tty was available)
#   2  a mandatory pre-deploy gate failed; nothing was staged
#   3  staging failed (locally for `npm`, or the dispatched GitHub Actions
#      run for `npm-ci`), or the stage id could not be captured
#   4  validation failed (validate_npm_stage_env.sh's own exit code, or bad
#      args/config)
#
# Security note: --otp is placed into the exec argv passed directly to `npm`
# and nowhere else — never interpolated into a printed or logged string. If
# command tracing (`set -x`) is active when this script starts — inherited
# via SHELLOPTS/BASH_ENV, or the caller ran `bash -x npm_stage_pipeline.sh
# ... --otp <otp>` — and an --otp value is present in argv, tracing is
# disabled before OTP is ever assigned to a variable and stays disabled for
# the rest of the run (see the "OTP tracing guard" block below for why this
# has to be the whole run, not just the npm invocation). The captured output
# of the stage invocation is additionally scrubbed of the literal OTP value
# defensively, before it is ever printed.

set -euo pipefail

EXIT_ABORTED=1
EXIT_GATE_FAILURE=2
EXIT_STAGE_FAILURE=3
EXIT_ENV_INVALID=4

DEFAULT_REGISTRY="https://registry.npmjs.org"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if REPO_ROOT="$(git -C "${SCRIPT_DIR}" rev-parse --show-toplevel 2>/dev/null)"; then
  :
else
  REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
fi

# shellcheck source=publish_common.sh
source "${SCRIPT_DIR}/publish_common.sh"

VALIDATE_SCRIPT="${SCRIPT_DIR}/validate_npm_stage_env.sh"
RUN_GATES_SCRIPT="${SCRIPT_DIR}/run_gates.sh"
WRITE_LEDGER_SCRIPT="${SCRIPT_DIR}/write_ledger_entry.sh"

usage() {
  cat <<'USAGE'
Usage: npm_stage_pipeline.sh <target> <path-to-publish.json> [--dry-run] [--non-interactive] [--otp <otp>]

Phases (in order): validate, gates, pack, stage, capture, ledger.
USAGE
}

fail_usage() {
  usage >&2
  printf 'npm stage pipeline error: %s\n' "$1" >&2
  exit "${EXIT_ENV_INVALID}"
}

log_info() {
  printf '→ %s\n' "$1"
}

log_warn() {
  printf '⚠ %s\n' "$1" >&2
}

# ---------------------------------------------------------------------------
# OTP tracing guard — must run before argv is parsed, i.e. before OTP is
# ever assigned to a variable. If the caller invoked this script with
# command tracing already enabled (`set -x`, inherited via SHELLOPTS/
# BASH_ENV, or `bash -x npm_stage_pipeline.sh ... --otp <otp>`) and an
# --otp value is present anywhere in argv, tracing is disabled immediately
# and stays disabled for the remainder of this run.
#
# A narrower window — e.g. suspending tracing only around the `npm stage
# publish` call itself and restoring it afterward — is NOT sufficient:
# bash's xtrace prints the *expanded* value of $OTP for every subsequent
# line that so much as references the variable. A plain truthiness check
# like `[[ -n "$OTP" ]]` is traced as `+ [[ -n 123456 ]]`, leaking the code
# just as surely as printing it directly. The only reliable guard is to
# suspend tracing before the first assignment and never re-enable it for
# the rest of the run.
# ---------------------------------------------------------------------------
OTP_PRESENT_IN_ARGV=0
for _arg in "$@"; do
  case "${_arg}" in
    --otp|--otp=*)
      OTP_PRESENT_IN_ARGV=1
      ;;
  esac
done
unset _arg
if (( OTP_PRESENT_IN_ARGV )); then
  case "$-" in
    *x*) set +x ;;
  esac
fi

# ---------------------------------------------------------------------------
# Arg parsing
# ---------------------------------------------------------------------------
DRY_RUN=0
NON_INTERACTIVE=0
OTP=""

POSITIONAL=()
while (( $# )); do
  case "$1" in
    --dry-run)
      DRY_RUN=1
      shift
      ;;
    --non-interactive)
      NON_INTERACTIVE=1
      shift
      ;;
    --otp)
      [[ $# -ge 2 ]] || fail_usage "--otp requires a value"
      OTP="$2"
      shift 2
      ;;
    --otp=*)
      OTP="${1#*=}"
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    --)
      shift
      while (( $# )); do
        POSITIONAL+=("$1")
        shift
      done
      ;;
    -*)
      fail_usage "unknown option: $1"
      ;;
    *)
      POSITIONAL+=("$1")
      shift
      ;;
  esac
done

[[ ${#POSITIONAL[@]} -ge 1 ]] || fail_usage "<target> is required"
TARGET_NAME="${POSITIONAL[0]}"
[[ ${#POSITIONAL[@]} -ge 2 ]] || fail_usage "<path-to-publish.json> is required"
CONFIG_PATH_ARG="${POSITIONAL[1]}"
[[ ${#POSITIONAL[@]} -le 2 ]] || fail_usage "unexpected extra positional arguments"

command -v jq >/dev/null 2>&1 || fail_usage "jq is required but not found on PATH"
command -v npm >/dev/null 2>&1 || fail_usage "npm is required but not found on PATH"

CONFIG_PATH="$(publish_normalize_path "${CONFIG_PATH_ARG}")"
[[ -f "${CONFIG_PATH}" ]] || fail_usage "publish config not found at '${CONFIG_PATH}'"

# ---------------------------------------------------------------------------
# Phase 1: validate
# ---------------------------------------------------------------------------
log_info "[validate] checking staging environment for target '${TARGET_NAME}'..."

VALIDATE_STATUS=0
bash "${VALIDATE_SCRIPT}" "${TARGET_NAME}" "${CONFIG_PATH}" || VALIDATE_STATUS=$?
if [[ ${VALIDATE_STATUS} -ne 0 ]]; then
  printf 'npm stage pipeline: environment validation failed (exit %s); nothing staged.\n' "${VALIDATE_STATUS}" >&2
  exit "${VALIDATE_STATUS}"
fi

# ---------------------------------------------------------------------------
# Phase 2: gates — build/test are mandatory global pre-deploy gates for
# npm/npm-ci targets (enforced inside run_gates.sh itself; not repeated or
# re-implemented here) and cannot be disabled via target config.
# ---------------------------------------------------------------------------
log_info "[gates] running mandatory pre-deploy gates (build, test) for target '${TARGET_NAME}'..."

GATES_CMD=(bash "${RUN_GATES_SCRIPT}" pre "${TARGET_NAME}" "${CONFIG_PATH}")
(( NON_INTERACTIVE )) && GATES_CMD+=(--non-interactive)

GATES_STATUS=0
"${GATES_CMD[@]}" || GATES_STATUS=$?
if [[ ${GATES_STATUS} -ne 0 ]]; then
  printf 'npm stage pipeline: pre-deploy gates failed; nothing staged.\n' >&2
  exit "${EXIT_GATE_FAILURE}"
fi

# ---------------------------------------------------------------------------
# Phase 3: pack — resolve <name>@<version> and confirm
# ---------------------------------------------------------------------------
TARGET_JSON="$(jq -c --arg t "${TARGET_NAME}" '.targets[]? | select(.name == $t)' "${CONFIG_PATH}")"
[[ -n "${TARGET_JSON}" ]] || fail_usage "target '${TARGET_NAME}' was not found in '${CONFIG_PATH}'"

TARGET_TYPE="$(printf '%s' "${TARGET_JSON}" | jq -r '.type // empty')"
if [[ "${TARGET_TYPE}" != "npm" && "${TARGET_TYPE}" != "npm-ci" ]]; then
  fail_usage "target '${TARGET_NAME}' has type '${TARGET_TYPE}'; staging only supports 'npm' and 'npm-ci'"
fi

PACKAGE_NAME="$(printf '%s' "${TARGET_JSON}" | jq -r '.npm.package_name // empty')"
[[ -n "${PACKAGE_NAME}" ]] || fail_usage "target '${TARGET_NAME}' is missing required field 'npm.package_name'"

NPM_ACCESS="$(printf '%s' "${TARGET_JSON}" | jq -r '.npm.access // empty')"
[[ -n "${NPM_ACCESS}" ]] || fail_usage "target '${TARGET_NAME}' is missing required field 'npm.access'"

DIST_TAG="$(printf '%s' "${TARGET_JSON}" | jq -r '.npm.dist_tag // "latest"')"
REGISTRY="$(printf '%s' "${TARGET_JSON}" | jq -r --arg d "${DEFAULT_REGISTRY}" '.npm.registry // $d')"

PACKAGE_JSON="${REPO_ROOT}/package.json"
[[ -f "${PACKAGE_JSON}" ]] || fail_usage "package.json not found at '${PACKAGE_JSON}'"

PACKAGE_VERSION="$(jq -r '.version // empty' "${PACKAGE_JSON}")"
[[ -n "${PACKAGE_VERSION}" ]] || fail_usage "package.json is missing a 'version' field"

PACKAGE_SPEC="${PACKAGE_NAME}@${PACKAGE_VERSION}"

echo "========== NPM STAGE PIPELINE =========="
printf 'Target:   %s (%s)\n' "${TARGET_NAME}" "${TARGET_TYPE}"
printf 'Package:  %s\n' "${PACKAGE_SPEC}"
printf 'Dist tag: %s\n' "${DIST_TAG}"
printf 'Access:   %s\n' "${NPM_ACCESS}"
printf 'Registry: %s\n' "${REGISTRY}"
printf 'Mode:     %s\n' "$( (( DRY_RUN )) && echo 'dry-run' || echo 'live stage' )"
echo "=========================================="

if (( NON_INTERACTIVE == 0 )); then
  PACK_CONFIRM_FD=""
  if [[ -t 0 ]] && exec 3</dev/tty 2>/dev/null; then
    PACK_CONFIRM_FD=3
  fi

  if [[ -z "${PACK_CONFIRM_FD}" ]]; then
    log_warn "no interactive tty available for pack confirmation; treating as declined. Pass --non-interactive to bypass."
    PACK_RESPONSE=""
  else
    printf 'Stage %s to target "%s"? [y/N] ' "${PACKAGE_SPEC}" "${TARGET_NAME}" >&2
    if ! IFS= read -r -u "${PACK_CONFIRM_FD}" PACK_RESPONSE; then
      PACK_RESPONSE=""
    fi
    exec 3<&- 2>/dev/null || true
  fi

  case "${PACK_RESPONSE:-}" in
    y|Y|yes|YES)
      : ;;
    *)
      printf 'npm stage pipeline: pack confirmation declined; nothing staged.\n' >&2
      exit "${EXIT_ABORTED}"
      ;;
  esac
else
  log_info "[pack] --non-interactive: skipping confirmation prompt for ${PACKAGE_SPEC}"
fi

# ---------------------------------------------------------------------------
# Phase 4: stage
#
# `npm` targets stage locally via `npm stage publish`. `npm-ci` targets pass
# `--provenance`, which requires a GitHub Actions OIDC token that only
# exists inside an Actions run — there is no local equivalent — so instead
# this dispatches the `stage` job of the target's generated workflow (the
# same workflow file/OIDC Trusted Publisher link `npm_ci_pipeline.sh` uses
# for `/publish deploy`) via `gh workflow run ... -f mode=stage` and waits
# for it with `gh run watch`.
# ---------------------------------------------------------------------------
STAGE_OUTPUT=""
STAGE_STATUS=0

if [[ "${TARGET_TYPE}" == "npm-ci" ]]; then
  command -v gh >/dev/null 2>&1 || fail_usage "'gh' CLI is required to stage an 'npm-ci' target (staging is dispatched as a GitHub Actions workflow run) but was not found on PATH"

  GITHUB_REPO="$(printf '%s' "${TARGET_JSON}" | jq -r '.github_repo // empty')"
  [[ -n "${GITHUB_REPO}" ]] || fail_usage "target '${TARGET_NAME}' is missing required field 'github_repo' (needed to dispatch the stage job)"

  WORKFLOW_PATH="$(printf '%s' "${TARGET_JSON}" | jq -r '.workflow_path // ".github/workflows/npm-publish.yml"')"
  WORKFLOW_FILENAME="$(basename "${WORKFLOW_PATH}")"

  if (( DRY_RUN )); then
    log_info "[dry-run] would dispatch: gh workflow run ${WORKFLOW_FILENAME} --repo ${GITHUB_REPO} -f mode=stage (tag=${DIST_TAG}, access=${NPM_ACCESS})"
    log_info "[dry-run] no workflow run triggered; no ledger entry written, no registry-mutating call made."
    exit 0
  fi

  log_info "[stage] dispatching 'stage' job of ${WORKFLOW_FILENAME} on ${GITHUB_REPO}..."
  if ! gh workflow run "${WORKFLOW_FILENAME}" --repo "${GITHUB_REPO}" -f mode=stage; then
    printf 'npm stage pipeline: gh workflow run failed; nothing staged.\n' >&2
    exit "${EXIT_STAGE_FAILURE}"
  fi

  RUN_ID="$(gh run list --workflow "${WORKFLOW_FILENAME}" --repo "${GITHUB_REPO}" --limit 1 --json databaseId --jq '.[0].databaseId')"
  [[ -n "${RUN_ID}" ]] || fail_usage "dispatched the stage workflow but could not resolve its run id via 'gh run list'"

  log_info "[stage] waiting on run ${RUN_ID}..."
  gh run watch "${RUN_ID}" --repo "${GITHUB_REPO}" --exit-status || STAGE_STATUS=$?

  RUN_URL="$(gh run view "${RUN_ID}" --repo "${GITHUB_REPO}" --json url --jq '.url' 2>/dev/null || true)"
  STAGE_OUTPUT="staged via GitHub Actions workflow run: ${RUN_URL}"
else
  STAGE_CMD_BASE=(npm stage publish --tag "${DIST_TAG}" --access "${NPM_ACCESS}")
  [[ -n "${REGISTRY}" ]] && STAGE_CMD_BASE+=(--registry "${REGISTRY}")

  DISPLAY_CMD=("${STAGE_CMD_BASE[@]}")
  (( DRY_RUN )) && DISPLAY_CMD+=(--dry-run)
  [[ -n "${OTP}" ]] && DISPLAY_CMD+=(--otp '********')

  log_info "[stage] resolved command: $(printf '%q ' "${DISPLAY_CMD[@]}")"

  EXEC_CMD=("${STAGE_CMD_BASE[@]}")
  (( DRY_RUN )) && EXEC_CMD+=(--dry-run)
  # Tracing was already suspended for the rest of this run (if it was
  # active) by the "OTP tracing guard" above, the moment argv was found to
  # contain --otp — before OTP was ever assigned to a variable. Nothing
  # further to do here.
  [[ -n "${OTP}" ]] && EXEC_CMD+=(--otp "${OTP}")

  STAGE_OUTPUT="$(cd "${REPO_ROOT}" && "${EXEC_CMD[@]}" 2>&1)" || STAGE_STATUS=$?

  # Defensive redaction: strip the literal OTP from captured output before
  # it is ever printed, in case npm echoed the argv back in an error
  # message. Quoting the pattern operand of ${var//pattern/repl} forces a
  # literal (non-glob) match, so this is safe even if the OTP happens to
  # contain characters that are special to bash's extglob pattern matching.
  if [[ -n "${OTP}" ]]; then
    STAGE_OUTPUT="${STAGE_OUTPUT//"${OTP}"/********}"
  fi
fi

printf '%s\n' "${STAGE_OUTPUT}"

if [[ ${STAGE_STATUS} -ne 0 ]]; then
  printf 'npm stage pipeline: staging failed (exit %s); nothing staged.\n' "${STAGE_STATUS}" >&2
  exit "${EXIT_STAGE_FAILURE}"
fi

if (( DRY_RUN )); then
  log_info "[dry-run] npm stage publish --dry-run completed; no ledger entry written, no registry-mutating call made."
  exit 0
fi

# ---------------------------------------------------------------------------
# Phase 5: capture — parse the stage id
# ---------------------------------------------------------------------------
log_info "[capture] parsing stage id from stage output..."

STAGE_ID=""

# Attempt 1: direct-output parsing. Tolerant of label variants npm may use
# ("stage id:", "stageId:", "stage_id="), case-insensitive.
STAGE_ID="$(printf '%s\n' "${STAGE_OUTPUT}" \
  | grep -Eio '\bstage[ _-]?id["'"'"']?[[:space:]]*[:=][[:space:]]*["'"'"']?[A-Za-z0-9._-]+' \
  | head -n 1 \
  | grep -Eo '[A-Za-z0-9._-]+$' || true)"

# Attempt 2: the captured output is itself JSON (e.g. if npm's stage publish
# supports --json the way `npm publish --json` does).
if [[ -z "${STAGE_ID}" ]] && printf '%s' "${STAGE_OUTPUT}" | jq -e . >/dev/null 2>&1; then
  STAGE_ID="$(printf '%s' "${STAGE_OUTPUT}" | jq -r '.id // .stageId // .stage_id // empty' 2>/dev/null || true)"
fi

# Attempt 3: fall back to `npm stage list <package>@<version> --json` and
# extract the most recent matching entry's id.
if [[ -z "${STAGE_ID}" ]]; then
  log_warn "could not parse a stage id directly from stage output; falling back to 'npm stage list --json'..."

  LIST_STATUS=0
  LIST_OUTPUT="$(npm stage list "${PACKAGE_SPEC}" --json 2>&1)" || LIST_STATUS=$?

  if [[ ${LIST_STATUS} -ne 0 ]]; then
    printf '%s\n' "${LIST_OUTPUT}" >&2
    printf 'npm stage pipeline: staged successfully but stage id capture failed (npm stage list also exited %s).\n' "${LIST_STATUS}" >&2
    exit "${EXIT_STAGE_FAILURE}"
  fi

  if printf '%s' "${LIST_OUTPUT}" | jq -e . >/dev/null 2>&1; then
    STAGE_ID="$(printf '%s' "${LIST_OUTPUT}" | jq -r --arg pkg "${PACKAGE_NAME}" --arg ver "${PACKAGE_VERSION}" '
      ( if (type == "array") then . else (.stages? // .items? // []) end ) as $entries
      | [ $entries[]? | select(((.name // .package // "") == $pkg) and ((.version // "") == $ver)) ]
      | sort_by(.stagedAt // .staged_at // .created // .createdAt // "")
      | last
      | (.id // .stageId // .stage_id // empty)
    ' 2>/dev/null || true)"
  fi
fi

if [[ -z "${STAGE_ID}" ]]; then
  printf 'npm stage pipeline: staged successfully but the stage id could not be captured from either the direct output or "npm stage list --json". Run "npm stage list %s --json" manually to recover it.\n' "${PACKAGE_SPEC}" >&2
  exit "${EXIT_STAGE_FAILURE}"
fi

echo ""
echo "=========================================="
printf ' STAGE ID: %s\n' "${STAGE_ID}"
echo "=========================================="
echo ""

# ---------------------------------------------------------------------------
# Phase 6: ledger — record the staged entry
# ---------------------------------------------------------------------------
log_info "[ledger] recording 'staged' ledger entry for ${PACKAGE_SPEC}..."

LEDGER_CMD=(bash "${WRITE_LEDGER_SCRIPT}" "${TARGET_NAME}" "${TARGET_TYPE}" staged "" \
  --version "${PACKAGE_VERSION}" --config "${CONFIG_PATH}" --stage-id "${STAGE_ID}" --dist-tag "${DIST_TAG}")
"${LEDGER_CMD[@]}"

log_info "[done] ${PACKAGE_SPEC} staged as ${STAGE_ID} (dist-tag: ${DIST_TAG}). Awaiting 'npm_stage_inspect.sh test' and approval."
