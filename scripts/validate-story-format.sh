#!/usr/bin/env bash
# validate-story-format.sh — validate a story markdown file against required format rules
#
# Usage: ./scripts/validate-story-format.sh <path-to-story-file>
#
# Exit codes:
#   0  Story format is valid
#   1  File not found or not readable
#   2  Missing "## Acceptance Criteria" section
#   3  Missing "## Definition of Done" section
#   4  Definition of Done has no checkbox items

set -euo pipefail

FILE="${1:-}"

if [[ -z "$FILE" ]]; then
  echo "❌ Usage: $(basename "$0") <path-to-story-file>"
  exit 1
fi

if [[ ! -f "$FILE" ]] || [[ ! -r "$FILE" ]]; then
  echo "❌ File not found or not readable: $FILE"
  exit 1
fi

STORY_ID=$(basename "$FILE" .md)

# Check 2: ## Acceptance Criteria section present
if ! grep -q "^## Acceptance Criteria" "$FILE"; then
  echo "❌ $STORY_ID: missing '## Acceptance Criteria' section — $FILE"
  exit 2
fi

# Check 3: ## Definition of Done section present
if ! grep -q "^## Definition of Done" "$FILE"; then
  echo "❌ $STORY_ID: missing '## Definition of Done' section — $FILE"
  exit 3
fi

# Check 4: DoD section contains at least one checkbox item.
# Allow unchecked boxes in planned stories and checked boxes after tester verification.
# Extract content of the DoD section (lines after ## Definition of Done up to the next ## heading or EOF)
DOD_CONTENT=$(awk '/^## Definition of Done/{found=1; next} found && /^## /{found=0} found{print}' "$FILE")

if ! echo "$DOD_CONTENT" | grep -Eq "^- \[( |x)\]"; then
  echo "❌ $STORY_ID: '## Definition of Done' has no checkbox items — $FILE"
  echo "   Each DoD item must use '- [ ] <criterion>' or '- [x] <criterion>', not plain bullets"
  exit 4
fi

echo "✅ $STORY_ID: story format valid"
exit 0
