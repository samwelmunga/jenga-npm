---
id: E15
title: Multi-Project Router & jenga attach
status: Done
date_created: 2026-05-10
date_started:
date_completed:
stories:
  - E15_S01
  - E15_S02
  - E15_S03
---

# Epic: Multi-Project Router & jenga attach

## Purpose
Fix the single-global-router limitation so each project can run its own scoped router instance, remove the non-functional daemon mode, and introduce a `jenga attach` command that writes the MCP config entry into a project's `.claude/settings.json` so new AI sessions auto-spawn a project-scoped router without manual setup.

## Background
Currently all runtime state (PID file, session file) is stored relative to the jenga install directory (`__dirname`), making the router effectively global — a second project calling `jenga start` receives "Router already running". Daemon mode exists but does not route anything; it is a heartbeat sentinel with no real function. Sessions that don't have the router in their MCP config from the start never pick it up.

## Definition of Done
- [ ] `jenga start` from any project creates state in `.jenga/` inside that project; two projects can run simultaneously without conflict
- [ ] `--daemon` flag and daemon startup path are removed; router is purely a stdio MCP server
- [ ] `jenga attach` writes a valid MCP server entry into `.claude/settings.json` in the current project; subsequent sessions auto-spawn the router
- [ ] `jenga start`, `jenga stop`, and `jenga status` all resolve state from `process.cwd()` rather than `__dirname`
