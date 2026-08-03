---
id: E26_S01_T03
story_id: E26_S01
epic_id: E26
title: Deprecate workflow_version in jenga.config.json
status: Passed
date_created: 2026-07-31
date_started: 2026-07-31
date_completed: 2026-07-31
dates_previously_completed:
reopened_on:
reopened_reason:
assigned_to: developer
docs: []
---

# Task: Deprecate workflow_version in jenga.config.json

## Description
The `workflow_version` field in `jenga.config.json` (and its example file `jenga.config.example.json`) is superseded by the `version` field in `package.json`. Add a deprecation comment or annotation to `jenga.config.example.json` explaining that `workflow_version` is no longer the authoritative version source and pointing readers to `package.json`. If any script or agent reads `workflow_version` to make decisions, update those to read from `package.json` instead.

## Prerequisites

## Acceptance Criteria
- [ ] `jenga.config.example.json` includes a deprecation note on `workflow_version` pointing to `package.json`
- [ ] No script or agent reads `workflow_version` for active decision-making (replace with `node -p "require('./package.json').version"` or equivalent)
- [ ] `grep -r "workflow_version" .` returns only config files and any migration notes — no active code logic
