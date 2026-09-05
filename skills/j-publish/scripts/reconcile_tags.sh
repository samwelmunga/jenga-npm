#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/publish_common.sh"

usage() {
  cat <<'USAGE'
Usage: reconcile_tags.sh [--dry-run] [--config <path>]
USAGE
}

DRY_RUN=0
CONFIG_PATH=''

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)
      DRY_RUN=1
      shift
      ;;
    --config)
      [[ $# -ge 2 ]] || { usage >&2; exit 1; }
      CONFIG_PATH="$2"
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

command -v jq >/dev/null 2>&1 || { echo 'jq is required.' >&2; exit 1; }
HISTORY_FILE="$(publish_resolve_history_file "$CONFIG_PATH")"
if (( DRY_RUN == 0 )); then
  publish_ensure_history_file "$HISTORY_FILE"
fi

TAGS=()
while IFS= read -r tag; do
  [[ -n "$tag" ]] && TAGS+=("$tag")
done < <(publish_list_semver_tags HEAD)

LEDGER_VERSIONS=()
if [[ -f "$HISTORY_FILE" ]]; then
  while IFS= read -r version; do
    [[ -n "$version" ]] && LEDGER_VERSIONS+=("$version")
  done < <(jq -r '.[]? | .version? | strings | select(test("^v[0-9]+\\.[0-9]+\\.[0-9]+$"))' "$HISTORY_FILE")
fi

contains_value() {
  local needle="$1"
  shift
  local value
  for value in "$@"; do
    [[ "$value" == "$needle" ]] && return 0
  done
  return 1
}

NEW_LEDGER_ENTRIES=0
NEW_GIT_TAGS=0

for tag in "${TAGS[@]:-}"; do
  [[ -n "$tag" ]] || continue
  if contains_value "$tag" "${LEDGER_VERSIONS[@]:-}"; then
    continue
  fi

  NEW_LEDGER_ENTRIES=$((NEW_LEDGER_ENTRIES + 1))
  if (( DRY_RUN )); then
    printf '⚠️  Tag %s found without ledger entry — would create partial entry\n' "$tag"
    continue
  fi

  TAG_TIMESTAMP="$(git for-each-ref --format='%(creatordate:iso8601-strict)' "refs/tags/$tag" | head -n 1)"
  [[ -n "$TAG_TIMESTAMP" ]] || TAG_TIMESTAMP="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
  TAG_ACTOR="$(git for-each-ref --format='%(taggername)' "refs/tags/$tag" | head -n 1)"
  [[ -n "$TAG_ACTOR" ]] || TAG_ACTOR='unknown'
  TAG_COMMIT="$(git rev-list -n 1 "$tag")"
  ENTRY_ID="$(uuidgen | tr '[:upper:]' '[:lower:]')"
  ENTRY_JSON="$(jq -cn \
    --arg id "$ENTRY_ID" \
    --arg version "$tag" \
    --arg target 'unknown' \
    --arg adapter 'manual' \
    --arg timestamp "$TAG_TIMESTAMP" \
    --arg released_by "$TAG_ACTOR" \
    --arg platform_state 'partial' \
    --arg git_tag "$tag" \
    --arg commit_sha "$TAG_COMMIT" \
    --arg note 'Manually tagged without /publish' \
    '{
      id: $id,
      version: $version,
      target: $target,
      adapter: $adapter,
      timestamp: $timestamp,
      released_by: $released_by,
      release_notes_path: null,
      platform_state: $platform_state,
      git_tag: $git_tag,
      commit_sha: $commit_sha,
      note: $note
    }')"
  publish_append_history_entry "$HISTORY_FILE" "$ENTRY_JSON"
  printf '⚠️  Tag %s found without ledger entry — created partial entry\n' "$tag"
done

if [[ -f "$HISTORY_FILE" ]]; then
  while IFS=$'\t' read -r version commit_sha; do
    [[ -n "$version" ]] || continue
    if contains_value "$version" "${TAGS[@]:-}"; then
      continue
    fi

    NEW_GIT_TAGS=$((NEW_GIT_TAGS + 1))
    TAG_COMMIT="${commit_sha:-$(git rev-parse HEAD)}"

    if (( DRY_RUN )); then
      printf '⚠️  Ledger entry %s had no git tag — would create retroactively\n' "$version"
      continue
    fi

    git tag -a "$version" "$TAG_COMMIT" -m 'Retroactive tag from /publish ledger'
    printf '⚠️  Ledger entry %s had no git tag — created retroactively\n' "$version"
  done < <(jq -r '.[]? | select(type == "object") | select((.version? // "") | test("^v[0-9]+\\.[0-9]+\\.[0-9]+$")) | [(.version // ""), (.commit_sha // "")] | @tsv' "$HISTORY_FILE")
fi

printf 'Reconciliation complete. %s new ledger entries, %s new git tags.\n' "$NEW_LEDGER_ENTRIES" "$NEW_GIT_TAGS"
