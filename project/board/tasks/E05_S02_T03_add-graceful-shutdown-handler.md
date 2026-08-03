---
id: E05_S02_T03
story_id: E05_S02
epic_id: E05
title: Add Graceful Shutdown Handler
status: Done
date_created: 2026-05-05
date_started: 2026-05-05
date_completed: 2026-05-05
assigned_to: developer
---

# Task: Add Graceful Shutdown Handler

## Description
Register `SIGTERM` and `SIGINT` signal handlers in the server entry point so that in-flight HTTP requests are allowed to complete before the process exits. The shutdown sequence should:

1. Stop accepting new connections (`server.close()`)
2. Wait up to a configurable timeout (default 5 s) for in-flight requests to finish
3. Log a "Shutting down gracefully" message on signal receipt
4. Log "Server closed" on clean exit or "Forcing shutdown after timeout" if the deadline is exceeded
5. Exit with code `0` on clean shutdown, `1` on forced shutdown

## Prerequisites
- E05_S02_T01 (server entry point scaffolded)

## Acceptance Criteria
- [ ] SIGTERM triggers graceful shutdown sequence
- [ ] SIGINT (Ctrl-C) triggers graceful shutdown sequence
- [ ] In-flight requests are not abruptly terminated during the timeout window
- [ ] Shutdown logs are emitted at each stage
- [ ] Process exits with the correct exit code
