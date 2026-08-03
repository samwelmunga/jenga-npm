---
id: E17_S03_T03
story_id: E17_S03
epic_id: E17
title: Update /do and /commit skills to check project/instructions/
status: Done
date_created: 2026-07-18
date_started: 2026-07-18
date_completed: 2026-07-18
---

# Task: Update /do and /commit skills to check project/instructions/

## Description
Two skill files reference `project/board/tasks/` when looking for `_INSTRUCTIONS.md` files:

1. `.agents/skills/do/SKILL.md` — Step 7: "Check for any `_INSTRUCTIONS.md` files in `project/board/tasks/`..."
2. `.agents/skills/commit/SKILL.md` — Step 1 (prerequisite verification): "Check whether an `_INSTRUCTIONS.md` file exists for this task at `project/board/tasks/<E##_S##_T##>_INSTRUCTIONS.md`..."

Also update the inline schema comment in `commit/SKILL.md` that lists `Instructions files: E##_S##_T##_INSTRUCTIONS.md` with the board/tasks path.

Update all three occurrences to use `project/instructions/<E##_S##_T##>_INSTRUCTIONS.md`.

## Acceptance Criteria
- [ ] `.agents/skills/do/SKILL.md` Step 7 references `project/instructions/` (not `project/board/tasks/`)
- [ ] `.agents/skills/commit/SKILL.md` Step 1 references `project/instructions/<E##_S##_T##>_INSTRUCTIONS.md`
- [ ] `.agents/skills/commit/SKILL.md` inline schema comment updated to reflect new path
- [ ] No remaining references to `project/board/tasks/*_INSTRUCTIONS.md` in either skill file
