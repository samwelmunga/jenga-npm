---
id: E09_S01_T02
story_id: E09_S01
epic_id: E09
title: Implement --serve-app flag to serve web app static files from same server process
status: Done
date_created: 2026-05-05
date_started: 2026-05-05
date_completed: 2026-05-05
assigned_to: developer
---

# Task: Implement --serve-app flag to serve web app static files from same server process

## Description
Extend `jenga dashboard start` with a `--serve-app` flag. When set, the same server process that hosts the API also serves the built web app static files (e.g. from a `dist/` or `web/` directory). The startup message should print both the API URL and the web app URL (they may be the same origin). If the static file directory does not exist, emit a clear warning but still start the API server.

## Prerequisites
- E09_S01_T01 — base `dashboard start` command must be implemented
- Web app must have a build output directory

## Acceptance Criteria
- [ ] `--serve-app` flag is accepted by `jenga dashboard start`
- [ ] When `--serve-app` is set, static files from the web app build directory are served on the same port
- [ ] Startup output includes the URL at which the web app is accessible
- [ ] If the static file build directory is missing, a warning is printed and the API server still starts
- [ ] API routes take precedence over static file serving (no route conflicts)
