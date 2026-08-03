#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/publish_common.sh"

usage() {
  cat <<'USAGE'
Usage: generate_release_notes.sh [--target <name>] [--from-tag <tag>] [--to-ref <git-ref>] [--output <path>] [<publish_json_path>]
USAGE
}

TARGET_NAME=""
FROM_TAG=""
TO_REF="HEAD"
OUTPUT_PATH=""
CONFIG_PATH=""
POSITIONAL_COUNT=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --target)
      [[ $# -ge 2 ]] || { usage >&2; exit 1; }
      TARGET_NAME="$2"
      shift 2
      ;;
    --from-tag)
      [[ $# -ge 2 ]] || { usage >&2; exit 1; }
      FROM_TAG="$2"
      shift 2
      ;;
    --to-ref)
      [[ $# -ge 2 ]] || { usage >&2; exit 1; }
      TO_REF="$2"
      shift 2
      ;;
    --output)
      [[ $# -ge 2 ]] || { usage >&2; exit 1; }
      OUTPUT_PATH="$2"
      shift 2
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    --*)
      usage >&2
      exit 1
      ;;
    *)
      POSITIONAL_COUNT=$((POSITIONAL_COUNT + 1))
      if (( POSITIONAL_COUNT > 1 )); then
        usage >&2
        exit 1
      fi
      CONFIG_PATH="$1"
      shift
      ;;
  esac
done

command -v jq >/dev/null 2>&1 || { echo 'jq is required.' >&2; exit 1; }

git rev-parse --verify "$TO_REF" >/dev/null 2>&1 || {
  echo "Unknown git ref: $TO_REF" >&2
  exit 1
}

HISTORY_FILE="$(publish_resolve_history_file "$CONFIG_PATH")"
LAST_TAG="$FROM_TAG"
FIRST_RELEASE=0
CUTOFF_DATE=""

if [[ -z "$LAST_TAG" ]]; then
  if LAST_TAG="$(publish_resolve_last_publish_tag "$HISTORY_FILE" "$TO_REF" 2>/dev/null || true)" && [[ -n "$LAST_TAG" ]]; then
    :
  else
    LAST_TAG=""
    FIRST_RELEASE=1
  fi
fi

if [[ -n "$LAST_TAG" ]]; then
  git rev-parse --verify "$LAST_TAG" >/dev/null 2>&1 || {
    echo "Unknown git tag: $LAST_TAG" >&2
    exit 1
  }
  CUTOFF_DATE="$(git log -1 --format=%cI "$LAST_TAG" 2>/dev/null | cut -dT -f1)"
fi

FEATURES=()
BUG_FIXES=()
OTHER=()

if [[ -n "$LAST_TAG" ]]; then
  LOG_RANGE=("$LAST_TAG..$TO_REF")
else
  LOG_RANGE=("$TO_REF")
fi

while IFS=$'\t' read -r subject short_sha || [[ -n "${subject:-}${short_sha:-}" ]]; do
  [[ -z "${subject:-}" ]] && continue
  line="- $subject ($short_sha)"
  if printf '%s\n' "$subject" | grep -Eq '^feat(\([^)]+\))?!?: '; then
    FEATURES+=("$line")
  elif printf '%s\n' "$subject" | grep -Eq '^fix(\([^)]+\))?!?: '; then
    BUG_FIXES+=("$line")
  else
    OTHER+=("$line")
  fi
done < <(git log "${LOG_RANGE[@]}" --pretty=format:'%s%x09%h')

collect_completed_tasks() {
  local cutoff_date="$1"
  local tasks_dir="$PUBLISH_REPO_ROOT/project/board/tasks"
  local collected=()
  local task_file status completed_date task_id task_title

  [[ -d "$tasks_dir" ]] || return 0

  while IFS= read -r -d '' task_file; do
    case "$task_file" in
      *_INSTRUCTIONS.md) continue ;;
    esac

    status="$(awk '/^status: /{sub(/^status: /, ""); print; exit}' "$task_file" 2>/dev/null || true)"
    [[ "$status" == "Passed" ]] || continue

    completed_date="$(awk '/^date_completed: /{sub(/^date_completed: /, ""); print; exit}' "$task_file" 2>/dev/null || true)"
    [[ -n "$completed_date" ]] || continue

    if [[ -n "$cutoff_date" && "$completed_date" < "$cutoff_date" ]]; then
      continue
    fi

    task_id="$(awk '/^id: /{sub(/^id: /, ""); print; exit}' "$task_file" 2>/dev/null || true)"
    task_title="$(awk '/^title: /{sub(/^title: /, ""); print; exit}' "$task_file" 2>/dev/null || true)"
    [[ -n "$task_id" ]] || continue
    [[ -n "$task_title" ]] || task_title="$task_id"
    collected+=("- $task_id — $task_title")
  done < <(find "$tasks_dir" -maxdepth 1 -type f -name '*.md' -print0 2>/dev/null)

  if (( ${#collected[@]} > 0 )); then
    printf '%s\n' "${collected[@]}" | LC_ALL=C sort -u
  fi
}

if [[ -z "$OUTPUT_PATH" ]]; then
  OUTPUT_PATH="$(publish_temp_release_notes_path)"
fi
mkdir -p "$(dirname "$OUTPUT_PATH")"

write_section() {
  local heading="$1"
  local array_name="$2"
  local item_count

  eval "item_count=\${#${array_name}[@]}"
  {
    printf '### %s\n' "$heading"
    if (( item_count > 0 )); then
      eval "printf '%s\\n' \"\${${array_name}[@]}\""
    else
      printf -- '- None\n'
    fi
    printf '\n'
  } >> "$OUTPUT_PATH"
}

GENERATED_AT="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
{
  printf '# Release notes\n\n'
  printf -- '- Generated: %s\n' "$GENERATED_AT"
  if [[ -n "$TARGET_NAME" ]]; then
    printf -- '- Target: %s\n' "$TARGET_NAME"
  fi
  if [[ -n "$LAST_TAG" ]]; then
    printf -- '- Changes: %s..%s\n\n' "$LAST_TAG" "$TO_REF"
  else
    printf -- '- Changes: full history through %s\n\n' "$TO_REF"
    if (( FIRST_RELEASE )); then
      printf '> First release — full history included\n\n'
    fi
  fi
} > "$OUTPUT_PATH"

write_section 'Features' FEATURES
write_section 'Bug Fixes' BUG_FIXES
write_section 'Other' OTHER

COMPLETED_TASKS="$(collect_completed_tasks "$CUTOFF_DATE" || true)"
if [[ -n "$COMPLETED_TASKS" ]]; then
  {
    printf '### Completed tasks\n'
    printf '%s\n' "$COMPLETED_TASKS"
    printf '\n'
  } >> "$OUTPUT_PATH"
fi

printf '📝 Release notes draft written to %s\n' "$OUTPUT_PATH"
