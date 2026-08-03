#!/usr/bin/env bash
# Resolves the board path from project/configs/workflow.json.
# Outputs a normalised path (always ends with exactly one '/') to stdout.
# Falls back to "project/board/" when the config file is missing or the key is absent.
# Exits non-zero and prints to stderr when the config file exists but is malformed JSON.

CONFIG="project/configs/workflow.json"
DEFAULT="project/board/"

if [ ! -f "$CONFIG" ]; then
  printf '%s\n' "$DEFAULT"
  exit 0
fi

if command -v jq >/dev/null 2>&1; then
  # Validate JSON first
  if ! jq empty "$CONFIG" 2>/dev/null; then
    echo "Error: $CONFIG contains malformed JSON" >&2
    exit 1
  fi

  board_path=$(jq -r '.paths.board // empty' "$CONFIG" 2>/dev/null)
else
  # Validate JSON portably: check that the file starts with '{' or '[' after whitespace
  first_char=$(sed 's/^[[:space:]]*//' "$CONFIG" | head -c1)
  if [ "$first_char" != "{" ] && [ "$first_char" != "[" ]; then
    echo "Error: $CONFIG contains malformed JSON" >&2
    exit 1
  fi

  # Portable grep+sed fallback: extract "board": "value"
  board_path=$(grep -o '"board"[[:space:]]*:[[:space:]]*"[^"]*"' "$CONFIG" \
    | sed 's/.*"board"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/' \
    | head -1)
fi

if [ -z "$board_path" ]; then
  printf '%s\n' "$DEFAULT"
  exit 0
fi

# Normalise: ensure exactly one trailing slash
board_path="${board_path%/}/"

printf '%s\n' "$board_path"
exit 0
