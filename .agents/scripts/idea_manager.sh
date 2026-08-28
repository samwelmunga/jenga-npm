#!/usr/bin/env bash
# scripts/idea_manager.sh — canonical owner of all project/ideas.md operations.
# Run from the repository root.

IDEA_FILE="project/ideas.md"
TEMPLATE="skills/idea/assets/idea_template.md"

usage() {
  cat >&2 <<EOF
Usage: $0 <subcommand> [args]

Subcommands:
  add "<entry>"    Append entry to project/ideas.md (auto-creates from template if missing)
  list             Print all non-comment, non-blank entries (silent if file missing/empty)
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
    if [ ! -f "$IDEA_FILE" ]; then
      if [ ! -f "$TEMPLATE" ]; then
        echo "Error: template not found at $TEMPLATE" >&2; exit 1
      fi
      cp "$TEMPLATE" "$IDEA_FILE"
    fi
    printf '%s\n' "$2" >> "$IDEA_FILE"
    ;;

  list)
    [ ! -f "$IDEA_FILE" ] && exit 0
    real_entries "$IDEA_FILE"
    exit 0
    ;;

  *)
    usage
    ;;
esac
