---
name: j:proceed
description: Polyfill alias of the proceed skill under a collision-safe directory name. Identical behavior to /proceed — Review project progress by checking epics and stories, optionally consulting PROJECT_SUMMARY.md and WARP.md, then continue executing the project plan. Use when the bare /proceed form is shadowed by another tool's own built-in command of the same name.
keywords:
  - proceed
  - review progress
  - check epics
  - continue executing
  - j-proceed
  - polyfill
examples:
  - "proceed with the plan"
  - "review progress and continue"
  - "j-proceed"
metadata:
  prefered_agent: scrum-master
---

# Proceed — Resume Project Execution

This skill is a literal-directory-name duplicate of `skills/proceed/`. It exists so that `/j-proceed` (and `j:j-proceed`) give a guaranteed-unshadowed way to reach the same flow as `/proceed`, even if a host tool's own built-in command of the same name would otherwise shadow or override the bare `/proceed` alias (Claude Code's native skill resolution is a literal-string, directory-name-based match — see `docs/skill-authoring.md`'s "Invocation Convention").

This file is generated/synced by `scripts/generate-j-alias.sh proceed` from `skills/proceed/SKILL.md` — do not hand-edit it; re-run the generator instead to pick up source changes.

## Instructions

1. **Assess progress** — Read `project/PROJECT_SUMMARY.md`, then check `project/board/epics/`, `project/board/stories/`, and `project/board/tasks/` to determine how far the project has come and what is outstanding.

2. **Check queues** — Review `project/queue/scrum_triggers.jsonl` for any pending triggers (rollup reviews, rapport reviews, status reviews). Process them first before deciding on next steps.

3. **Determine the next action**:
   - If there are tasks in `Pending` or `In Progress` status that have not yet been assigned to the developer, identify them.
   - If outstanding tasks are ready for implementation, write a session handoff to `project/queue/handoffs/scrum-master-<session_id>-<task_id>.json` (per-session path — see `templates/SCRUM_BOARD_SCHEMA.md`'s `handoffs/` section; use the first task ID, or `batch` if several) with `"status": "planning_complete"` so that `on_session_end.sh` routes them to the developer queue.
   - If all tasks are complete, check for epic/story rollup and update board statuses accordingly.

4. **Report** a clear summary to the user: what is done, what is in progress, what is next — and which agent will handle it.
