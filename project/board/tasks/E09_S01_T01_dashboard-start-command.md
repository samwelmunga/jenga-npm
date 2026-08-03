---
id: E09_S01_T01
story_id: E09_S01
epic_id: E09
title: Implement `jenga dashboard start` CLI command with --port flag and startup URL logging
status: Done
date_created: 2026-05-05
date_started: 2026-05-05
date_completed: 2026-05-05
assigned_to: developer
---

# Task: Implement `jenga dashboard start` CLI command with --port flag and startup URL logging

## Description
Add a `jenga dashboard start` sub-command that starts the HTTP API server. The command must accept a `--port` flag (default: 3000 or project convention) and print the server URL to stdout on successful startup. The process must exit cleanly on Ctrl+C (SIGINT/SIGTERM) without leaving zombie processes.

## Prerequisites
- HTTP API server module must exist (E05_S02)
- `jenga` CLI entry point must support sub-commands

## Acceptance Criteria
- [ ] `jenga dashboard start` starts the HTTP API server
- [ ] `--port <number>` flag is accepted; server listens on the specified port
- [ ] A URL (e.g. `http://localhost:3000`) is printed to stdout when the server is ready
- [ ] Ctrl+C (SIGINT) shuts down the server cleanly with exit code 0
- [ ] SIGTERM is also handled cleanly
- [ ] Running the command without `--port` uses a sensible default port
