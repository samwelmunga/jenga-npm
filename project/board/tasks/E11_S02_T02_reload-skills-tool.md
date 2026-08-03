---
id: E11_S02_T02
story_id: E11_S02
epic_id: E11
title: Implement `reload_skills` MCP tool and update ping with skill count
status: Passed
date_created: 2026-05-09
date_started: 2026-05-09
date_completed: 2026-05-09
assigned_to: developer
---

# Task: Implement `reload_skills` MCP tool and update ping with skill count

## Description
Register a `reload_skills` MCP tool that re-scans the skills directory and rebuilds the in-memory index. Update the `ping` tool response to include `skill_count: <number>`.

## Prerequisites
- E11_S02_T01

## Acceptance Criteria
- [x] `reload_skills` correctly reflects added/removed skills without restarting the router
- [x] `ping` response now includes `skill_count`
- [x] `reload_skills` returns `{ ok: true, skill_count: <number> }`
