---
id: E24_S01_T01
story_id: E24_S01
epic_id: E24
title: Add optional docs field to board schema and templates
status: Passed
date_created: 2026-07-23
date_started:
date_completed: 2026-07-23
assigned_to: developer
---

# Task: Add optional docs field to board schema and templates

## Description
Add an optional `docs: [...]` YAML field to the board file templates for epics, stories, and tasks. This field is a list of relative file paths (e.g. `["README.md", "docs/API.md"]`) that identifies which documentation files a given board item affects. The field must be optional — existing board files without it must continue to work unchanged.

Check existing templates in `project/board/` or any template directory, and update them. Also check if there's a JSON schema file for board items.

## Prerequisites
None.

## Acceptance Criteria
- [ ] Epic board template includes an optional `docs: []` field in its YAML front-matter example
- [ ] Story board template includes an optional `docs: []` field in its YAML front-matter example
- [ ] Task board template includes an optional `docs: []` field in its YAML front-matter example
- [ ] Existing board files without `docs` continue to work unchanged
