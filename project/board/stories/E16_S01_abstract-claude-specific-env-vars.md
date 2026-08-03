---
id: E16_S01
epic: E16
title: Abstract Claude-Specific Env Vars
status: Done
date_created: 2026-05-10
date_completed: 2026-05-10
tasks:
  - E16_S01_T01
  - E16_S01_T02
  - E16_S01_T03
---

# Story: Abstract Claude-Specific Env Vars

## Goal
Replace all occurrences of `CLAUDE_PROJECT_DIR` and any other Claude-specific variables in hook scripts and config templates with Jenga canonical variables (e.g. `JENGA_PROJECT_DIR`). A small resolver script sets `JENGA_PROJECT_DIR` by falling back across known agent env vars (`CLAUDE_PROJECT_DIR`, `COPILOT_PROJECT_DIR`, or `pwd`).

## Tasks

### E16_S01_T01 — Audit all Claude-specific variable usage
Scan the repo for `CLAUDE_PROJECT_DIR`, `CLAUDE_*`, and any other agent-specific env vars. Produce a list of files and line numbers that need updating.

### E16_S01_T02 — Create `lib/resolve-project-dir.sh`
Write a small resolver script that exports `JENGA_PROJECT_DIR` by trying in order:
1. `$CLAUDE_PROJECT_DIR`
2. `$COPILOT_WORKSPACE_FOLDER` (or equivalent Copilot env var)
3. `$(git rev-parse --show-toplevel)`
4. `$(pwd)`

### E16_S01_T03 — Update hook scripts and config templates to use `JENGA_PROJECT_DIR`
Replace all `CLAUDE_PROJECT_DIR` references in `settings.json`, hook scripts, and any templates with `JENGA_PROJECT_DIR`. Source `lib/resolve-project-dir.sh` at the top of each affected hook script.

## Acceptance Criteria
- No `CLAUDE_PROJECT_DIR` references remain in hook scripts or config templates
- `JENGA_PROJECT_DIR` resolves correctly when running under Claude Code, Copilot CLI, or plain shell
