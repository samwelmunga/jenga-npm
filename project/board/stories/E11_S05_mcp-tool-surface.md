---
id: E11_S05
epic_id: E11
title: MCP Tool Surface
status: Passed
date_created: 2026-05-09
date_started:
date_completed: 2026-05-10
tasks: [E11_S05_T01, E11_S05_T02]
---

# Story: MCP Tool Surface

As a client (hook script or Claude Code), I want the router to expose a complete set of MCP tools so that all routing and session operations are accessible over the stdio MCP protocol.

## Acceptance Criteria
- [ ] `route_prompt(text: string)` → `{ action, transformed, skill, confidence }` — routes a prompt
- [ ] `active_session()` → `{ skill: string | null, startedAt: string | null }` — returns current session state
- [ ] `end_session(skill: string)` → `{ ok: true }` — clears the active session for the given skill
- [ ] `list_skills()` → `{ skills: [{ name, description, keywords }] }` — returns the current skill index
- [ ] `reload_skills()` → `{ ok: true, skill_count: number }` — rescans skills directory and rebuilds index
- [ ] `ping()` → `{ ok: true, uptime: number, skill_count: number }` — health check
- [ ] All tools follow the MCP tool schema spec (JSON Schema input/output definitions)
- [ ] Tool errors return structured MCP error responses, not unhandled exceptions

## Definition of Done
- [ ] All 6 tools callable via any MCP client
- [ ] Tool schemas are valid and pass MCP schema validation
- [ ] No tool throws an unhandled exception under normal operating conditions
