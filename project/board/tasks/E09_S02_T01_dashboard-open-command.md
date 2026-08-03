---
id: E09_S02_T01
story_id: E09_S02
epic_id: E09
title: Implement `jenga dashboard open` CLI command with health check and browser launch
status: Done
date_created: 2026-05-05
date_started: 2026-05-05
date_completed: 2026-05-05
assigned_to: developer
---

# Task: Implement `jenga dashboard open` CLI command with health check and browser launch

## Description
Add a `jenga dashboard open` sub-command that opens the dashboard URL in the system's default browser. Before opening, perform a health check against the server (e.g. `GET /health` or a TCP connect on the target port). If the health check fails, print a warning to stdout telling the user the server may not be running, then print the URL they can open manually. Use OS-appropriate browser-launch mechanisms (`open` on macOS, `xdg-open` on Linux, `start` on Windows).

## Prerequisites
- `jenga dashboard start` (E09_S01_T01) should exist for the user flow to be coherent, but this command can be implemented independently
- A health-check endpoint or convention must be defined

## Acceptance Criteria
- [ ] `jenga dashboard open` attempts a health check on `http://localhost:<port>`
- [ ] If the health check passes, the URL is opened in the system's default browser
- [ ] If the browser cannot be launched, the URL is printed to stdout
- [ ] If the health check fails, a warning is printed explaining the server may not be running
- [ ] The command does not hang — health check has a short timeout (e.g. 2 seconds)
