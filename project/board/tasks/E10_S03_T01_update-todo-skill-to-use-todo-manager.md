---
id: E10_S03_T01
story_id: E10_S03
epic_id: E10
title: Update /todo SKILL.md to delegate to todo_manager.sh
status: Done
date_created: 2026-05-08
date_started: 2026-05-08
date_completed: 2026-05-08
assigned_to: developer
---

# Task: Update /todo SKILL.md to delegate to todo_manager.sh

## Description
Edit `skills/todo/SKILL.md` so that all `todo.md` file operations are delegated to `bash scripts/todo_manager.sh`. Specifically: replace the inline "create from template" instruction with an `add` call (auto-init is handled by the script), and replace any direct file-write instructions with `bash scripts/todo_manager.sh add '<entry>'`. Remove all raw `echo`, `sed`, `grep`, or direct file-write instructions. The skill's UX (looping, prompting, classification, board-linking) must remain unchanged.

## Prerequisites
- E10_S01_T01 (todo_manager.sh must exist)

## Acceptance Criteria
- [ ] Step 1 no longer references `todo_template.md` directly
- [ ] Step 5 uses `bash scripts/todo_manager.sh add '<mission title>: <E##_S##>'`
- [ ] No raw `echo`, `sed`, `grep`, or direct file-write instructions remain
- [ ] Skill UX behaviour is unchanged
