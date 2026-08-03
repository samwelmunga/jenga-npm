---
id: E17_S02
epic_id: E17
title: Reopen Tracking Fields in Board Schema
status: Passed
date_created: 2026-07-04
date_started:
date_completed: 2026-07-04
tasks:
  - E17_S02_T01
---

# Story: Reopen Tracking Fields in Board Schema

As a scrum master or developer, I want epic, story, and task files to record when and why a previously completed item was reopened — so that audit trails and history are preserved without polluting the primary date fields.

## Acceptance Criteria
- [x] `templates/SCRUM_BOARD_SCHEMA.md` frontmatter blocks for Epic, Story, and Task each include `dates_previously_completed`, `reopened_on`, and `reopened_reason` fields
- [x] Each field is documented as a comma-separated list (to support multiple reopen cycles)
- [x] A note in the schema clearly states these fields must only be populated when a previously completed item is being reopened and modified; they remain blank on first-run items
- [x] The existing `date_completed` field is unchanged and still refers to the most recent completion date

## Definition of Done
- [x] All three fields added to the Epic, Story, and Task frontmatter examples in `SCRUM_BOARD_SCHEMA.md`
- [x] Inline comments or a prose note in the schema explain the comma-separated-list convention and the reopen-only usage rule
- [x] No existing schema field or section is removed or renamed
