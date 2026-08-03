---
id: E10_S04_T01
story_id: E10_S04
epic_id: E10
title: Create skills/todo/assets/todo_handoff_template.md
status: Done
date_created: 2026-05-08
date_started: 2026-05-08
date_completed: 2026-05-08
assigned_to: developer
---

# Task: Create skills/todo/assets/todo_handoff_template.md

## Description
Create `skills/todo/assets/todo_handoff_template.md` — a structured asset template that callers (e.g. `/redo`, `/spinoff`) populate with pre-collected context before invoking `/todo`. The template must include clearly labelled placeholders for: mission title, goal/objective, affected files or scope, intended approach, and epic/story linkage. It must include a preamble instructing `/todo` to skip any questions whose answers are already present. Placeholder syntax must be consistent with other asset templates in the project. It must be generic enough to be used by both `/redo` and `/spinoff`.

## Prerequisites
None

## Acceptance Criteria
- [ ] File exists at `skills/todo/assets/todo_handoff_template.md`
- [ ] Preamble instructs `/todo` to skip pre-filled questions
- [ ] Placeholders cover: mission title, goal/objective, affected files/scope, intended approach, epic/story linkage
- [ ] Placeholder syntax is consistent with other project templates
- [ ] Template renders clearly in a terminal
