---
id: E24_S02_T02
story_id: E24_S02
epic_id: E24
title: Implement optional target path argument parsing
status: Passed
date_created: 2026-07-23
date_started:
date_completed: 2026-07-24
assigned_to: developer
---

# Task: Implement optional target path argument parsing

## Description
Extend `skills/doc/SKILL.md` to accept an optional positional argument: the target file path. When a path is provided (e.g. `/doc docs/API.md`), that path becomes the document target. When no path is provided, the target defaults to `README.md`.

## Prerequisites
- E24_S02_T01

## Acceptance Criteria
- [ ] `/doc` with no arguments targets `README.md`
- [ ] `/doc README.md` explicitly targets README.md
- [ ] `/doc docs/API.md` targets `docs/API.md`
- [ ] The parsed target path is clearly surfaced to subsequent steps in the skill flow
