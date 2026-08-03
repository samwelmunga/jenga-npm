---
id: E24_S04_T03
story_id: E24_S04
epic_id: E24
title: Implement conditional Examples section
status: Passed
date_created: 2026-07-23
date_started:
date_completed: 2026-07-23
assigned_to: developer
---

# Task: Implement conditional Examples section

## Description
Extend the generation template to include an **Examples** section — but only when the project produces user-facing output (i.e. is a CLI, API, library, or SDK). 

The skill must infer the project type from the synthesis context:
- CLI indicators: presence of a `bin` field in `package.json`, `[tool.scripts]` in `pyproject.toml`, CLI-related skill files, or explicit mention in board items
- API indicators: Express/FastAPI/Gin/etc dependencies, route definitions, `openapi.yaml`
- Library/SDK indicators: no `bin`, published to a registry, export-heavy source

If the project type cannot be determined, omit the Examples section and do not guess.

## Prerequisites
- E24_S04_T02

## Acceptance Criteria
- [ ] Examples section is included when project type is CLI, API, library, or SDK
- [ ] Examples section is omitted when project type cannot be determined
- [ ] Project type inference uses synthesis context (not hardcoded assumptions)
- [ ] At least 2 concrete examples are generated when the section is included
