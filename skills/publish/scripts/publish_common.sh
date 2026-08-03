#!/usr/bin/env bash

if [[ -n "${PUBLISH_COMMON_SH_LOADED:-}" ]]; then
  return 0
fi
PUBLISH_COMMON_SH_LOADED=1

PUBLISH_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if PUBLISH_REPO_ROOT="$(git -C "$PUBLISH_SCRIPT_DIR" rev-parse --show-toplevel 2>/dev/null)"; then
  :
else
  PUBLISH_REPO_ROOT="$(cd "$PUBLISH_SCRIPT_DIR/../../.." && pwd)"
fi
PUBLISH_DEFAULT_HISTORY_FILE="$PUBLISH_REPO_ROOT/project/logs/publish-history.json"
PUBLISH_DEFAULT_CONFIG_FILE="$PUBLISH_REPO_ROOT/project/configs/publish.json"

publish_stat_mtime() {
  if [[ -e "$1" ]]; then
    stat -f %m "$1" 2>/dev/null || echo 0
  else
    echo 0
  fi
}

publish_acquire_lock() {
  local lock_path="$1"
  local attempt=0
  local now mtime

  while :; do
    if [[ -e "$lock_path" ]]; then
      now="$(date +%s)"
      mtime="$(publish_stat_mtime "$lock_path")"
      if (( now - mtime < 60 )); then
        if (( attempt >= 1 )); then
          return 1
        fi
        sleep 10
        attempt=$((attempt + 1))
        continue
      fi
      rm -f "$lock_path"
    fi

    if ( set -o noclobber; : > "$lock_path" ) 2>/dev/null; then
      return 0
    fi

    if (( attempt >= 1 )); then
      return 1
    fi
    sleep 10
    attempt=$((attempt + 1))
  done
}

publish_release_lock() {
  rm -f "$1"
}

publish_normalize_path() {
  local path="$1"
  if [[ -z "$path" ]]; then
    return 1
  fi
  if [[ "$path" = /* ]]; then
    printf '%s\n' "$path"
  else
    printf '%s/%s\n' "$PUBLISH_REPO_ROOT" "$path"
  fi
}

publish_resolve_history_file() {
  local config_path="${1:-}"
  local history_path="${PUBLISH_HISTORY_FILE:-}"

  if [[ -z "$history_path" && -n "$config_path" && -f "$config_path" ]] && command -v jq >/dev/null 2>&1; then
    history_path="$(jq -r '.defaults.history_file // empty' "$config_path" 2>/dev/null || true)"
  fi

  if [[ -z "$history_path" ]]; then
    history_path="$PUBLISH_DEFAULT_HISTORY_FILE"
    printf '%s\n' "$history_path"
    return 0
  fi

  publish_normalize_path "$history_path"
}

publish_ensure_history_file() {
  local history_file="$1"
  local lock_file="${history_file}.lock"
  local tmp_file="${history_file}.tmp.$$"

  mkdir -p "$(dirname "$history_file")"
  if ! publish_acquire_lock "$lock_file"; then
    echo "Could not acquire lock for $history_file" >&2
    return 1
  fi

  if [[ ! -f "$history_file" ]]; then
    printf '[]\n' > "$history_file"
  elif ! jq -e 'type == "array"' "$history_file" >/dev/null 2>&1; then
    publish_release_lock "$lock_file"
    rm -f "$tmp_file"
    echo "Publish history file must contain a JSON array: $history_file" >&2
    return 1
  fi

  publish_release_lock "$lock_file"
  return 0
}

publish_append_history_entry() {
  local history_file="$1"
  local entry_json="$2"
  local lock_file="${history_file}.lock"
  local tmp_file="${history_file}.tmp.$$"

  mkdir -p "$(dirname "$history_file")"
  if ! publish_acquire_lock "$lock_file"; then
    echo "Could not acquire lock for $history_file" >&2
    return 1
  fi

  if [[ ! -f "$history_file" ]]; then
    printf '[]\n' > "$history_file"
  fi

  if ! jq -e 'type == "array"' "$history_file" >/dev/null 2>&1; then
    publish_release_lock "$lock_file"
    rm -f "$tmp_file"
    echo "Publish history file must contain a JSON array: $history_file" >&2
    return 1
  fi

  if ! jq --argjson entry "$entry_json" '. + [$entry]' "$history_file" > "$tmp_file"; then
    publish_release_lock "$lock_file"
    rm -f "$tmp_file"
    echo "Failed to append publish history entry." >&2
    return 1
  fi

  mv "$tmp_file" "$history_file"
  publish_release_lock "$lock_file"
  return 0
}

publish_is_semver_tag() {
  [[ "$1" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]
}

publish_list_semver_tags() {
  local ref="${1:-HEAD}"
  git tag --merged "$ref" --list 'v*.*.*' --sort=-v:refname 2>/dev/null | while IFS= read -r tag; do
    [[ -z "$tag" ]] && continue
    if publish_is_semver_tag "$tag"; then
      printf '%s\n' "$tag"
    fi
  done
}

publish_history_has_version() {
  local history_file="$1"
  local version="$2"
  [[ -f "$history_file" ]] || return 1
  jq -e --arg version "$version" 'type == "array" and any(.[]?; (.version? // "") == $version)' "$history_file" >/dev/null 2>&1
}

publish_resolve_last_publish_tag() {
  local history_file="$1"
  local ref="${2:-HEAD}"
  local tag

  [[ -f "$history_file" ]] || return 1

  while IFS= read -r tag; do
    [[ -z "$tag" ]] && continue
    if publish_history_has_version "$history_file" "$tag"; then
      printf '%s\n' "$tag"
      return 0
    fi
  done < <(publish_list_semver_tags "$ref")

  return 1
}

publish_latest_ledger_version() {
  local history_file="$1"
  [[ -f "$history_file" ]] || return 1
  jq -r '[.[]? | .version? | strings | select(test("^v[0-9]+\\.[0-9]+\\.[0-9]+$"))] | last // empty' "$history_file"
}

publish_normalize_version() {
  local version="$1"
  if [[ "$version" != v* ]]; then
    version="v$version"
  fi
  publish_is_semver_tag "$version" || return 1
  printf '%s\n' "$version"
}

publish_bump_version() {
  local current_version="$1"
  local bump_level="$2"
  local major minor patch

  current_version="$(publish_normalize_version "$current_version")" || return 1
  IFS=. read -r major minor patch <<< "${current_version#v}"

  case "$bump_level" in
    major)
      major=$((major + 1))
      minor=0
      patch=0
      ;;
    minor)
      minor=$((minor + 1))
      patch=0
      ;;
    patch)
      patch=$((patch + 1))
      ;;
    *)
      return 1
      ;;
  esac

  printf 'v%s.%s.%s\n' "$major" "$minor" "$patch"
}

publish_current_actor() {
  local actor
  actor="$(git config user.name 2>/dev/null || true)"
  if [[ -n "$actor" ]]; then
    printf '%s\n' "$actor"
    return 0
  fi

  actor="${GITHUB_ACTOR:-${USER:-}}"
  if [[ -n "$actor" ]]; then
    printf '%s\n' "$actor"
    return 0
  fi

  printf 'CI\n'
}

publish_temp_release_notes_path() {
  local dir="$PUBLISH_REPO_ROOT/.claude/publish-tmp"
  mkdir -p "$dir"
  printf '%s/release-notes-%s.md\n' "$dir" "$(date -u +"%Y%m%dT%H%M%SZ")"
}
