---
id: E10_S04
epic_id: E10
title: "Handoff template for skills invoking `/todo`"
status: Done
date_created: 2026-05-08
date_started:
date_completed: 2026-05-10
tasks: []
---

# Story: Handoff template for skills invoking `/todo`

As a skill author, I want a structured template asset owned by `/todo` that any skill can populate with pre-collected context and pass to `/todo`, so `/todo` skips questions that have already been answered.

## Acceptance Criteria
- [ ] File exists at `skills/todo/assets/todo_handoff_template.md`
- [ ] Template contains clearly labelled placeholders for: mission title, goal/objective, affected files or scope, intended approach, and any epic/story linkage already known
- [ ] Template includes a preamble instructing `/todo` that context is pre-filled and it should skip any questions already answered by the caller
- [ ] Placeholder syntax is consistent with other asset templates in the project
- [ ] Format renders clearly in a terminal
- [ ] Template is generic enough to be used by both `/redo` and `/spinoff` (and any future caller)

## Definition of Done
- [ ] The template exists and is referenced correctly in E10_S05 (redo) and E10_S07 (spinoff)
