---
id: E17_S02_T01
story_id: E17_S02
epic_id: E17
title: Add reopen-tracking fields to SCRUM_BOARD_SCHEMA.md
status: Passed
date_created: 2026-07-04
date_started:
date_completed: 2026-07-04
assigned_to: developer
---

# Task: Add reopen-tracking fields to SCRUM_BOARD_SCHEMA.md

## Description
Update `templates/SCRUM_BOARD_SCHEMA.md` to add three new frontmatter fields — `dates_previously_completed`, `reopened_on`, and `reopened_reason` — to the file format examples for Epic, Story, and Task. Each field holds a comma-separated list to support multiple reopen cycles. Add a clearly visible note (prose or inline comment) explaining these fields must only be populated when a previously completed item is being reopened and modified; they should remain blank on first-run items.

## Prerequisites
None.

## Acceptance Criteria
- [x] `dates_previously_completed`, `reopened_on`, and `reopened_reason` fields are present in the frontmatter block of the Epic format example
- [x] The same three fields are present in the frontmatter block of the Story format example
- [x] The same three fields are present in the frontmatter block of the Task format example
- [x] Each field shows a comma-separated-list value example or comment (e.g. `# YYYY-MM-DD, YYYY-MM-DD`)
- [x] A note in the schema (adjacent to these fields or in a dedicated sub-section) states: these fields are only populated when a previously completed item is reopened and modified; leave blank on new items
- [x] No existing field, section, or text in `SCRUM_BOARD_SCHEMA.md` is removed or altered
