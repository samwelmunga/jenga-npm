#!/usr/bin/env bash
# extract-task-diff-stats.sh — Extract actual git diff stats for a single task
#
# Usage: extract-task-diff-stats.sh <task-id>
#
# Finds all commits whose message contains <task-id> (EST naming convention,
# e.g. E32_S06_T01), aggregates the file count and net line delta across all
# matched commits, and prints:
#
#   actual_files_changed: <N>
#   actual_lines_delta: <N>
#
# For bundle tasks (a single commit covers multiple task IDs), each task that
# matches the commit receives the full bundle stats — this is the "full credit"
# attribution model. See skills/close-story/SKILL.md for the rationale.
#
# Exit codes:
#   0 — success (even when no commits are found; outputs 0 values)
#   1 — missing or invalid argument

set -euo pipefail

# ---------------------------------------------------------------------------
# Argument validation
# ---------------------------------------------------------------------------

TASK_ID="${1:-}"

if [[ -z "$TASK_ID" ]]; then
  echo "Usage: $(basename "$0") <task-id>" >&2
  echo "  Example: $(basename "$0") E32_S06_T01" >&2
  exit 1
fi

# Validate EST format: E##_S##_T##
if [[ ! "$TASK_ID" =~ ^E[0-9]{2}_S[0-9]{2}_T[0-9]{2}$ ]]; then
  echo "ERROR: Invalid task ID format '$TASK_ID'. Expected E##_S##_T## (e.g. E32_S06_T01)" >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Find commits matching this task ID in the message
# ---------------------------------------------------------------------------

MATCHED_SHAS=$(git log --all --no-merges --grep="$TASK_ID" --pretty=format:"%H" 2>/dev/null || true)

if [[ -z "$MATCHED_SHAS" ]]; then
  # No commits found — task may predate EST tagging or use a non-standard message
  echo "actual_files_changed: 0"
  echo "actual_lines_delta: 0"
  exit 0
fi

# ---------------------------------------------------------------------------
# Aggregate diff stats across all matched commits
# ---------------------------------------------------------------------------

TOTAL_FILES=0
TOTAL_INSERTIONS=0
TOTAL_DELETIONS=0

while IFS= read -r sha; do
  [[ -z "$sha" ]] && continue

  # Get the diff stat summary line for this commit
  # git diff --stat <sha>~1..<sha> outputs individual file lines plus a summary:
  #   N files changed, M insertions(+), K deletions(-)
  # We only need the last (summary) line.
  STAT_OUTPUT=$(git diff --stat "${sha}~1..${sha}" 2>/dev/null || true)

  if [[ -z "$STAT_OUTPUT" ]]; then
    # Commit with no parent (initial commit) or empty diff — skip
    continue
  fi

  # Parse files changed from the summary line
  # The summary line contains "N file(s) changed"
  FILES_THIS=$(echo "$STAT_OUTPUT" | (grep -o '[0-9][0-9]* file' || true) | awk '{sum+=$1} END {print sum+0}')
  # Parse insertions
  INS_THIS=$(echo "$STAT_OUTPUT" | (grep -o '[0-9][0-9]* insertion' || true) | awk '{sum+=$1} END {print sum+0}')
  # Parse deletions
  DEL_THIS=$(echo "$STAT_OUTPUT" | (grep -o '[0-9][0-9]* deletion' || true) | awk '{sum+=$1} END {print sum+0}')

  TOTAL_FILES=$((TOTAL_FILES + FILES_THIS))
  TOTAL_INSERTIONS=$((TOTAL_INSERTIONS + INS_THIS))
  TOTAL_DELETIONS=$((TOTAL_DELETIONS + DEL_THIS))

done <<< "$MATCHED_SHAS"

TOTAL_DELTA=$((TOTAL_INSERTIONS + TOTAL_DELETIONS))

# ---------------------------------------------------------------------------
# Output structured results
# ---------------------------------------------------------------------------

echo "actual_files_changed: $TOTAL_FILES"
echo "actual_lines_delta: $TOTAL_DELTA"
