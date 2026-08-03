---
id: E17_S03
epic_id: E17
title: Dedicated Instructions Location for Task Prerequisites
status: Done
date_created: 2026-07-16
date_started: 2026-07-18
date_completed: 2026-07-18
tasks:
  - E17_S03_T01
  - E17_S03_T02
  - E17_S03_T03
  - E17_S03_T04
---

# Story: Dedicated Instructions Location for Task Prerequisites

As a developer or scrum master, I want `_INSTRUCTIONS.md` files (user-action prerequisites) to live in a dedicated `project/instructions/` directory — so that user-facing instruction files are clearly separated from board task files and have a single discoverable home.

## Background
Currently, `_INSTRUCTIONS.md` files are written to `project/board/tasks/` alongside scrum board task files. This conflates two distinct concerns: agent-facing work items (board schema files) and human-facing prerequisites (instructions for manual user actions). Discovery relies on a filename convention scan inside a directory not designed for this purpose.

See evaluation: `project/rapports/analysis/instructions-dedicated-location-eval.md`

## Acceptance Criteria
- [ ] A dedicated `project/instructions/` directory exists (created on first use, not pre-provisioned)
- [ ] `agents/developer.md` instructs the developer to write prerequisite instructions to `project/instructions/<E##_S##_T##>_INSTRUCTIONS.md` (not `project/board/tasks/`)
- [ ] `.agents/skills/do/SKILL.md` Step 7 checks `project/instructions/` (not `project/board/tasks/`) for the task's `_INSTRUCTIONS.md`
- [ ] `.agents/skills/commit/SKILL.md` Step 1 checks `project/instructions/<E##_S##_T##>_INSTRUCTIONS.md`
- [ ] `templates/SCRUM_BOARD_SCHEMA.md` removes the instructions file entry from the `tasks/` directory section and documents `project/instructions/` as the canonical location
- [ ] No existing `_INSTRUCTIONS.md` files are lost (migration note or script handles any files already in `project/board/tasks/`)

## Definition of Done
- [ ] All touch-points updated: `developer.md`, `do/SKILL.md`, `commit/SKILL.md`, `SCRUM_BOARD_SCHEMA.md`
- [ ] The new path is consistent across all four files — no reference to `project/board/tasks/` remains for instructions files
- [ ] Any existing `_INSTRUCTIONS.md` files in `project/board/tasks/` are migrated to `project/instructions/`
