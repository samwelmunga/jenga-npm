# E16_S01_T01 — Execution Plan: Audit Claude-Specific Env Vars

**Task:** E16_S01_T01  
**Date:** 2026-05-10  
**Epic:** E16 — Multi-Platform Agent Config Parity  
**Story:** E16_S01 — Abstract Claude-Specific Env Vars  

## Objective

Produce a definitive list of every file and line number that references Claude-specific environment variables, so that T02 and T03 have a clear change list to work from.

## Approach

1. **Scan for `CLAUDE_PROJECT_DIR`** — the primary variable targeted for replacement with `JENGA_PROJECT_DIR`.
2. **Scan for all `CLAUDE_*` variables** — to catch any other Claude-specific env vars (e.g. `CLAUDE_AGENT_TYPE`, `CLAUDE_SESSION_ID`, `CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS`).
3. **Scan for all `COPILOT_*` variables** — to document any Copilot-side env vars already referenced or expected.
4. **Check hook scripts specifically** — `hooks/`, `.agents/hooks/`, `.claude/hooks/`, `settings.json`.
5. **Exclude board/docs references** — the findings will note which hits are in source files (actionable) vs. documentation/board files (informational).
6. **Record findings** in `project/documentation/summaries/E16_S01_T01-summary.md`.

## Tools

- `grep -rn` / ripgrep across the full repository
- File-type filters: `.sh`, `.json`, `.md`, `.js`, `.ts`, `.yaml`, `.yml`

## No Code Changes

This is an audit-only task. No source files will be modified.
