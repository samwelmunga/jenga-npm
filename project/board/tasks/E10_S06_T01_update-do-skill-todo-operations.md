---
id: E10_S06_T01
story_id: E10_S06
epic_id: E10
title: Update /do SKILL.md todo operations to use todo_manager.sh
status: Done
date_created: 2026-05-08
date_started: 2026-05-08
date_completed: 2026-05-08
assigned_to: developer
---

# Task: Update /do SKILL.md todo operations to use todo_manager.sh

## Description
Edit `skills/do/SKILL.md` to replace all inline `todo.md` file operations with calls to `todo_manager.sh`. Specifically: step 1 (check for todo.md) uses `bash scripts/todo_manager.sh exists`; step 2 (list tasks) uses `bash scripts/todo_manager.sh list`; step 7 (remove + teardown) uses `bash scripts/todo_manager.sh remove '<title>'` followed by `bash scripts/todo_manager.sh teardown`. No raw file ops against `todo.md` should remain.

## Prerequisites
- E10_S01_T01 (todo_manager.sh must exist)

## Acceptance Criteria
- [ ] Step 1 uses `bash scripts/todo_manager.sh exists`
- [ ] Step 2 uses `bash scripts/todo_manager.sh list`
- [ ] Step 7 uses `remove` then `teardown`
- [ ] No raw file ops against `todo.md` remain
- [ ] Skill behaviour from a user perspective is unchanged
