---
id: E09_S01
epic_id: E09
title: "`jenga dashboard start` Command"
status: Done
date_created: 2026-05-05
date_started: 2026-05-05
date_completed: 2026-05-05
tasks: [E09_S01_T01, E09_S01_T02]
---

# Story: `jenga dashboard start` Command

As a user, I want to start the jenga API server (and optionally serve the web app) with a single CLI command so that I can get the dashboard running without manual setup.

## Acceptance Criteria
- [ ] `jenga dashboard start` starts the HTTP API server
- [ ] An optional flag (e.g. `--serve-app`) also serves the web app static files from the same server process
- [ ] The command prints the URL(s) to visit on startup
- [ ] Port is configurable via flag (e.g. `--port 3001`)
- [ ] The command exits cleanly on Ctrl+C

## Definition of Done
- [ ] Command starts the server and the URL is reachable in a browser
- [ ] `--serve-app` flag serves the web app correctly from the same process
