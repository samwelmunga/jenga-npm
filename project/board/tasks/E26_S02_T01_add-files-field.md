---
id: E26_S02_T01
story_id: E26_S02
epic_id: E26
title: Add files field to package.json
status: Passed with remarks
date_created: 2026-07-31
date_started: 2026-07-31
date_completed: 2026-07-31
dates_previously_completed:
reopened_on:
reopened_reason:
assigned_to: developer
docs: []
---

# Task: Add files field to package.json

## Description
Add a `files` array to `package.json` that explicitly declares which directories and files are included when the package is published. This prevents internal files (board, queue, logs, project/, node_modules/, .jenga_paths, etc.) from being bundled. The intended publishable assets are: `skills/`, `agents/`, `hooks/`, `scripts/`, `templates/`, `bin/`, `README.md`, `LICENSE`.

Run `npm pack --dry-run` after the change and review the output to confirm only the intended files are listed.

## Prerequisites

## Acceptance Criteria
- [ ] `package.json` contains a `files` array listing: `skills/`, `agents/`, `hooks/`, `scripts/`, `templates/`, `bin/`, `README.md`, `LICENSE`
- [ ] `npm pack --dry-run` output does not include `project/`, `jobs/`, `.jenga_paths`, `node_modules/`, or any board/queue/log files
- [ ] `npm pack --dry-run` output confirms the expected framework files are included
