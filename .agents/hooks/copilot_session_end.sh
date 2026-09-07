#!/bin/bash
# hooks/copilot_session_end.sh
#
# Copilot CLI session-end entry point.
#
# GitHub Copilot CLI DOES fire a native `sessionEnd` hook (confirmed empirically against a real
# installed `copilot` CLI under E16_S03_T03 — see docs/hook-parity.md). This script is wired as
# that hook's command via `.github/hooks/jenga.json` (committed here; generated per-consumer at
# `jenga init` / npm postinstall time via lib/generate-copilot-hooks.js — see E16_S03_T04).
# It can also still be called manually — e.g. as a post-step in a skill, or on a Copilot install
# that hasn't run `jenga init`/postinstall yet and so has no `.github/hooks/jenga.json` — the
# manual path documented below remains a valid fallback, not the primary mechanism.
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
