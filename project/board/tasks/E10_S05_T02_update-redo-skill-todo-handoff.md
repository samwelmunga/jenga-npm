---
id: E10_S05_T02
story_id: E10_S05
epic_id: E10
title: Update /redo skill step 3 to use todo handoff template
status: Done
date_created: 2026-05-08
date_started: 2026-05-08
date_completed: 2026-05-08
assigned_to: developer
---

# Task: Update /redo skill step 3 to use todo handoff template

## Description
Edit step 3 of `skills/redo/SKILL.md` so that instead of writing to `todo.md` directly or manually creating a `/todo`, the skill populates `skills/todo/assets/todo_handoff_template.md` with the collected scope (original implementation summary, redo objective, affected files, approach) and then invokes the `/todo` skill with that content. The handoff must clearly signal to `/todo` which fields are pre-filled so `/todo` skips those questions.

## Prerequisites
- E10_S04_T01 (handoff template must exist)

## Acceptance Criteria
- [ ] Step 3 references `skills/todo/assets/todo_handoff_template.md`
- [ ] Step 3 instructs populating the template with: original summary, redo objective, affected files, approach
- [ ] Step 3 invokes `/todo` with the populated template content
- [ ] No direct `todo.md` file operations remain in the skill
