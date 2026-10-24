#!/usr/bin/env bash
# scripts/check-events-log-shrink.sh — fail when the event log is not a pure extension of HEAD (E75_S01_T03).
#
# Usage: check-events-log-shrink.sh [--staged] [--file <repo-relative-path>]
#   Default file: project/logs/events.json. Compares the working-tree copy (or the index copy
#   with --staged) against its HEAD version. The log is append-only, so a valid change is always
#   a pure extension: HEAD's bytes must be an exact prefix of the new content.
# Exit: 0 ok (or no HEAD version / file not tracked yet), 1 shrunk or rewritten, 2 usage.
set -u
FILE="project/logs/events.json"; STAGED=0
while [ $# -gt 0 ]; do
  case "$1" in
    --staged) STAGED=1; shift ;;
    --file) [ $# -ge 2 ] || exit 2; FILE="$2"; shift 2 ;;
    *) echo "usage: check-events-log-shrink.sh [--staged] [--file <path>]" >&2; exit 2 ;;
  esac
done
ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || { echo "not a git repository" >&2; exit 2; }
git -C "$ROOT" cat-file -e "HEAD:$FILE" 2>/dev/null || exit 0
TMP="$(mktemp)"; trap 'rm -f "$TMP" "$TMP.new"' EXIT
git -C "$ROOT" show "HEAD:$FILE" > "$TMP"
if [ "$STAGED" = 1 ]; then
  git -C "$ROOT" show ":$FILE" > "$TMP.new" 2>/dev/null || { echo "$FILE was deleted in the index; the event log must never be removed" >&2; exit 1; }
else
  [ -f "$ROOT/$FILE" ] || { echo "$FILE is missing from the working tree; the event log must never be removed" >&2; exit 1; }
  cp "$ROOT/$FILE" "$TMP.new"
fi
old_lines=$(wc -l < "$TMP" | tr -d ' '); new_lines=$(wc -l < "$TMP.new" | tr -d ' ')
old_bytes=$(wc -c < "$TMP" | tr -d ' ')
if [ "$new_lines" -lt "$old_lines" ]; then
  echo "$FILE shrank: $old_lines lines at HEAD, $new_lines now. The log is append-only." >&2; exit 1
fi
if ! head -c "$old_bytes" "$TMP.new" | cmp -s - "$TMP"; then
  echo "$FILE does not extend its HEAD version: existing bytes were rewritten. The log is append-only." >&2; exit 1
fi
exit 0
