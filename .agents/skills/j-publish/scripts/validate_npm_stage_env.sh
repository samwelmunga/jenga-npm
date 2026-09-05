#!/usr/bin/env bash
# validate_npm_stage_env.sh — Preflight gate for `/publish stage`.
#
# npm's staged-publishing workflow (npm CLI >= 11.15.0, Node >= 22.14.0) only exists on
# recent toolchains, only applies to `npm`/`npm-ci` targets, and only works for a package
# that has already had at least one non-staged publish. This script checks all four
# preconditions up front so the rest of the `/publish stage` pipeline never has to discover
# one of them has failed midway through a staging attempt.
#
# Usage:
#   validate_npm_stage_env.sh <target> <path-to-publish.json>
#
# Exit codes:
#   0  all four preflight checks passed
#   4  one of the checks failed (config/environment invalid), matching
#      skills/j-publish/assets/ci-contract.md
#
# Security note: the registry probe (check 4) never prints npm's raw stdout/stderr. Only
# messages composed by this script are emitted, so nothing npm writes — which could in
# principle include auth-related registry response detail — reaches stdout, stderr, or any
# log this script's caller might capture.

set -u

EXIT_ENV_INVALID=4

NPM_MIN_VERSION="11.15.0"
NODE_MIN_VERSION="22.14.0"
DEFAULT_REGISTRY="https://registry.npmjs.org"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ---------------------------------------------------------------------------
# Shared helpers (repo-root resolution, path normalization) — reused rather
# than re-implemented, per the repo-root-then-project/configs/ convention
# already established in publish_common.sh.
# ---------------------------------------------------------------------------
# shellcheck source=publish_common.sh
source "${SCRIPT_DIR}/publish_common.sh"

fail() {
  printf 'stage env validation failed: %s\n' "$1" >&2
  exit "${EXIT_ENV_INVALID}"
}

usage() {
  cat <<'USAGE'
Usage: validate_npm_stage_env.sh <target> <path-to-publish.json>
USAGE
}

# ---------------------------------------------------------------------------
# Semver comparison — component-wise numeric compare, boundary inclusive.
# A naive string or float compare gets "11.9.0 < 11.15.0" backwards (float
# compare would read 11.9 > 11.15); comparing each dotted component as a
# base-10 integer gets it right regardless of leading zeros.
# ---------------------------------------------------------------------------
version_ge() {
  local version="$1" min="$2"
  local -a v_parts m_parts
  IFS='.' read -r -a v_parts <<< "$version"
  IFS='.' read -r -a m_parts <<< "$min"

  local i v m
  for i in 0 1 2; do
    v="${v_parts[i]:-0}"
    m="${m_parts[i]:-0}"
    # Strip any non-digit suffix (pre-release/build metadata) so `10#` never
    # trips over a stray character; default to 0 if nothing numeric remains.
    v="${v//[!0-9]/}"
    m="${m//[!0-9]/}"
    v="${v:-0}"
    m="${m:-0}"
    if ((10#$v > 10#$m)); then
      return 0
    elif ((10#$v < 10#$m)); then
      return 1
    fi
  done
  return 0
}

# ---------------------------------------------------------------------------
# Argument & dependency sanity checks
# ---------------------------------------------------------------------------
TARGET_NAME="${1:-}"
CONFIG_PATH_ARG="${2:-}"

if [[ -z "${TARGET_NAME}" ]]; then
  usage >&2
  fail "missing target name argument"
fi

command -v jq >/dev/null 2>&1 || fail "jq is required but not found on PATH"
command -v npm >/dev/null 2>&1 || fail "'npm' was not found on PATH. Install Node.js (which provides npm) from https://nodejs.org/ or via your package manager, then re-run."
command -v node >/dev/null 2>&1 || fail "'node' was not found on PATH. Install Node.js from https://nodejs.org/ or via your package manager, then re-run."

# Resolve the config path: normalize a supplied relative/absolute path via
# publish_common.sh, or fall back to the repo-root-then-project/configs/
# search already used elsewhere in this skill.
if [[ -n "${CONFIG_PATH_ARG}" ]]; then
  CONFIG_PATH="$(publish_normalize_path "${CONFIG_PATH_ARG}")"
elif [[ -f "${PUBLISH_REPO_ROOT}/publish.json" ]]; then
  CONFIG_PATH="${PUBLISH_REPO_ROOT}/publish.json"
elif [[ -f "${PUBLISH_DEFAULT_CONFIG_FILE}" ]]; then
  CONFIG_PATH="${PUBLISH_DEFAULT_CONFIG_FILE}"
else
  usage >&2
  fail "missing publish.json path argument, and no default config found at '${PUBLISH_REPO_ROOT}/publish.json' or '${PUBLISH_DEFAULT_CONFIG_FILE}'"
fi

[[ -f "${CONFIG_PATH}" ]] || fail "publish config not found at '${CONFIG_PATH}'"
jq -e . "${CONFIG_PATH}" >/dev/null 2>&1 || fail "publish config at '${CONFIG_PATH}' is not valid JSON"

# ---------------------------------------------------------------------------
# Check 1 — npm CLI version >= 11.15.0
# ---------------------------------------------------------------------------
NPM_VERSION_RAW="$(npm --version 2>/dev/null)"
NPM_VERSION="${NPM_VERSION_RAW#v}"
if [[ -z "${NPM_VERSION}" ]]; then
  fail "could not determine npm CLI version ('npm --version' produced no output)"
fi
if ! version_ge "${NPM_VERSION}" "${NPM_MIN_VERSION}"; then
  fail "npm CLI version ${NPM_VERSION} is below the minimum required for staged publishing (${NPM_MIN_VERSION}). Upgrade with 'npm install -g npm@latest' (or any npm >= ${NPM_MIN_VERSION}) and re-run."
fi

# ---------------------------------------------------------------------------
# Check 2 — Node version >= 22.14.0
# ---------------------------------------------------------------------------
NODE_VERSION_RAW="$(node --version 2>/dev/null)"
NODE_VERSION="${NODE_VERSION_RAW#v}"
if [[ -z "${NODE_VERSION}" ]]; then
  fail "could not determine Node.js version ('node --version' produced no output)"
fi
if ! version_ge "${NODE_VERSION}" "${NODE_MIN_VERSION}"; then
  fail "Node.js version ${NODE_VERSION} is below the minimum required for staged publishing (${NODE_MIN_VERSION}). Upgrade Node.js to ${NODE_MIN_VERSION} or newer (https://nodejs.org/) and re-run."
fi

# ---------------------------------------------------------------------------
# Check 3 — target exists and its type is `npm` or `npm-ci`
# ---------------------------------------------------------------------------
TARGET_JSON="$(jq -c --arg t "${TARGET_NAME}" '.targets[]? | select(.name == $t)' "${CONFIG_PATH}")"
if [[ -z "${TARGET_JSON}" ]]; then
  fail "target '${TARGET_NAME}' was not found in '${CONFIG_PATH}'"
fi

TARGET_TYPE="$(printf '%s' "${TARGET_JSON}" | jq -r '.type // empty')"
if [[ "${TARGET_TYPE}" != "npm" && "${TARGET_TYPE}" != "npm-ci" ]]; then
  if [[ -z "${TARGET_TYPE}" ]]; then
    fail "target '${TARGET_NAME}' is missing a type. Staging is only supported for target types 'npm' and 'npm-ci'."
  fi
  fail "target '${TARGET_NAME}' has type '${TARGET_TYPE}'. Staging is only supported for target types 'npm' and 'npm-ci' — use '/publish deploy' for other target types."
fi

# ---------------------------------------------------------------------------
# Check 4 — the package already exists on the registry
# ---------------------------------------------------------------------------
PACKAGE_NAME="$(printf '%s' "${TARGET_JSON}" | jq -r '.npm.package_name // empty')"
if [[ -z "${PACKAGE_NAME}" ]]; then
  fail "target '${TARGET_NAME}' is missing required field 'npm.package_name'"
fi

REGISTRY="$(printf '%s' "${TARGET_JSON}" | jq -r --arg d "${DEFAULT_REGISTRY}" '.npm.registry // $d')"

# Capture npm's output but never print it — it is not needed for the
# messages below, and not printing it is a hard guarantee against ever
# leaking anything npm's registry client writes (including, in principle,
# auth-related response detail) into this script's own stdout/stderr.
REGISTRY_PROBE_OUTPUT="$(npm view "${PACKAGE_NAME}" version --registry "${REGISTRY}" 2>&1)"
REGISTRY_PROBE_EXIT=$?

if [[ ${REGISTRY_PROBE_EXIT} -ne 0 ]]; then
  if printf '%s' "${REGISTRY_PROBE_OUTPUT}" | grep -qi 'E404\|404 Not Found\|is not in this registry'; then
    fail "package '${PACKAGE_NAME}' was not found on registry '${REGISTRY}' (404). npm cannot stage a package that has never been published — run '/publish deploy' for the first release; staging becomes available from the second release onward."
  fi
  fail "could not verify that package '${PACKAGE_NAME}' exists on registry '${REGISTRY}' (npm view exited ${REGISTRY_PROBE_EXIT}). Check network connectivity and registry configuration, then re-run."
fi

# ---------------------------------------------------------------------------
# All checks passed
# ---------------------------------------------------------------------------
printf '[validate] stage environment OK — npm %s, node %s, target "%s" (%s), package "%s" resolves on %s\n' \
  "${NPM_VERSION}" "${NODE_VERSION}" "${TARGET_NAME}" "${TARGET_TYPE}" "${PACKAGE_NAME}" "${REGISTRY}"
exit 0
