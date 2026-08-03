---
id: E16_S01_T01
story_id: E16_S01
epic_id: E16
title: Audit all Claude-specific variable usage
status: Done
date_created: 2026-05-10
date_started: 2026-05-10
date_completed: 2026-05-10
assigned_to: developer
---

# Task: Audit all Claude-specific variable usage

## Description
Scan the entire repository for `CLAUDE_PROJECT_DIR`, `CLAUDE_*`, and any other agent-specific env vars embedded in hook scripts, config templates, skill files, and scripts. Produce a clear list of every file and line number that references a Claude-specific variable so that T02 and T03 have a definitive change list to work from.

## Prerequisites
None.

## Acceptance Criteria
- [x] All files containing `CLAUDE_PROJECT_DIR` or other `CLAUDE_*` vars are identified
- [x] Any Copilot-specific vars (e.g. `COPILOT_*`) already in use are also listed
- [x] Findings are recorded as a comment or note that informs T03's implementation
