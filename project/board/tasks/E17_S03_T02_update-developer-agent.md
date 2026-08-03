---
id: E17_S03_T02
story_id: E17_S03
epic_id: E17
title: Update agents/developer.md to write instructions to project/instructions/
status: Done
date_created: 2026-07-18
date_started: 2026-07-18
date_completed: 2026-07-18
---

# Task: Update agents/developer.md to write instructions to project/instructions/

## Description
`agents/developer.md` currently instructs the developer to write prerequisite instruction files to `project/board/tasks/<E##_S##_T##>_INSTRUCTIONS.md`. Update all references so the canonical path is `project/instructions/<E##_S##_T##>_INSTRUCTIONS.md`.

## Affected lines (approximate)
- Task Intake step 5 — the `project/board/tasks/<E##_S##_T##>_INSTRUCTIONS.md` path
- Secrets Management section — back-reference to Task Intake step 5

## Acceptance Criteria
- [ ] `agents/developer.md` references `project/instructions/<E##_S##_T##>_INSTRUCTIONS.md` (not `project/board/tasks/`)
- [ ] Both occurrences updated (Task Intake step 5 and Secrets Management)
- [ ] No other references to `project/board/tasks/` for instructions remain in `agents/developer.md`
