#!/bin/bash
# hooks/copilot_session_end.sh
#
# Copilot CLI session-end entry point.
#
# GitHub Copilot CLI does not fire a native SessionEnd hook. Call this script
# manually at the end of a Copilot session or as a post-step in any skill
# that completes a significant pipeline stage (e.g. commit, lgtm).
#
# This wrapper:
#   1. Sources lib/resolve-project-dir.sh to export JENGA_PROJECT_DIR,
#      JENGA_AGENT_TYPE, and JENGA_SESSION_ID (idempotent — safe to call
#      even if a parent script already sourced the resolver).
#   2. Delegates to hooks/on_session_end.sh for all shared cleanup logic:
#      queue routing, rapport detection, handoff file processing, and
#      todo cleanup.
#
# Usage:
#   bash hooks/copilot_session_end.sh
#
# Environment (optional — resolver provides defaults):
#   JENGA_PROJECT_DIR   — override project root (default: git root or pwd)
#   JENGA_AGENT_TYPE    — override agent type (default: "generic")
#   JENGA_SESSION_ID    — override session ID (default: uuidgen / timestamp)

# shellcheck source=lib/resolve-project-dir.sh
source "$(git rev-parse --show-toplevel)/lib/resolve-project-dir.sh"

exec bash "$JENGA_PROJECT_DIR/hooks/on_session_end.sh" "$@"
