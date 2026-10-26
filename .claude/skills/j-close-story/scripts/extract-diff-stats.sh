#!/usr/bin/env bash
# extract-diff-stats.sh — Story-level aggregate diff stats
#
# Usage: extract-diff-stats.sh <story-id> [<date_started> <date_completed>]
#
# Prints:
#   diff_added: <N>
#   diff_removed: <N>
#   commits_matched: <N>
#   commits_unmatched_in_window: <N|unknown>
#
# "Matched" means the commits that belong to the story: the commits that name the story id itself plus the commits
# of each of its tasks, all resolved through the shared resolver scripts/commits-for-item.sh (E79_S02_T04). The
# resolver is anchored (a story query returns only commits that name the story), whereas this script's old
# message search was an unanchored substring match that picked up the child tasks' commits as a side effect.
# The task ids are therefore resolved explicitly: the story file's `tasks:` list plus every <story-id>_T*.md
# under project/board/tasks/ (including tasks/_superseded/), de-duplicated. A commit that names a task id for
# which no board file exists is no longer counted (it was before); see the E79_S02_T04 summary.

set -euo pipefail

STORY_ID="${1:-}"
DATE_STARTED="${2:-}"
DATE_COMPLETED="${3:-}"

if [[ -z "$STORY_ID" ]]; then
  echo "Usage: extract-diff-stats.sh <story-id> [<date_started> <date_completed>]" >&2
  exit 1
fi

# The resolver accepts epic, story and task ids; this script is the story-level one.
if [[ ! "$STORY_ID" =~ ^E[0-9]+_S[0-9]+$ ]]; then
  echo "ERROR: Invalid story ID format '$STORY_ID'. Expected E##_S## (e.g. E32_S06)" >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Locate the resolver
# ---------------------------------------------------------------------------
# Script-relative first: this script sits at <root>/skills/j-close-story/scripts/ in the monorepo, in
# node_modules/@jenga-ai/agent/ and in the .claude/ mirror, so "../../../scripts" reaches the resolver in all
# three layouts. Then the repo's usual cwd forms.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RESOLVER=""
for candidate in \
  "$SCRIPT_DIR/../../../scripts/commits-for-item.sh" \
  "scripts/commits-for-item.sh" \
  "node_modules/@jenga-ai/agent/scripts/commits-for-item.sh"; do
  if [[ -f "$candidate" ]]; then
    RESOLVER="$candidate"
    break
  fi
done

if [[ -z "$RESOLVER" ]]; then
  echo "ERROR: cannot find scripts/commits-for-item.sh (looked beside the skill, in ./scripts and in node_modules/@jenga-ai/agent/scripts) while resolving $STORY_ID" >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Which ids make up the story: the story itself and its tasks
# ---------------------------------------------------------------------------
PROJECT_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || true)"
[[ -n "$PROJECT_ROOT" ]] || PROJECT_ROOT="."
BOARD_DIR="$PROJECT_ROOT/project/board"

TASK_IDS=""
story_file=""
for candidate in "$BOARD_DIR/stories/${STORY_ID}_"*.md; do
  if [[ -f "$candidate" ]]; then
    story_file="$candidate"
    break
  fi
done

if [[ -n "$story_file" ]]; then
  # `tasks:` is a YAML list of ids in the frontmatter (first --- block).
  TASK_IDS="$(awk '
    /^---[[:space:]]*$/ { fm++; next }
    fm == 1 && /^tasks:[[:space:]]*$/ { in_tasks = 1; next }
    fm == 1 && in_tasks && /^[[:space:]]*-[[:space:]]*/ { sub(/^[[:space:]]*-[[:space:]]*/, ""); sub(/[[:space:]]+$/, ""); print; next }
    fm == 1 && in_tasks { in_tasks = 0 }
  ' "$story_file")"
fi

for task_file in "$BOARD_DIR/tasks/${STORY_ID}_T"*.md "$BOARD_DIR/tasks/_superseded/${STORY_ID}_T"*.md; do
  [[ -f "$task_file" ]] || continue
  base="$(basename "$task_file")"
  # E##_S##_T##_slug.md -> E##_S##_T##
  TASK_IDS="${TASK_IDS}"$'\n'"$(printf '%s\n' "$base" | sed -n 's/^\(E[0-9]*_S[0-9]*_T[0-9]*\)_.*$/\1/p')"
done

# ---------------------------------------------------------------------------
# Primary query: union of the resolver's answer for the story and for each task
# ---------------------------------------------------------------------------
# A resolver failure keeps the old tolerant behaviour (treated as no commits) but its diagnostic reaches stderr.
MATCHED_HASHES=""
add_item_commits() {
  local item="$1" out
  out="$(bash "$RESOLVER" "$item" || true)"
  [[ -n "$out" ]] && MATCHED_HASHES="${MATCHED_HASHES}${MATCHED_HASHES:+$'\n'}${out}"
  return 0
}

add_item_commits "$STORY_ID"
while IFS= read -r task_id; do
  # Only well-formed task ids that really belong to this story are queried.
  [[ "$task_id" =~ ^${STORY_ID}_T[0-9]+$ ]] || continue
  add_item_commits "$task_id"
done < <(printf '%s\n' "$TASK_IDS" | sort -u)

# De-duplicate (a bundle commit names several tasks), keeping first-seen order.
MATCHED_HASHES="$(printf '%s\n' "$MATCHED_HASHES" | awk 'NF && !seen[$0]++')"

# Parse insertions and deletions from --stat lines
# --stat lines look like: " 3 files changed, 45 insertions(+), 12 deletions(-)"
# Using portable grep (BSD and GNU compatible) instead of grep -oP
if [[ -n "$MATCHED_HASHES" ]]; then
  # One --stat pass over exactly the resolved commits (--no-walk: do not follow their parents).
  STAT_OUTPUT=$(printf '%s\n' "$MATCHED_HASHES" \
    | git log --stdin --no-walk=unsorted --stat --no-merges --pretty=format:"COMMIT:%H %s" 2>/dev/null || true)
  # Legacy quirk, kept on purpose so EST-only output is byte-identical to before: the old count was `wc -l` over
  # `--pretty=format:%H` output, which has no trailing newline, so it reported one less than the number of commits
  # (and 0 for a single commit). $(...) strips the trailing newline here, so `printf '%s'` reproduces that. Fixing
  # it is a separate, explicit decision (noted in the E79_S02_T04 summary).
  COMMITS_MATCHED=$(printf '%s' "$MATCHED_HASHES" | wc -l | tr -d ' ')
else
  STAT_OUTPUT=""
  COMMITS_MATCHED=0
fi

DIFF_ADDED=$(echo "$STAT_OUTPUT" | (grep -o '[0-9]* insertion' || true) | awk '{sum+=$1} END {print sum+0}')
DIFF_REMOVED=$(echo "$STAT_OUTPUT" | (grep -o '[0-9]* deletion' || true) | awk '{sum+=$1} END {print sum+0}')

# Secondary query — date-window unmatched count
if [[ -n "$DATE_STARTED" && -n "$DATE_COMPLETED" ]]; then
  ALL_IN_WINDOW=$(git log --all --no-merges \
    --since="$DATE_STARTED" \
    --until="${DATE_COMPLETED}T23:59:59" \
    --pretty=format:"%H" 2>/dev/null || true)

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
