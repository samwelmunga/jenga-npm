---
id: E24_S01_T03
story_id: E24_S01
epic_id: E24
title: Update Scrum Master agent guidance for docs annotations
status: Passed
date_created: 2026-07-23
date_started:
date_completed: 2026-07-23
assigned_to: developer
---

# Task: Update Scrum Master agent guidance for docs annotations

## Description
Update `agents/scrum-master.md` (the canonical source) to include guidance on when and how the Scrum Master should annotate board items with `docs` targets. The guidance should explain:
- The purpose of the `docs` field (provenance tracking for the `/doc` skill)
- When to add it: when a story or task directly results in user-facing documentation changes (e.g. a new skill → update README; a new API → update docs/API.md)
- How to populate it: relative paths from the repo root
- That it is optional — not every board item needs it

## Prerequisites
- E24_S01_T01

## Acceptance Criteria
- [ ] `agents/scrum-master.md` updated with a clear section on `docs` annotation guidance
- [ ] Guidance covers: purpose, when to annotate, how to populate the field, and that it's optional
- [ ] The updated guidance is also distributed to `.agents/` via the normal flow (note: `.agents/` is a build output — the canonical file is in `agents/`)
