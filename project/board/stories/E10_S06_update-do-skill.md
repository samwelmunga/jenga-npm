---
id: E10_S06
epic_id: E10
title: "Update `/do` skill to use `todo_manager.sh` + `board_resolver.sh`"
status: Done
date_created: 2026-05-08
date_started:
date_completed: 2026-05-10
tasks: []
---

# Story: Update `/do` skill to use `todo_manager.sh` + `board_resolver.sh`

As a skill maintainer, I want `/do`'s SKILL.md to delegate all `todo.md` operations to `todo_manager.sh` and all board-path resolution to `board_resolver.sh` so the skill contains no inline file ops or hardcoded paths.

## Acceptance Criteria
- [ ] Step 1 (check for `todo.md`) uses `bash scripts/todo_manager.sh exists` instead of a prose file-check
- [ ] Step 2 (list tasks) uses `bash scripts/todo_manager.sh list` to display contents
- [ ] Step 7 (remove + teardown) uses `bash scripts/todo_manager.sh remove '<title>'` followed by `bash scripts/todo_manager.sh teardown`
- [ ] All hardcoded `project/board/` path references are replaced with `$(bash scripts/board_resolver.sh)`
- [ ] No raw file ops against `todo.md` remain in the skill body
- [ ] Skill behaviour from a user perspective is unchanged

## Definition of Done
- [ ] A complete `/do` flow (select task, execute, complete) correctly removes the entry and tears down `todo.md` when empty
- [ ] Board file lookups resolve correctly against the configured board path
