---
id: E10
title: Script Infrastructure & Skill Refactor
status: Done
date_created: 2026-05-08
date_started:
date_completed: 2026-05-10
stories:
  - E10_S01
  - E10_S02
  - E10_S03
  - E10_S04
  - E10_S05
  - E10_S06
  - E10_S07
  - E10_S08
---

# Epic: Script Infrastructure & Skill Refactor

## Purpose
Replace ad-hoc `todo.md` file operations and board-path guessing scattered across skill instructions with two canonical shell scripts — `todo_manager.sh` and `board_resolver.sh` — and update all affected skills to call them. Introduce a structured handoff template (owned by `/todo`) so any skill invoking `/todo` with pre-collected context can skip repeated Q&A. Add a session-end safety net that automatically cleans up effectively-empty `todo.md` files.

## Definition of Done
- [ ] `scripts/todo_manager.sh` is the single source of truth for all `todo.md` CRUD
- [ ] `scripts/board_resolver.sh` is the single source of truth for board path resolution
- [ ] `/todo`, `/do`, and `/redo` skills contain no inline file ops against `todo.md` or hardcoded board paths
- [ ] `/redo` and `/spinoff` invoke the `/todo` skill via `skills/todo/assets/todo_handoff_template.md`
- [ ] `on_session_end.sh` calls `todo_cleanup.sh` to remove effectively-empty `todo.md` on every session end
- [ ] `skills/todo/assets/todo_template.md` is NOT deleted — it remains the source template used by `todo_manager.sh`
