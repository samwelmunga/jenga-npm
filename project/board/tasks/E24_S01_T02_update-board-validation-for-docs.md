---
id: E24_S01_T02
story_id: E24_S01
epic_id: E24
title: Update board validation scripts to accept docs annotations
status: Passed
date_created: 2026-07-23
date_started:
date_completed: 2026-07-23
assigned_to: developer
---

# Task: Update board validation scripts to accept docs annotations

## Description
Find any board validation scripts (e.g. in `scripts/` or referenced by hooks) that validate the YAML front-matter of epic, story, or task files. Update them to recognise and preserve the `docs` field without treating it as an error or unknown field. If no validation scripts exist, document that fact and create a simple validation helper stub at `scripts/validate-board.sh` (or equivalent) that can be extended later.

## Prerequisites
- E24_S01_T01 (docs field added to templates)

## Acceptance Criteria
- [ ] Any existing board validation scripts accept `docs: [...]` without error
- [ ] Running validation against an existing board file (without `docs`) still passes
- [ ] Running validation against a board file with `docs: ["README.md"]` passes
