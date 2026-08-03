---
id: E26_S02_T03
story_id: E26_S02
epic_id: E26
title: Implement postinstall hook for consumer project installation
status: Passed with remarks
date_created: 2026-07-31
date_started:
date_completed:
dates_previously_completed:
reopened_on:
reopened_reason:
assigned_to: developer
docs: []
---

# Task: Implement postinstall hook for consumer project installation

## Description
Create `scripts/postinstall.js` (a Node.js script) that runs automatically when a consumer project runs `npm install jenga-agent`. The script should copy `skills/`, `agents/`, `hooks/`, `scripts/`, and `templates/` from the installed package location (`node_modules/jenga-agent/`) into the consumer project's root directory.

Safe upgrade behaviour: if a destination file already exists, the script should only overwrite it if the installed package version is newer than the version currently present (read from the consumer project's `jenga.config.json` `workflow_version` field, or a new `.jenga-version` marker file). First-time installs always copy all files.

Register the script in `package.json` under `"scripts": { "postinstall": "node scripts/postinstall.js" }`.

## Prerequisites

## Acceptance Criteria
- [ ] `scripts/postinstall.js` exists and is a valid Node.js script
- [ ] `package.json` registers `scripts/postinstall.js` under `"postinstall"`
- [ ] Running `npm install <tarball>` in a fresh empty directory results in `skills/`, `agents/`, `hooks/`, `scripts/`, `templates/` appearing at the project root
- [ ] Re-running `npm install` on a project that already has the framework files does not blindly overwrite them — it checks version before overwriting
- [ ] The postinstall script logs a clear summary of what was copied and skipped
