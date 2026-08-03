#!/usr/bin/env bash
# scripts/todo_manager.sh — canonical owner of all project/todo.md operations.
# Run from the repository root.

TODO_FILE="project/todo.md"
TEMPLATE="skills/todo/assets/todo_template.md"

usage() {
  cat >&2 <<EOF
Usage: $0 <subcommand> [args]

Subcommands:
  add "<entry>"    Append entry to project/todo.md (auto-creates from template if missing)
  remove "<title>" Remove first line containing <title> (exits non-zero if not found)
  list             Print all non-comment, non-blank entries (silent if file missing/empty)
  exists           Exit 0 if at least one real entry exists; exit 1 otherwise
  teardown         Delete project/todo.md if effectively empty; no-op if absent or has real entries
EOF
  exit 1
}

# Filters out blank lines, lines starting with #, and HTML comments
real_entries() {
  grep -v '^\s*$' "$1" 2>/dev/null \
    | grep -v '^\s*#' \
    | grep -v '^\s*<!--'
}

case "${1:-}" in
  add)
    [ -z "${2:-}" ] && { echo "Error: add requires an entry argument" >&2; exit 1; }
    if [ ! -f "$TODO_FILE" ]; then
      if [ ! -f "$TEMPLATE" ]; then
        echo "Error: template not found at $TEMPLATE" >&2; exit 1
      fi
      cp "$TEMPLATE" "$TODO_FILE"
    fi
    printf '%s\n' "$2" >> "$TODO_FILE"
    ;;

  remove)
    [ -z "${2:-}" ] && { echo "Error: remove requires a title argument" >&2; exit 1; }
    if [ ! -f "$TODO_FILE" ]; then
      echo "Error: $TODO_FILE does not exist" >&2; exit 1
    fi
    # Check for at least one match
    if ! grep -qF "$2" "$TODO_FILE"; then
      echo "Error: no line matching \"$2\" found in $TODO_FILE" >&2; exit 1
    fi
    # Remove only the FIRST matching line atomically
    awk -v title="$2" 'found || !index($0, title) { print; next } { found=1 }' \
      "$TODO_FILE" > "${TODO_FILE}.tmp" && mv "${TODO_FILE}.tmp" "$TODO_FILE"
    ;;

  list)
    [ ! -f "$TODO_FILE" ] && exit 0
    real_entries "$TODO_FILE"
    exit 0
    ;;

  exists)
    if [ ! -f "$TODO_FILE" ]; then
      echo "todo.md is missing" >&2; exit 1
    fi
    if [ -z "$(real_entries "$TODO_FILE")" ]; then
      echo "todo.md exists but has no real entries" >&2; exit 1
    fi
    exit 0
    ;;

  teardown)
    [ ! -f "$TODO_FILE" ] && exit 0
    # "Effectively empty" = only blank lines, "# Todo", or HTML comments
    non_trivial=$(grep -v '^\s*$' "$TODO_FILE" \
      | grep -v '^\s*# Todo\s*$' \
      | grep -v '^\s*<!--')
    if [ -z "$non_trivial" ]; then
      rm -f "$TODO_FILE"
    fi
    exit 0
    ;;

  *)
    usage
    ;;
esac
