---
name: j.proceed
description: Review project progress by checking epics and stories, optionally consulting PROJECT_SUMMARY.md and WARP.md, then continue executing the project plan.
keywords:
  - proceed
  - review progress
  - check epics
  - continue executing
  - j-proceed
examples:
  - "proceed with the plan"
  - "review progress and continue"
  - "j-proceed"
metadata:
  prefered_agent: scrum-master
---

# Proceed — Resume Project Execution

`skills/j-proceed/` is the **canonical, hand-edited** directory for this skill, per CLAUDE.md's "The Canonical Naming Contract" (the `E50` reopening of 2026-09-09, which promoted `skills/j-proceed/` from generated twin to sole canonical form). The `j-` prefix is there for collision safety — a real directory under a distinct name, so a host tool shipping its own same-named built-in command cannot shadow it (Claude Code's native skill resolution is a literal-string, directory-name-based match; see `docs/skill-authoring.md`'s "Invocation Convention").

> ⚠️ **`scripts/generate-j-alias.sh` was retired by `E50_S14` and no longer exists — there is nothing to run.** This file was previously generated from a bare `skills/proceed/SKILL.md` source; `E50_S15` deleted that directory. This file is now the sole canonical, hand-edited source for this skill — edit it directly.

## Instructions

1. **Assess progress** — Read `project/PROJECT_SUMMARY.md`, then check `project/board/epics/`, `project/board/stories/`, and `project/board/tasks/` to determine how far the project has come and what is outstanding.

2. **Check queues** — Review `project/queue/scrum_triggers.jsonl` for any pending triggers (rollup reviews, rapport reviews, status reviews). Process them first before deciding on next steps.

3. **Determine the next action**:
   - If there are tasks in `Pending` or `In Progress` status that have not yet been assigned to the developer, identify them.
   - If outstanding tasks are ready for implementation, write a session handoff to `project/queue/handoffs/scrum-master-<session_id>-<task_id>.json` (per-session path — see `$([ -f templates/SCRUM_BOARD_SCHEMA.md ] && echo templates/SCRUM_BOARD_SCHEMA.md || echo node_modules/@jenga-ai/agent/templates/SCRUM_BOARD_SCHEMA.md)`'s `handoffs/` section; use the first task ID, or `batch` if several) with `"status": "planning_complete"` so that `on_session_end.sh` routes them to the developer queue.
   - If all tasks are complete, check for epic/story rollup and update board statuses accordingly.

4. **Report** a clear summary to the user: what is done, what is in progress, what is next — and which agent will handle it.
