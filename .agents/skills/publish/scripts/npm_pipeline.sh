#!/usr/bin/env bash
# npm_pipeline.sh — Execute the npm publish pipeline for the JengaAgent repo.
#
# Runs from the JengaAgent repo root (where package.json lives) and invokes
# `npm publish --tag <dist_tag>` (or `--dry-run` when requested).
#
# Exit codes:
#   0  success (live publish or dry-run completed)
#   2  pre-publish gate failure (missing package.json, missing npm/node, bad args)
#   3  publish error (`npm publish` returned non-zero)
#
# Style and conventions mirror `ios_pipeline.sh`.

set -euo pipefail

EXIT_PRE_PUBLISH_FAILURE=2
EXIT_PUBLISH_FAILURE=3

usage() {
  cat <<'USAGE'
Usage: npm_pipeline.sh [<target> <publish_json_path>] [--dry-run] [--dist-tag <tag>] [--non-interactive]

Options:
  <target>              Optional target name from publish.json (npm target).
  <publish_json_path>   Optional path to publish.json for reading defaults.
  --dry-run             Run `npm publish --dry-run`; do not touch the registry.
  --dist-tag <tag>      Override dist-tag. Falls back to $NPM_DIST_TAG, then
                        to the target's `npm.dist_tag`, then to "latest".
  --non-interactive     Reserved flag for CI; no interactive prompts today.
  -h, --help            Show this message.
USAGE
}

log_info() {
  printf '→ %s\n' "$1"
}

log_warn() {
  printf '⚠ %s\n' "$1" >&2
}

fail_pre_publish() {
  printf 'npm pipeline pre-publish failure: %s\n' "$1" >&2
  exit "$EXIT_PRE_PUBLISH_FAILURE"
}

fail_publish() {
  printf 'npm pipeline publish failure: %s\n' "$1" >&2
  exit "$EXIT_PUBLISH_FAILURE"
}

TARGET_NAME=""
PUBLISH_JSON=""
DRY_RUN=0
NON_INTERACTIVE=0
DIST_TAG_ARG=""

# Peel off optional positional args before flag parsing so callers may pass
# `<target> <publish_json_path>` in either order relative to flags.
POSITIONAL=()
while (($#)); do
  case "$1" in
    -h|--help)
      usage
      exit 0
      ;;
    --dry-run)
      DRY_RUN=1
      shift
      ;;
    --non-interactive)
      NON_INTERACTIVE=1
      shift
      ;;
    --dist-tag)
      [[ $# -ge 2 ]] || fail_pre_publish "--dist-tag requires a value"
      DIST_TAG_ARG="$2"
      shift 2
      ;;
    --dist-tag=*)
      DIST_TAG_ARG="${1#*=}"
      shift
      ;;
    --)
      shift
      while (($#)); do
        POSITIONAL+=("$1")
        shift
      done
      ;;
    -*)
      usage >&2
      fail_pre_publish "unknown option: $1"
      ;;
    *)
      POSITIONAL+=("$1")
      shift
      ;;
  esac
done

if [[ ${#POSITIONAL[@]} -ge 1 ]]; then
  TARGET_NAME="${POSITIONAL[0]}"
fi
if [[ ${#POSITIONAL[@]} -ge 2 ]]; then
  PUBLISH_JSON="${POSITIONAL[1]}"
fi
if [[ ${#POSITIONAL[@]} -gt 2 ]]; then
  usage >&2
  fail_pre_publish "unexpected extra positional arguments"
fi

# Silence unused warnings; these are contract flags for the adapter layer.
: "${TARGET_NAME:=}"
: "${NON_INTERACTIVE:=0}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel 2>/dev/null)"; then
  :
else
  REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
fi

VALIDATE_ENV_SCRIPT="$SCRIPT_DIR/validate_npm_env.sh"

command -v npm >/dev/null 2>&1 || fail_pre_publish "npm is required on PATH"

PACKAGE_JSON="$REPO_ROOT/package.json"
[[ -f "$PACKAGE_JSON" ]] || fail_pre_publish "package.json not found at '$PACKAGE_JSON'"

# Read a JSON string field. Prefers jq, falls back to node.
read_json_string() {
  local file="$1"
  local path="$2"
  local value=""
  if command -v jq >/dev/null 2>&1; then
    value="$(jq -r "$path // \"\"" "$file" 2>/dev/null || true)"
  elif command -v node >/dev/null 2>&1; then
    # Convert a jq-style dot path (e.g. ".npm.dist_tag") to a JS accessor.
    local js_path="${path#.}"
    value="$(node -e "
      try {
        const data = require('$file');
        const parts = '$js_path'.split('.').filter(Boolean);
        let v = data;
        for (const p of parts) { v = v == null ? undefined : v[p]; }
        process.stdout.write(v == null ? '' : String(v));
      } catch (e) { process.stdout.write(''); }
    " 2>/dev/null || true)"
  fi
  printf '%s' "$value"
}

PACKAGE_NAME="$(read_json_string "$PACKAGE_JSON" '.name')"
PACKAGE_VERSION="$(read_json_string "$PACKAGE_JSON" '.version')"
[[ -n "$PACKAGE_NAME" ]] || fail_pre_publish "package.json is missing a 'name' field"
[[ -n "$PACKAGE_VERSION" ]] || fail_pre_publish "package.json is missing a 'version' field"

# Pull defaults from publish.json when both target + config are supplied.
CONFIG_DIST_TAG=""
CONFIG_REGISTRY=""
CONFIG_ACCESS=""
if [[ -n "$TARGET_NAME" && -n "$PUBLISH_JSON" ]]; then
  [[ -f "$PUBLISH_JSON" ]] || fail_pre_publish "publish config not found at '$PUBLISH_JSON'"
  command -v jq >/dev/null 2>&1 || fail_pre_publish "jq is required when passing a publish.json path"

  TARGET_JSON="$(jq -c --arg target "$TARGET_NAME" \
    '.targets[]? | select(.name == $target and .type == "npm")' \
    "$PUBLISH_JSON")"
  [[ -n "$TARGET_JSON" ]] \
    || fail_pre_publish "npm target '$TARGET_NAME' was not found in '$PUBLISH_JSON'"

  CONFIG_DIST_TAG="$(printf '%s' "$TARGET_JSON" | jq -r '.npm.dist_tag // ""')"
  CONFIG_REGISTRY="$(printf '%s' "$TARGET_JSON" | jq -r '.npm.registry // ""')"
  CONFIG_ACCESS="$(printf '%s' "$TARGET_JSON" | jq -r '.npm.access // ""')"

  if [[ -f "$VALIDATE_ENV_SCRIPT" ]]; then
    if ! bash "$VALIDATE_ENV_SCRIPT" "$PUBLISH_JSON" "$TARGET_NAME"; then
      fail_pre_publish "environment validation via validate_npm_env.sh failed"
    fi
  else
    log_warn "validate_npm_env.sh not found; skipping env pre-check"
  fi
fi

# Resolve dist-tag with precedence: flag > env > config > default.
DIST_TAG=""
if [[ -n "$DIST_TAG_ARG" ]]; then
  DIST_TAG="$DIST_TAG_ARG"
elif [[ -n "${NPM_DIST_TAG:-}" ]]; then
  DIST_TAG="$NPM_DIST_TAG"
elif [[ -n "$CONFIG_DIST_TAG" ]]; then
  DIST_TAG="$CONFIG_DIST_TAG"
else
  DIST_TAG="latest"
fi

# Resolve registry: config value wins; otherwise npm's default.
if [[ -n "$CONFIG_REGISTRY" ]]; then
  REGISTRY="$CONFIG_REGISTRY"
else
  REGISTRY="https://registry.npmjs.org/"
fi

MODE_LABEL="live publish"
if (( DRY_RUN )); then
  MODE_LABEL="dry-run"
fi

echo "========== NPM PUBLISH PIPELINE =========="
printf 'Package:  %s\n' "$PACKAGE_NAME"
printf 'Version:  %s\n' "$PACKAGE_VERSION"
printf 'Dist tag: %s\n' "$DIST_TAG"
printf 'Registry: %s\n' "$REGISTRY"
if [[ -n "$CONFIG_ACCESS" ]]; then
  printf 'Access:   %s\n' "$CONFIG_ACCESS"
fi
printf 'Mode:     %s\n' "$MODE_LABEL"
printf 'Repo:     %s\n' "$REPO_ROOT"
echo "=========================================="

PUBLISH_CMD=(npm publish --tag "$DIST_TAG")
if [[ -n "$CONFIG_ACCESS" ]]; then
  PUBLISH_CMD+=(--access "$CONFIG_ACCESS")
fi
if [[ -n "$CONFIG_REGISTRY" ]]; then
  PUBLISH_CMD+=(--registry "$CONFIG_REGISTRY")
fi

cd "$REPO_ROOT"

if (( DRY_RUN )); then
  echo "DRY RUN — nothing was published"
  PUBLISH_CMD+=(--dry-run)
  log_info "Running: ${PUBLISH_CMD[*]}"
  if "${PUBLISH_CMD[@]}"; then
    log_info "Dry-run completed successfully."
    exit 0
  fi
  fail_publish "npm publish --dry-run exited non-zero"
fi

log_info "Running: ${PUBLISH_CMD[*]}"
if "${PUBLISH_CMD[@]}"; then
  log_info "Published $PACKAGE_NAME@$PACKAGE_VERSION to $REGISTRY (dist-tag: $DIST_TAG)"
  exit 0
fi

fail_publish "npm publish exited non-zero"
