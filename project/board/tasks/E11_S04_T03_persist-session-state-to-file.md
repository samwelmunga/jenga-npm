---
id: E11_S04_T03
story_id: E11_S04
epic_id: E11
title: Persist session state to .session.json in daemon mode
status: Done
date_created: 2026-05-10
date_started: 2026-05-10
date_completed: 2026-05-10
assigned_to: developer
---

# Task: Persist session state to .session.json in daemon mode

## Description
When the router runs in daemon mode (`--daemon`), its MCP stdio transport is skipped, making session state inaccessible to external processes like `jenga status`. Fix this by writing `activeSession` to `mcp/router/.session.json` whenever it changes. This allows `jenga status` (and any other process) to read the current session without needing IPC.

Write `.session.json` in three cases:
1. Session starts (on invoke) — write `{ skill, startedAt }`
2. Session ends (via `end_session` tool or auto-expire) — write `{ skill: null, startedAt: null }`
3. Router shuts down (SIGTERM/SIGINT) — clear the file (write null state or delete it)

## Prerequisites
- E11_S04_T01
- E11_S04_T02

## Acceptance Criteria
- [ ] `.session.json` is written to `mcp/router/` whenever `activeSession` changes
- [ ] File contains `{ "skill": "brainstorm", "startedAt": "<iso>" }` when a session is active
- [ ] File contains `{ "skill": null, "startedAt": null }` when no session is active
- [ ] File is cleared/reset on graceful shutdown
- [ ] Write failures are logged to stderr but do not crash the router
