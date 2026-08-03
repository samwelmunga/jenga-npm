---
id: E11_S04_T02
story_id: E11_S04
epic_id: E11
title: Implement `end_session` tool and auto-expire timeout
status: Passed
date_created: 2026-05-09
date_started: 2026-05-09
date_completed: 2026-05-09
assigned_to: developer
---

# Task: Implement `end_session` tool and auto-expire timeout

## Description
Register an `end_session(skill: string)` MCP tool that clears the active session if the given skill matches. Implement session auto-expire: if no `route_prompt` call is received within `sessionTimeout` ms (default 300000), clear the session automatically. Ending a non-active session is a no-op.

## Prerequisites
- E11_S04_T01

## Acceptance Criteria
- [x] `end_session` clears activeSkill when skill matches
- [x] `end_session` for a non-active skill is a no-op (no error)
- [x] Session auto-clears after `sessionTimeout` ms of inactivity
- [x] `active_session()` returns `{ skill: null, startedAt: null }` after clearing
