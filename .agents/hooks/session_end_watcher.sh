#!/usr/bin/env bash
# hooks/session_end_watcher.sh
# Detects [JENGA:SESSION_END:<skill>] in output, signals router, strips marker.

SIGNAL_PATTERN='\[JENGA:SESSION_END:[a-zA-Z0-9_-]+\]'

# Read all input
INPUT=$(cat)

# Check for signal
SIGNAL_LINE=$(echo "$INPUT" | grep -oE "$SIGNAL_PATTERN" | head -1)

if [ -n "$SIGNAL_LINE" ]; then
  # Extract skill name
  SKILL=$(echo "$SIGNAL_LINE" | sed 's/\[JENGA:SESSION_END:\(.*\)\]/\1/')

  # TODO: Call end_session on router via MCP (wired in E11_S04)
  echo "[jenga-router] Session ended: $SKILL" >&2

  # Strip the signal line from output
  echo "$INPUT" | grep -vE "$SIGNAL_PATTERN"
else
  echo "$INPUT"
fi
