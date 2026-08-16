#!/usr/bin/env bash
set -euo pipefail

STORY_ID="${1:-}"
DATE_STARTED="${2:-}"
DATE_COMPLETED="${3:-}"

if [[ -z "$STORY_ID" ]]; then
  echo "Usage: extract-diff-stats.sh <story-id> [<date_started> <date_completed>]" >&2
  exit 1
fi

# Primary query — EST pattern match
# Collect all --stat output for commits matching the story ID pattern
STAT_OUTPUT=$(git log --all --stat --no-merges --grep="$STORY_ID" --pretty=format:"COMMIT:%H %s" 2>/dev/null || true)

# Parse insertions and deletions from --stat lines
# --stat lines look like: " 3 files changed, 45 insertions(+), 12 deletions(-)"
# Using portable grep (BSD and GNU compatible) instead of grep -oP
DIFF_ADDED=$(echo "$STAT_OUTPUT" | (grep -o '[0-9]* insertion' || true) | awk '{sum+=$1} END {print sum+0}')
DIFF_REMOVED=$(echo "$STAT_OUTPUT" | (grep -o '[0-9]* deletion' || true) | awk '{sum+=$1} END {print sum+0}')
COMMITS_MATCHED=$(git log --all --no-merges --grep="$STORY_ID" --pretty=format:"%H" 2>/dev/null | wc -l | tr -d ' ')

# Secondary query — date-window unmatched count
if [[ -n "$DATE_STARTED" && -n "$DATE_COMPLETED" ]]; then
  ALL_IN_WINDOW=$(git log --all --no-merges \
    --since="$DATE_STARTED" \
    --until="${DATE_COMPLETED}T23:59:59" \
    --pretty=format:"%H" 2>/dev/null || true)

  MATCHED_HASHES=$(git log --all --no-merges --grep="$STORY_ID" --pretty=format:"%H" 2>/dev/null || true)

  COMMITS_UNMATCHED=0
  while IFS= read -r hash; do
    [[ -z "$hash" ]] && continue
    if ! echo "$MATCHED_HASHES" | grep -q "^$hash$"; then
      COMMITS_UNMATCHED=$((COMMITS_UNMATCHED + 1))
    fi
  done <<< "$ALL_IN_WINDOW"
else
  COMMITS_UNMATCHED="unknown"
fi

# Output structured results
echo "diff_added: $DIFF_ADDED"
echo "diff_removed: $DIFF_REMOVED"
echo "commits_matched: $COMMITS_MATCHED"
echo "commits_unmatched_in_window: $COMMITS_UNMATCHED"
