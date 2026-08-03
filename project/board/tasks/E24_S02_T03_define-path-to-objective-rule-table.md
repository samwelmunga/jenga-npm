---
id: E24_S02_T03
story_id: E24_S02
epic_id: E24
title: Define path-to-objective rule table
status: Passed
date_created: 2026-07-23
date_started:
date_completed: 2026-07-24
assigned_to: developer
---

# Task: Define path-to-objective rule table

## Description
Define a deterministic path→objective rule table within the `/doc` skill. Each entry maps a target file path (or pattern) to a generation objective that describes what the document should contain. This table drives what `/doc` generates — it determines the doc type and content structure for known targets.

Minimum required entries:
- `README.md` → project overview (Description + Getting Started + optional Examples)
- `docs/API.md` → API reference documentation
- `docs/CLI.md` → CLI usage guide
- `docs/CONTRIBUTING.md` → contributor guide
- `CHANGELOG.md` → changelog / release notes

The table should be extensible — new entries can be added without restructuring the skill.

## Prerequisites
- E24_S02_T01

## Acceptance Criteria
- [ ] Path→objective rule table is defined in `skills/doc/SKILL.md` (or a supporting asset file)
- [ ] At least 5 known path mappings are present
- [ ] The table format is extensible (e.g. a YAML/JSON asset or a clearly structured section in the skill)
- [ ] The table is used by subsequent steps to determine generation objectives
