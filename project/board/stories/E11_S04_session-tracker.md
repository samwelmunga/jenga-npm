---
id: E11_S04
epic_id: E11
title: Session Tracker
status: Done
date_created: 2026-05-09
date_started:
date_completed: 2026-05-10
tasks: [E11_S04_T01, E11_S04_T02, E11_S04_T03]
---

# Story: Session Tracker

As the router, I want to track which skill session is currently active so that subsequent prompts within that session are passed through unmodified until the session ends.

## Acceptance Criteria
- [ ] In-memory session state: `{ activeSkill: string | null, startedAt: timestamp | null }`
- [ ] When `route_prompt` returns `action: "invoke"`, the router sets `activeSkill` to the matched skill name
- [ ] While `activeSkill` is set, all subsequent `route_prompt` calls return `action: "passthrough"` immediately (no matching)
- [ ] Session ends when the router receives the completion signal `[JENGA:SESSION_END:<skill_name>]` via the `end_session(skill)` tool
- [ ] Session auto-expires after `sessionTimeout` ms of inactivity (configurable in `jenga.cli.json`, default: 300000ms / 5 min)
- [ ] `active_session()` tool returns `{ skill: string | null, startedAt: timestamp | null }`
- [ ] Ending a session for a skill that is not the active skill is a no-op (not an error)

## Definition of Done
- [ ] After invoking `/brainstorm`, follow-up prompts return passthrough until `[JENGA:SESSION_END:brainstorm]` is received
- [ ] Session auto-clears correctly after timeout with no follow-up prompts
- [ ] `active_session()` returns accurate state at all times
