---
id: E17_S03_T04
story_id: E17_S03
epic_id: E17
title: Update SCRUM_BOARD_SCHEMA.md to document project/instructions/ as canonical location
status: Done
date_created: 2026-07-18
date_started: 2026-07-18
date_completed: 2026-07-18
---

# Task: Update SCRUM_BOARD_SCHEMA.md to document project/instructions/ as canonical location

## Description
`templates/SCRUM_BOARD_SCHEMA.md` currently lists `_INSTRUCTIONS.md` files under the `project/board/tasks/` directory section. Update it to:
1. Remove the instructions file entry from the `tasks/` directory listing
2. Add a `project/instructions/` section documenting `<E##_S##_T##>_INSTRUCTIONS.md` as the canonical home for user-action prerequisite files

## Acceptance Criteria
- [ ] `templates/SCRUM_BOARD_SCHEMA.md` no longer lists `_INSTRUCTIONS.md` under `project/board/tasks/`
- [ ] A `project/instructions/` section (or equivalent documentation) is added, describing the directory as the canonical location for prerequisite instruction files
- [ ] The schema note explains that the directory is created on first use, not pre-provisioned
