---
id: E10_S07_T01
story_id: E10_S07
epic_id: E10
title: Update /spinoff skill to use todo handoff template
status: Done
date_created: 2026-05-08
date_started: 2026-05-08
date_completed: 2026-05-08
assigned_to: developer
---

# Task: Update /spinoff skill to use todo handoff template

## Description
Edit `skills/spinoff/SKILL.md` step 5 ("Save the /todo") to reference `skills/todo/assets/todo_handoff_template.md` as the input format for invoking `/todo`. The skill should populate the template with the context summary collected in step 2 before invoking `/todo`, so `/todo` skips any questions already answered. The existing `/spinoff` UX flow (collect context, optionally brainstorm, save todo, return focus) must remain unchanged.

## Prerequisites
- E10_S04_T01 (handoff template must exist)

## Acceptance Criteria
- [ ] Step 5 references `skills/todo/assets/todo_handoff_template.md`
- [ ] Step 5 instructs populating the template with context from step 2
- [ ] `/todo` skips pre-filled questions
- [ ] Existing UX flow is unchanged
