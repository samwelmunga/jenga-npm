---
id: E13_S01_T01
story_id: E13_S01
epic_id: E13
title: Implement `jenga init` interactive wizard
status: Passed
date_created: 2026-05-09
date_started: 2026-05-09
date_completed: 2026-05-09
assigned_to: developer
---

# Task: Implement `jenga init` interactive wizard

## Description
Implement the `jenga init` command as an interactive wizard that prompts for: (1) agent selection (claude / copilot / custom), (2) skills directory path (default: `skills/`), (3) match threshold (default: 0.75), (4) session timeout in minutes (default: 5). Each prompt shows the default and accepts Enter to keep it. If `jenga.cli.json` already exists, show current values as defaults.

## Prerequisites
None

## Acceptance Criteria
- [x] Wizard prompts for all 4 fields with defaults
- [x] Pressing Enter for all prompts completes in < 60 seconds
- [x] Re-run shows existing config values as defaults
- [x] Re-run does not lose existing data
