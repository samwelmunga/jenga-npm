#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# scripts/check-todo-format.sh
#
# Prints every active-looking project/todo.md line that doesn't match the
# documented `<mission title>: <ref>` shape — most commonly the ref written
# first instead of last (e.g. `E01_S02_T03 - Fix the thing`). Reuses
# parsers/todo.js's own `readTodoRefs()`/`LEADING_REF_MISORDER_PATTERN` —
# never a second, independently-maintained regex — so the dashboard API,
# /j-reconcile, and /j-status all agree on exactly the same set of lines.
#
# Such a line is silently invisible to _queued promotion (board.js /
# kanbanColumns.js's Active Sprint "In Progress" column) even though a human
# reader would recognize it as referencing a task — this script exists so
# that gap gets surfaced instead of going unnoticed indefinitely.
#
# Run from the repository root (same convention as scripts/todo_manager.sh).
#
# Usage: check-todo-format.sh
# Output: one "line <N>: <text>" per malformed entry, nothing if none found
#         (including when project/todo.md itself is absent).
# Exit codes:
#   0  no malformed entries found
#   1  one or more malformed entries found
#   2  could not locate parsers/todo.js (neither this repo's own copy nor a
#      consumer install's node_modules copy)
# ---------------------------------------------------------------------------

set -euo pipefail

TODO_PARSER_REL="$([ -f project/app/api/parsers/todo.js ] && echo project/app/api/parsers/todo.js || echo node_modules/@jenga-ai/agent/project/app/api/parsers/todo.js)"

if [ ! -f "$TODO_PARSER_REL" ]; then
  echo "check-todo-format.sh: error: could not locate parsers/todo.js (checked project/app/api/parsers/todo.js and node_modules/@jenga-ai/agent/project/app/api/parsers/todo.js — run this from the repository root)" >&2
  exit 2
fi

TODO_PARSER_ABS="$(pwd)/$TODO_PARSER_REL"

node -e '
const { readTodoRefs } = require(process.argv[1]);
const { unrecognized } = readTodoRefs();
if (unrecognized.length === 0) process.exit(0);
for (const e of unrecognized) {
  console.log(`line ${e.line}: ${e.text}`);
}
process.exit(1);
' "$TODO_PARSER_ABS"
