#!/usr/bin/env bash
# update-task-frontmatter.sh — Write or update a YAML key in task/story frontmatter
#
# Usage: update-task-frontmatter.sh <file-path> <key> <value>
#
# If the key already exists in the frontmatter block (between the first pair
# of --- delimiters), its value is replaced in-place.
# If the key does not exist, it is appended just before the closing ---.
#
# Works with both GNU and BSD sed (macOS-compatible — uses a temp file instead
# of sed -i '').
#
# Exit codes:
#   0 — success
#   1 — argument error or file not found

set -euo pipefail

# ---------------------------------------------------------------------------
# Argument validation
# ---------------------------------------------------------------------------

FILE_PATH="${1:-}"
KEY="${2:-}"
VALUE="${3:-}"

if [[ -z "$FILE_PATH" || -z "$KEY" || -z "$VALUE" ]]; then
  echo "Usage: $(basename "$0") <file-path> <key> <value>" >&2
  echo "  Example: $(basename "$0") project/board/tasks/E32_S06_T01_my-task.md actual_files_changed 5" >&2
  exit 1
fi

if [[ ! -f "$FILE_PATH" ]]; then
  echo "ERROR: File not found: '$FILE_PATH'" >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Process frontmatter
# ---------------------------------------------------------------------------

# Strategy:
#   1. Read the file line by line.
#   2. Track whether we are inside the frontmatter block (between --- delimiters).
#   3. If the key exists in frontmatter, replace the line.
#   4. If we reach the closing --- without having replaced the key, insert the
#      key:value line immediately before the closing ---.
#   5. Write the result to a temp file and move it back.

TMPFILE=$(mktemp)
trap 'rm -f "$TMPFILE"' EXIT

in_frontmatter=0
frontmatter_open=0   # set to 1 after the opening ---
key_replaced=0
closing_found=0

while IFS= read -r line; do
  # Detect frontmatter boundaries
  if [[ "$line" == "---" ]]; then
    if [[ $frontmatter_open -eq 0 ]]; then
      # Opening ---
      frontmatter_open=1
      in_frontmatter=1
      echo "$line" >> "$TMPFILE"
      continue
    elif [[ $in_frontmatter -eq 1 ]]; then
      # Closing --- — if key was not found yet, insert it now
      if [[ $key_replaced -eq 0 ]]; then
        echo "${KEY}: ${VALUE}" >> "$TMPFILE"
        key_replaced=1
      fi
      in_frontmatter=0
      closing_found=1
      echo "$line" >> "$TMPFILE"
      continue
    fi
  fi

  # Replace existing key in frontmatter
  if [[ $in_frontmatter -eq 1 && $key_replaced -eq 0 ]]; then
    # Match lines starting with exactly this key (not a key that begins with the same prefix)
    if [[ "$line" =~ ^${KEY}:[[:space:]]* ]]; then
      echo "${KEY}: ${VALUE}" >> "$TMPFILE"
      key_replaced=1
      continue
    fi
  fi

  echo "$line" >> "$TMPFILE"
done < "$FILE_PATH"

# Edge case: file had no frontmatter closing --- (malformed file)
if [[ $key_replaced -eq 0 && $closing_found -eq 0 ]]; then
  echo "WARNING: No frontmatter closing --- found in '$FILE_PATH'. Key not written." >&2
  exit 1
fi

# Move the temp file into place
mv "$TMPFILE" "$FILE_PATH"
trap - EXIT

exit 0
