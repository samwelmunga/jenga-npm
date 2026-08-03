---
id: E11_S05_T01
story_id: E11_S05
epic_id: E11
title: Implement `list_skills` and `active_session` MCP tools
status: Passed
date_created: 2026-05-09
date_started: 2026-05-09
date_completed: 2026-05-09
assigned_to: developer
---

# Task: Implement `list_skills` and `active_session` MCP tools

## Description
Register two remaining MCP tools on the router: `list_skills()` returns `{ skills: [{ name, description, keywords }] }` from the in-memory index. `active_session()` returns `{ skill: string | null, startedAt: string | null }`.

## Prerequisites
- E11_S02_T02
- E11_S04_T01

## Acceptance Criteria
- [x] `list_skills` returns all indexed skills with name, description, keywords
- [x] `active_session` returns accurate state at all times
- [x] Both tools have valid MCP JSON Schema definitions
