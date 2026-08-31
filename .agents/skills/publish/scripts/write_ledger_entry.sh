#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/publish_common.sh"

usage() {
  cat <<'USAGE'
Usage: write_ledger_entry.sh <target> <adapter> <platform_state> <notes_path> [--yes] [--dry-run] [--version <vX.Y.Z>] [--config <path>] [--stage-id <id>] [--dist-tag <tag>] [--result <pass|fail>] [--reason <text>]

platform_state must be one of: uploaded, partial, dry-run, failed, staged,
stage_tested, approved, rejected.

--result <pass|fail>  Optional. Records a stage_tested smoke-test outcome on
                       the entry (null when omitted). The npm_stage_inspect.sh
                       approve interlock reads this field.
--reason <text>        Optional. Records a free-text reason on the entry —
                       used by npm_stage_inspect.sh's `approve --force
                       <reason>` to record why the test interlock was
                       overridden (null when omitted).
USAGE
}

# Full accepted platform_state vocabulary: the three pre-existing states
# actually written by publish_deploy.sh/reconcile_tags.sh today (uploaded,
# partial, dry-run) plus `failed`, documented as part of the original
# ledger-entry format (E22_S05_T02) though not currently emitted by any
# caller, plus the four staged-publishing states added by E22_S09_T02.
ALLOWED_PLATFORM_STATES=(uploaded partial dry-run failed staged stage_tested approved rejected)

platform_state_is_valid() {
  local state="$1" allowed
  for allowed in "${ALLOWED_PLATFORM_STATES[@]}"; do
    [[ "$state" == "$allowed" ]] && return 0
  done
  return 1
}

[[ $# -ge 4 ]] || { usage >&2; exit 1; }
TARGET_NAME="$1"
ADAPTER_NAME="$2"
PLATFORM_STATE="$3"
NOTES_PATH_RAW="$4"
shift 4

AUTO_ACCEPT=0
DRY_RUN=0
SELECTED_VERSION=''
CONFIG_PATH="${PUBLISH_CONFIG:-}"
STAGE_ID=''
DIST_TAG=''
RESULT=''
REASON=''

while [[ $# -gt 0 ]]; do
  case "$1" in
    --yes)
      AUTO_ACCEPT=1
      shift
      ;;
    --dry-run)
      DRY_RUN=1
      shift
      ;;
    --version)
      [[ $# -ge 2 ]] || { usage >&2; exit 1; }
      SELECTED_VERSION="$2"
      shift 2
      ;;
    --config)
      [[ $# -ge 2 ]] || { usage >&2; exit 1; }
      CONFIG_PATH="$2"
      shift 2
      ;;
    --stage-id)
      [[ $# -ge 2 ]] || { usage >&2; exit 1; }
      STAGE_ID="$2"
      shift 2
      ;;
    --dist-tag)
      [[ $# -ge 2 ]] || { usage >&2; exit 1; }
      DIST_TAG="$2"
      shift 2
      ;;
    --result)
      [[ $# -ge 2 ]] || { usage >&2; exit 1; }
      RESULT="$2"
      shift 2
      ;;
    --reason)
      [[ $# -ge 2 ]] || { usage >&2; exit 1; }
      REASON="$2"
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

[[ -n "$TARGET_NAME" && -n "$ADAPTER_NAME" && -n "$PLATFORM_STATE" ]] || { usage >&2; exit 1; }
if ! platform_state_is_valid "$PLATFORM_STATE"; then
  printf "Unknown platform_state '%s'. Expected one of: %s.\n" "$PLATFORM_STATE" "${ALLOWED_PLATFORM_STATES[*]}" >&2
  exit 1
fi
if [[ -n "$RESULT" && "$RESULT" != "pass" && "$RESULT" != "fail" ]]; then
  printf "Unknown --result '%s'. Expected 'pass' or 'fail'.\n" "$RESULT" >&2
  exit 1
fi
command -v jq >/dev/null 2>&1 || { echo 'jq is required.' >&2; exit 1; }

HISTORY_FILE="$(publish_resolve_history_file "$CONFIG_PATH")"
publish_ensure_history_file "$HISTORY_FILE"

if [[ -n "$SELECTED_VERSION" ]]; then
  VERSION="$SELECTED_VERSION"
else
  SUGGEST_CMD=(bash "$SCRIPT_DIR/suggest_semver_bump.sh")
  if (( AUTO_ACCEPT )); then
    SUGGEST_CMD+=(--yes)
  fi
  if [[ -n "$CONFIG_PATH" ]]; then
    SUGGEST_CMD+=("$CONFIG_PATH")
  fi
  VERSION_OUTPUT="$("${SUGGEST_CMD[@]}")"
  printf '%s\n' "$VERSION_OUTPUT"
  VERSION="$(printf '%s\n' "$VERSION_OUTPUT" | tail -n 1 | tr -d '\r')"
fi
VERSION="$(publish_normalize_version "$VERSION")" || {
  echo "Unable to resolve a valid version from suggest_semver_bump.sh output." >&2
  exit 1
}

GIT_TAG="$VERSION"
if (( DRY_RUN )); then
  printf '[DRY RUN] Would create tag %s\n' "$GIT_TAG"
elif git rev-parse "$GIT_TAG" >/dev/null 2>&1; then
  printf '⚠️  Git tag %s already exists — skipping tag creation\n' "$GIT_TAG" >&2
else
  git tag -a "$GIT_TAG" -m "Release $GIT_TAG — deployed to $TARGET_NAME"
fi

TIMESTAMP="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
RELEASED_BY="$(publish_current_actor)"
COMMIT_SHA="$(git rev-parse HEAD)"
ENTRY_ID="$(uuidgen | tr '[:upper:]' '[:lower:]')"

if [[ -z "$NOTES_PATH_RAW" || "$NOTES_PATH_RAW" == 'null' ]]; then
  NOTES_JSON='null'
else
  NOTES_JSON="$(jq -Rn --arg path "$NOTES_PATH_RAW" '$path')"
fi

if [[ -z "$STAGE_ID" ]]; then
  STAGE_ID_JSON='null'
else
  STAGE_ID_JSON="$(jq -Rn --arg id "$STAGE_ID" '$id')"
fi

if [[ -z "$DIST_TAG" ]]; then
  DIST_TAG_JSON='null'
else
  DIST_TAG_JSON="$(jq -Rn --arg tag "$DIST_TAG" '$tag')"
fi

if [[ -z "$RESULT" ]]; then
  RESULT_JSON='null'
else
  RESULT_JSON="$(jq -Rn --arg result "$RESULT" '$result')"
fi

if [[ -z "$REASON" ]]; then
  REASON_JSON='null'
else
  REASON_JSON="$(jq -Rn --arg reason "$REASON" '$reason')"
fi

ENTRY_JSON="$(jq -cn \
  --arg id "$ENTRY_ID" \
  --arg version "$VERSION" \
  --arg target "$TARGET_NAME" \
  --arg adapter "$ADAPTER_NAME" \
  --arg timestamp "$TIMESTAMP" \
  --arg released_by "$RELEASED_BY" \
  --arg platform_state "$PLATFORM_STATE" \
  --arg git_tag "$GIT_TAG" \
  --arg commit_sha "$COMMIT_SHA" \
  --argjson release_notes_path "$NOTES_JSON" \
  --argjson stage_id "$STAGE_ID_JSON" \
  --argjson dist_tag "$DIST_TAG_JSON" \
  --argjson result "$RESULT_JSON" \
  --argjson reason "$REASON_JSON" \
  '{
    id: $id,
    version: $version,
    target: $target,
    adapter: $adapter,
    timestamp: $timestamp,
    released_by: $released_by,
    release_notes_path: $release_notes_path,
    platform_state: $platform_state,
    git_tag: $git_tag,
    commit_sha: $commit_sha,
    stage_id: $stage_id,
    dist_tag: $dist_tag,
    result: $result,
    reason: $reason
  }')"

publish_append_history_entry "$HISTORY_FILE" "$ENTRY_JSON"
printf '🧾 Publish ledger entry appended for %s\n' "$VERSION"
