#!/usr/bin/env bash
# scripts/todo_manager.sh — canonical owner of all project/todo.md operations.
# Run from the repository root.

TODO_FILE="project/todo.md"

# PACKAGE_ROOT locates the package-shipped todo template (skills/j-todo/assets/).
# This script always lives at scripts/, one level below the package root, in
# both layouts:
#   - this monorepo checkout
#   - a consumer install, inside node_modules/@jenga-ai/agent/
# BASH_SOURCE-derived resolution is exact in both cases (same reasoning as
# scripts/jenga-permission-level-switch.sh's PACKAGE_ROOT derivation), with a
# defensive node_modules-relative fallback matching the PKG_ROOT convention in
# skills/init/scripts/init.sh, in case BASH_SOURCE resolution is ever
# unavailable (e.g. the script is sourced rather than executed).
PACKAGE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEMPLATE="$PACKAGE_ROOT/skills/j-todo/assets/todo_template.md"
if [ ! -f "$TEMPLATE" ]; then
  TEMPLATE="node_modules/@jenga-ai/agent/skills/j-todo/assets/todo_template.md"
fi

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
    # Remove only the FIRST matching line atomically. A line matches when it contains <title> as a plain substring,
    # with one extra rule (E86_S05_T01): when <title> ends in a board ID (`<mission title>: E10_S1`), the occurrence
    # must also END at that ID, i.e. no [A-Za-z0-9_] may follow it. Without it `...: E10_S1` would also match
    # `...: E10_S10` or `...: E10_S1_T01` (an ID is a string prefix of the longer ones once IDs have three or more
    # digits) and the wrong entry would be removed. A title that does not end in an ID keeps the
    # plain "first line containing <title>" meaning.
    #
    # awk exits 3 when no line matched; the temp file is then discarded, so a miss never rewrites the file.
    if awk -v title="$2" '
      function matches(line,    rest, pos, c) {
        rest = line
        while ((pos = index(rest, title)) > 0) {
          if (!ends_in_id) return 1
          c = substr(rest, pos + length(title), 1)
          if (c == "" || c !~ /[A-Za-z0-9_]/) return 1
          rest = substr(rest, pos + 1)
        }
        return 0
      }
      BEGIN { ends_in_id = (title ~ /E[0-9]+(_S[0-9]+(_T[0-9]+)?)?$/) }
      found || !matches($0) { print; next }
      { found = 1 }
      END { exit (found ? 0 : 3) }
    ' "$TODO_FILE" > "${TODO_FILE}.tmp"; then
      mv "${TODO_FILE}.tmp" "$TODO_FILE"
    else
      rc=$?
      rm -f "${TODO_FILE}.tmp"
      if [ "$rc" -eq 3 ]; then
        echo "Error: no line matching \"$2\" found in $TODO_FILE" >&2; exit 1
      fi
      exit "$rc"
    fi
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
