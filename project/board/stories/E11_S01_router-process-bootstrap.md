---
id: E11_S01
epic_id: E11
title: Router Process Bootstrap
status: Passed
date_created: 2026-05-09
date_started:
date_completed: 2026-05-10
tasks: [E11_S01_T01, E11_S01_T02, E11_S01_T03]
---

# Story: Router Process Bootstrap

As a developer, I want a Node.js stdio MCP server at `mcp/router/` that can be started, stopped, and health-checked so that the rest of the Jenga system has a reliable routing process to connect to.

## Acceptance Criteria
- [ ] Server lives at `mcp/router/index.js` and follows the same stdio MCP pattern as `mcp/help`
- [ ] On start, writes a PID file to a configurable path (default: `mcp/router/.pid`)
- [ ] Exposes a `ping` tool that returns `{ ok: true, uptime: <seconds> }` for health checks
- [ ] Gracefully handles `SIGTERM`/`SIGINT`: clears PID file and exits cleanly
- [ ] Startup errors (e.g. missing config) are printed to stderr and exit non-zero

## Definition of Done
- [ ] Server starts via `node mcp/router/index.js` and is immediately pingable
- [ ] PID file is created on start and removed on clean exit
- [ ] Process survives 60 seconds of idle without crashing
