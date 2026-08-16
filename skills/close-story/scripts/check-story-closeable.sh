#!/usr/bin/env bash
# check-story-closeable.sh — Last-task detection guard for /close-story
#
# Usage: bash check-story-closeable.sh <story-id>
#
# Exits 0 and prints "CLOSEABLE" to stdout when all tasks in the story's
# `tasks:` frontmatter list have status Passed or Done.
# Exits 1 and prints a descriptive message to stderr for any other outcome.
#
# This script always re-reads task files from disk — never uses cached state.

set -euo pipefail

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

usage() {
  echo "Usage: $(basename "$0") <story-id>" >&2
  echo "  Example: $(basename "$0") E17_S06" >&2
  exit 1
}

# Locate the project root relative to this script's location.
# Script lives at: skills/close-story/scripts/check-story-closeable.sh
# Project root is three levels up (skills/ → repo root).
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
STORIES_DIR="$PROJECT_ROOT/project/board/stories"
TASKS_DIR="$PROJECT_ROOT/project/board/tasks"

# ---------------------------------------------------------------------------
# Argument validation
# ---------------------------------------------------------------------------

if [[ $# -ne 1 ]]; then
  usage
fi

STORY_ID="$1"

# Basic sanity check on the story ID format (E##_S##)
if [[ ! "$STORY_ID" =~ ^E[0-9]{2}_S[0-9]{2}$ ]]; then
  echo "ERROR: Invalid story ID format '$STORY_ID'. Expected format: E##_S## (e.g. E17_S06)" >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Step 1: Locate story file
# ---------------------------------------------------------------------------

# Use a glob — story slug may vary, so match on ID prefix only.
story_file=""
while IFS= read -r -d '' candidate; do
  story_file="$candidate"
  break
done < <(find "$STORIES_DIR" -maxdepth 1 -name "${STORY_ID}_*.md" -print0 2>/dev/null)

if [[ -z "$story_file" ]]; then
  echo "ERROR: Story file not found for '$STORY_ID' in $STORIES_DIR" >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Step 2: Extract tasks: list from story frontmatter
# ---------------------------------------------------------------------------
# Frontmatter is the YAML block between the first pair of --- delimiters.
# The tasks: field is a YAML list of task IDs, e.g.:
#   tasks:
#     - E17_S06_T01
#     - E17_S06_T02

extract_tasks() {
  local file="$1"
  local in_frontmatter=0
  local in_tasks=0
  local found_any=0

  while IFS= read -r line; do
    # Detect frontmatter boundaries
    if [[ "$line" == "---" ]]; then
      if [[ $in_frontmatter -eq 0 ]]; then
        in_frontmatter=1
        continue
      else
        # Closing --- ends the frontmatter block
        break
      fi
    fi

    # Only process lines inside frontmatter
    if [[ $in_frontmatter -eq 0 ]]; then
      continue
    fi

    # Detect the start of the tasks: key
    if [[ "$line" =~ ^tasks:[[:space:]]*$ ]]; then
      in_tasks=1
      continue
    fi

    # If we are collecting tasks, look for list items
    if [[ $in_tasks -eq 1 ]]; then
      # A list item starts with optional whitespace then "- "
      if [[ "$line" =~ ^[[:space:]]*-[[:space:]]+([A-Za-z0-9_]+) ]]; then
        echo "${BASH_REMATCH[1]}"
        found_any=1
      elif [[ "$line" =~ ^[^[:space:]] ]]; then
        # A non-indented, non-list line means we've left the tasks block
        break
      fi
    fi
  done < "$file"
}

mapfile -t TASK_IDS < <(extract_tasks "$story_file")

# ---------------------------------------------------------------------------
# Step 3: Validate tasks: list is present and non-empty
# ---------------------------------------------------------------------------

if [[ ${#TASK_IDS[@]} -eq 0 ]]; then
  echo "ERROR: No tasks found in story frontmatter for '$STORY_ID' — cannot determine close state" >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Step 4: Check each task's status
# ---------------------------------------------------------------------------

all_closeable=1

for task_id in "${TASK_IDS[@]}"; do
  # 4a. Locate the task file (always re-read from disk)
  task_file=""
  while IFS= read -r -d '' candidate; do
    task_file="$candidate"
    break
  done < <(find "$TASKS_DIR" -maxdepth 1 -name "${task_id}_*.md" -print0 2>/dev/null)

  if [[ -z "$task_file" ]]; then
    echo "ERROR: Task file not found for '$task_id' — treating as open" >&2
    all_closeable=0
    continue
  fi

  # 4b/4c. Extract status: field from the task's frontmatter
  task_status=""
  in_fm=0
  while IFS= read -r line; do
    if [[ "$line" == "---" ]]; then
      if [[ $in_fm -eq 0 ]]; then
        in_fm=1
        continue
      else
        break
      fi
    fi
    if [[ $in_fm -eq 1 && "$line" =~ ^status:[[:space:]]*(.+)$ ]]; then
      task_status="${BASH_REMATCH[1]}"
      # Trim surrounding quotes if present
      task_status="${task_status%\"}"
      task_status="${task_status#\"}"
      task_status="${task_status%\'}"
      task_status="${task_status#\'}"
      break
    fi
  done < "$task_file"

  # 4d. Evaluate status
  case "$task_status" in
    Passed|Done)
      # Task is in a terminal state — OK
      ;;
    "")
      echo "OPEN: '$task_id' has no status field — treating as open" >&2
      all_closeable=0
      ;;
    *)
      echo "OPEN: '$task_id' has status '$task_status'" >&2
      all_closeable=0
      ;;
  esac
done

# ---------------------------------------------------------------------------
# Step 5: Report result
# ---------------------------------------------------------------------------

if [[ $all_closeable -eq 1 ]]; then
  echo "CLOSEABLE"
  exit 0
else
  exit 1
fi
