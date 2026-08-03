---
id: E10_S05
epic_id: E10
title: "Update `/redo` skill: path bug fix + `/todo` handoff"
status: Done
date_created: 2026-05-08
date_started:
date_completed: 2026-05-10
tasks: []
---

# Story: Update `/redo` skill — path bug fix + `/todo` handoff

As a skill maintainer, I want `/redo` to resolve board paths via `board_resolver.sh` (fixing the hardcoded path bug) and to hand off todo creation to the `/todo` skill using the handoff template instead of writing to `todo.md` directly.

## Acceptance Criteria
- [ ] Every board path reference in `skills/redo/SKILL.md` (`project/epics/`, `project/stories/`) is replaced with a call to `scripts/board_resolver.sh`; no hardcoded paths remain
- [ ] Step 3 no longer instructs the agent to write to `todo.md` directly or to manually "create a `/todo`"
- [ ] Step 3 instructs the agent to populate `skills/todo/assets/todo_handoff_template.md` with collected scope (original implementation summary, redo objective, affected files, approach) and invoke the `/todo` skill with that content
- [ ] The handoff clearly signals to `/todo` which fields are pre-filled so `/todo` skips those questions
- [ ] Steps 1, 2, and 4+ are preserved and unchanged in intent
- [ ] The skill no longer contains any direct `todo.md` file operations

## Definition of Done
- [ ] A `/redo` flow ends with a correctly-formed `todo.md` entry created via `/todo`
- [ ] Board file lookups resolve correctly against the configured board path
