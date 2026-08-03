---
id: E11_S01_T02
story_id: E11_S01
epic_id: E11
title: Implement PID file management
status: Passed
date_created: 2026-05-09
date_started: 2026-05-09
date_completed: 2026-05-09
assigned_to: developer
---

# Task: Implement PID file management

## Description
On startup write the process PID to the PID file path (default `mcp/router/.pid`, configurable). On clean exit (SIGTERM/SIGINT) delete the PID file. Startup errors (e.g. missing config) print to stderr and exit non-zero.

## Prerequisites
- E11_S01_T01

## Acceptance Criteria
- [x] PID file is created at startup and deleted on clean exit
- [x] SIGTERM and SIGINT are both handled — router exits cleanly
- [x] Missing config causes exit non-zero with a descriptive stderr message
