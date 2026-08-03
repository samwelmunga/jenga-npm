#!/usr/bin/env bash
# lib/resolve-project-dir.sh
# Sourced helper: exports JENGA_PROJECT_DIR, JENGA_AGENT_TYPE, JENGA_SESSION_ID
# by probing known agent environment variables in priority order.
# Idempotent — no-op if JENGA_PROJECT_DIR is already set.

if [ -n "${JENGA_PROJECT_DIR:-}" ]; then
  return 0 2>/dev/null || true
fi

# --- JENGA_PROJECT_DIR ---
if [ -n "${CLAUDE_PROJECT_DIR:-}" ]; then
  JENGA_PROJECT_DIR="$CLAUDE_PROJECT_DIR"
elif [ -n "${COPILOT_WORKSPACE_FOLDER:-}" ]; then
  JENGA_PROJECT_DIR="$COPILOT_WORKSPACE_FOLDER"
else
  _git_root="$(git rev-parse --show-toplevel 2>/dev/null)"
  if [ -n "$_git_root" ]; then
    JENGA_PROJECT_DIR="$_git_root"
  else
    JENGA_PROJECT_DIR="$(pwd)"
  fi
  unset _git_root
fi
export JENGA_PROJECT_DIR

# --- JENGA_AGENT_TYPE ---
if [ -z "${JENGA_AGENT_TYPE:-}" ]; then
  if [ -n "${CLAUDE_AGENT_TYPE:-}" ]; then
    JENGA_AGENT_TYPE="$CLAUDE_AGENT_TYPE"
  else
    JENGA_AGENT_TYPE="generic"
  fi
  export JENGA_AGENT_TYPE
fi

# --- JENGA_SESSION_ID ---
if [ -z "${JENGA_SESSION_ID:-}" ]; then
  if [ -n "${CLAUDE_SESSION_ID:-}" ]; then
    JENGA_SESSION_ID="$CLAUDE_SESSION_ID"
  elif command -v uuidgen >/dev/null 2>&1; then
    JENGA_SESSION_ID="$(uuidgen)"
  else
    JENGA_SESSION_ID="session-$(date +%s)-$$"
  fi
  export JENGA_SESSION_ID
fi
