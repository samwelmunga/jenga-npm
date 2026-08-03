---
id: E05_S02_T01
story_id: E05_S02
epic_id: E05
title: Scaffold API Server Entry Point
status: Done
date_created: 2026-05-05
date_started: 2026-05-05
date_completed: 2026-05-05
assigned_to: developer
---

# Task: Scaffold API Server Entry Point

## Description
Create the API server entry point (`api/server.js` or equivalent) that:

- Reads the port from an environment variable `JENGA_API_PORT`, falling back to `3001`
- Initialises a structured router so endpoint groups (board, history, architecture) can be registered cleanly as separate modules
- Logs the port and key config values (e.g. project root, version) on startup
- Exports the app instance separately from the `listen` call so it can be unit-tested without binding a port

The entry point should be runnable via `node api/server.js` or an npm script `npm run api`.

## Prerequisites
- E05_S01_T02 (envelope types) available to import

## Acceptance Criteria
- [ ] Server starts and listens on port from `JENGA_API_PORT` env var, defaulting to 3001
- [ ] Startup log line includes port and version
- [ ] Router supports modular registration of endpoint groups
- [ ] App instance is exported for testing
- [ ] `npm run api` (or equivalent) starts the server
