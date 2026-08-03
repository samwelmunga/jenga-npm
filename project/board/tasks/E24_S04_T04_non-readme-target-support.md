---
id: E24_S04_T04
story_id: E24_S04
epic_id: E24
title: Support non-README targets via path-to-objective rule table
status: Passed
date_created: 2026-07-23
date_started:
date_completed: 2026-07-23
assigned_to: developer
---

# Task: Support non-README targets via path-to-objective rule table

## Description
Extend the generation flow to handle non-README targets (e.g. `docs/API.md`, `docs/CLI.md`, `docs/CONTRIBUTING.md`, `CHANGELOG.md`). Each target type has a different generation structure driven by its entry in the path→objective rule table from E24_S02.

For each known non-README target, implement the appropriate content structure:
- `docs/API.md` — endpoint/function reference: group by module/route, include signatures, params, return values
- `docs/CLI.md` — command reference: list commands, flags, usage examples
- `docs/CONTRIBUTING.md` — contributor guide: setup, PR process, coding standards, testing
- `CHANGELOG.md` — release notes: derive from git log, group by version/date

## Prerequisites
- E24_S04_T01
- E24_S04_T02

## Acceptance Criteria
- [ ] `docs/API.md` generation produces a structured API reference
- [ ] `docs/CLI.md` generation produces a command reference
- [ ] `docs/CONTRIBUTING.md` generation produces a contributor guide
- [ ] `CHANGELOG.md` generation derives from git history
- [ ] All non-README targets use the rule table to determine their structure
