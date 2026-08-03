---
id: E16_S01_T03
story_id: E16_S01
epic_id: E16
title: Update hook scripts and config templates to use JENGA_PROJECT_DIR
status: Done
date_created: 2026-05-10
date_started: 2026-05-10
date_completed: 2026-05-10
assigned_to: developer
---

# Task: Update hook scripts and config templates to use JENGA_PROJECT_DIR

## Description
Using the audit from T01, replace all `CLAUDE_PROJECT_DIR` references with `JENGA_PROJECT_DIR` across:
- `settings.json` hook command strings
- Any hook scripts under `hooks/`
- Any `jenga init` templates that embed the variable

Each shell-based hook command should source `lib/resolve-project-dir.sh` at its top before referencing `JENGA_PROJECT_DIR`. For `settings.json` (JSON strings), inline the resolver one-liner or delegate to a wrapper script.

## Prerequisites
- E16_S01_T01 (audit provides the full change list)
- E16_S01_T02 (resolver script must exist before being sourced)

## Acceptance Criteria
- [ ] Zero `CLAUDE_PROJECT_DIR` references remain in hook scripts or config templates
- [ ] All updated scripts source `lib/resolve-project-dir.sh` before using `JENGA_PROJECT_DIR`
- [ ] `settings.json` hooks use `JENGA_PROJECT_DIR` (via inline resolver or wrapper script)
- [ ] Existing hook behaviour is preserved end-to-end under Claude Code
