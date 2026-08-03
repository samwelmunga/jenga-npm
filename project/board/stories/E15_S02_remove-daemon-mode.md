---
id: E15_S02
epic: E15
title: Remove daemon mode
status: Done
date_created: 2026-05-10
tasks:
  - E15_S02_T01
---

# Story: Remove daemon mode

## Goal
Strip the `--daemon` flag and its startup path from the router and CLI. The router is purely a stdio MCP server spawned by the AI client — no background sentinel, no heartbeat, no `setInterval` keep-alive.

## Background
Daemon mode was intended to keep the router alive between sessions, but it never connected a stdio transport, meaning no MCP tools were reachable. It only served as a PID lock. With project-scoped state (E15_S01) the lock moves to the project, making the daemon redundant.

## Acceptance Criteria
- [ ] `--daemon` flag removed from router startup (`mcp/router/index.js`)
- [ ] Daemon branch removed from `lib/commands/start.js`
- [ ] `jenga start` no longer forks a background process; it validates config and prints attach instructions instead (or is repurposed to call `jenga attach`)
- [ ] No `setInterval` keep-alive remains in router code
- [ ] `jenga stop` either removed or updated to explain the new model
