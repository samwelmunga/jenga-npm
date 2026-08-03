---
id: E03_S03
epic: E03
title: Jenga Empty-Board Fallback to /do
status: Done
date_created: 2026-05-03
date_started: 2026-05-03
date_completed: 2026-05-03
---

# Story: Jenga Empty-Board Fallback to /do

## Description
When the `/jenga` skill finds the todo list empty, instead of stopping, it should invoke the `/do` skill to check whether there are any stories on the board that have not yet been broken down into tasks. This ensures the automated orchestrator doesn't silently halt when work may still exist at the story level.

## Acceptance Criteria
- [x] `/jenga` detects when `project/todo.md` has no actionable entries
- [x] On empty todo list, `/jenga` invokes `/do` rather than exiting
- [x] `/do` is invoked with the intent of finding stories with no tasks yet
- [x] If `/do` finds no eligible work either, `/jenga` exits cleanly
- [x] Behaviour is consistent with the existing `/jenga` orchestration loop
