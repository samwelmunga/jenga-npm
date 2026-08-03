---
id: E06_S03
epic_id: E06
title: "[SPIKE] Editable Board"
status: Done
date_created: 2026-05-05
date_started: 2026-05-05
date_completed: 2026-05-05
tasks: [E06_S03_T01]
---

# Story: [SPIKE] Editable Board

Research and document how inline board editing (status changes, reordering, field updates) could be implemented on top of the existing read-only board. No code is produced — output is a design note.

## Spike Questions to Answer
- [ ] What API contract changes would be needed to support writes? (e.g. `PATCH /board/:epicId/stories/:storyId`)
- [ ] How should the server write changes back to markdown files safely (conflict avoidance, formatting preservation)?
- [ ] Should edits be optimistic (UI updates immediately, syncs in background) or pessimistic (UI waits for server confirmation)?
- [ ] What is the minimum set of editable fields that would make the board meaningfully interactive? (e.g. status only vs. full CRUD)
- [ ] Are there any locking concerns if the CLI and the dashboard both write to markdown files simultaneously?

## Definition of Done
- [ ] A design note document exists summarising findings and a recommended approach
- [ ] Document identifies the scope of work required (rough story estimate)
- [ ] No implementation code is written as part of this spike
