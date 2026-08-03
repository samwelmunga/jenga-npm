---
id: E10_S07
epic_id: E10
title: "Update `/spinoff` skill to use handoff template"
status: Done
date_created: 2026-05-08
date_started:
date_completed: 2026-05-10
tasks: []
---

# Story: Update `/spinoff` skill to use handoff template

As a skill maintainer, I want `/spinoff` to use `skills/todo/assets/todo_handoff_template.md` when invoking `/todo` so that pre-collected context is passed consistently and `/todo` skips questions already answered.

## Acceptance Criteria
- [ ] `/spinoff` step 5 ("Save the /todo") references `skills/todo/assets/todo_handoff_template.md` as the input format for invoking `/todo`
- [ ] The skill populates the handoff template with the context summary collected in step 2 before invoking `/todo`
- [ ] `/todo` receives the pre-filled template and skips any questions already answered
- [ ] The existing `/spinoff` UX flow (collect context, optionally brainstorm, save todo, return focus) is unchanged

## Definition of Done
- [ ] A `/spinoff` flow produces a correctly-formed `todo.md` entry via `/todo` using the handoff template
