---
id: E17_S03_T01
story_id: E17_S03
epic_id: E17
title: Migrate existing _INSTRUCTIONS.md files to project/instructions/
status: Done
date_created: 2026-07-18
date_started: 2026-07-18
date_completed: 2026-07-18
---

# Task: Migrate existing _INSTRUCTIONS.md files to project/instructions/

## Description
Two `_INSTRUCTIONS.md` files currently live in `project/board/tasks/`:
- `project/board/tasks/E22_S04_T01_INSTRUCTIONS.md`
- `project/board/tasks/E22_S02_T02_INSTRUCTIONS.md`

Move them to `project/instructions/` (create the directory on first use). Update any internal cross-references if present.

## Acceptance Criteria
- [ ] `project/instructions/` directory exists after this task
- [ ] `project/instructions/E22_S04_T01_INSTRUCTIONS.md` exists with the same content as the original
- [ ] `project/instructions/E22_S02_T02_INSTRUCTIONS.md` exists with the same content as the original
- [ ] Original files in `project/board/tasks/` are removed
- [ ] No content is lost during migration
