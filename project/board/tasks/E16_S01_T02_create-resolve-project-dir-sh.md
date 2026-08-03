---
id: E16_S01_T02
story_id: E16_S01
epic_id: E16
title: Create lib/resolve-project-dir.sh
status: Done
date_created: 2026-05-10
date_started: 2026-05-10
date_completed: 2026-05-10
assigned_to: developer
---

# Task: Create lib/resolve-project-dir.sh

## Description
Write `lib/resolve-project-dir.sh` — a sourced helper that exports `JENGA_PROJECT_DIR` by probing known agent env vars in priority order:

1. `$CLAUDE_PROJECT_DIR` (Claude Code)
2. `$COPILOT_WORKSPACE_FOLDER` (GitHub Copilot CLI — verify correct var name)
3. `$(git rev-parse --show-toplevel 2>/dev/null)` (any git context)
4. `$(pwd)` (final fallback)

The script must be idempotent (no-op if `JENGA_PROJECT_DIR` is already set) and must not produce output when sourced.

## Prerequisites
- E16_S01_T01 (audit — confirms which agent vars are actually in use)

## Acceptance Criteria
- [ ] `lib/resolve-project-dir.sh` exists and is sourceable
- [ ] Exports `JENGA_PROJECT_DIR` correctly in each of the four scenarios
- [ ] No side effects when sourced multiple times
- [ ] Script is executable (`chmod +x`)
