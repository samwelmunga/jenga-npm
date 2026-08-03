#!/usr/bin/env bash

TODO_FILE="project/todo.md"

[ ! -f "$TODO_FILE" ] && exit 0

# Check if file is effectively empty (only blank lines, "# Todo", or single-line HTML comments)
while IFS= read -r line; do
  # Skip blank/whitespace-only lines
  [[ -z "${line// }" ]] && continue
  # Skip "# Todo" header
  [[ "$line" == "# Todo" ]] && continue
  # Skip single-line HTML comments
  [[ "$line" == \<\!--*--\> ]] && continue
  # Found a real entry — exit silently
  exit 0
done < "$TODO_FILE"

# File is effectively empty — delete it
rm "$TODO_FILE"
echo "[todo_cleanup] project/todo.md was empty — deleted."
exit 0
