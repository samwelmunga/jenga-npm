---
id: E09_S02
epic_id: E09
title: "`jenga dashboard open` Command"
status: Done
date_created: 2026-05-05
date_started: 2026-05-05
date_completed: 2026-05-05
tasks: [E09_S02_T01, E09_S02_T02]
---

# Story: `jenga dashboard open` Command

As a user, I want a CLI command that opens the dashboard in my default browser so that I don't have to remember the URL or keep a terminal window in focus.

## Acceptance Criteria
- [ ] `jenga dashboard open` opens `http://localhost:<port>` in the system's default browser
- [ ] If no browser can be detected or launched, the URL is printed to stdout with a clear message
- [ ] If the server does not appear to be running (health check fails), a warning is printed before attempting to open
- [ ] Port defaults match `jenga dashboard start` defaults and are configurable via `--port`

## Definition of Done
- [ ] Command opens the browser on macOS, Linux, and Windows (or prints URL as fallback)
- [ ] Health check warning is shown when server is unreachable
