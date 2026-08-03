---
id: E13_S02_T01
story_id: E13_S02
epic_id: E13
title: Implement `jenga start` router daemon spawn
status: Passed
date_created: 2026-05-09
date_started: 2026-05-09
date_completed: 2026-05-09
assigned_to: developer
---

# Task: Implement `jenga start` router daemon spawn

## Description
Implement the `jenga start` command. Read `jenga.cli.json` for router configuration. Spawn `mcp/router/index.js` as a detached background process (survives terminal close). Write the router PID to the PID file path defined in config. Print "✓ Jenga Router started (PID: <n>)" on success.

## Prerequisites
None

## Acceptance Criteria
- [x] `jenga start` spawns router as a detached background process
- [x] PID file is written at the configured path
- [x] Router survives the terminal that started it being closed
- [x] Success message printed with PID
