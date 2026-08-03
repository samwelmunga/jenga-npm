---
id: E10_S03
epic_id: E10
title: "Update `/todo` skill to use `todo_manager.sh`"
status: Done
date_created: 2026-05-08
date_started:
date_completed: 2026-05-10
tasks: []
---

# Story: Update `/todo` skill to use `todo_manager.sh`

As a skill maintainer, I want `/todo`'s SKILL.md to delegate all `todo.md` file operations to `todo_manager.sh` so that the skill contains no inline shell or file-write logic.

## Acceptance Criteria
- [ ] Step 1 replaces the "create it using `assets/todo_template.md`" instruction with "run `bash scripts/todo_manager.sh add` (auto-init is handled by the script)"
- [ ] Step 5 replaces the inline format block with "run `bash scripts/todo_manager.sh add '<mission title>: <E##_S##>'`"
- [ ] No raw `echo`, `sed`, `grep`, or direct file-write instructions remain in the skill body
- [ ] The skill no longer references `todo_template.md` directly
- [ ] Skill UX (looping, prompting, classification, board-linking) is unchanged

## Definition of Done
- [ ] A complete `/todo` flow produces a correctly-formed `project/todo.md` using only `todo_manager.sh` calls
