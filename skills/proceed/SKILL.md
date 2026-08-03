---
name: proceed
description: Review project progress by checking epics and stories, optionally consulting PROJECT_SUMMARY.md and WARP.md, then continue executing the project plan.
keywords:
  - proceed
  - review progress
  - check epics
  - continue executing
examples:
  - "proceed with the plan"
  - "review progress and continue"
metadata:
  prefered_agent: scrum-master
---

# Proceed — Resume Project Execution

## Instructions

1. **Assess progress** — Read `project/PROJECT_SUMMARY.md`, then check `project/board/epics/`, `project/board/stories/`, and `project/board/tasks/` to determine how far the project has come and what is outstanding.

2. **Check queues** — Review `project/queue/scrum_triggers.jsonl` for any pending triggers (rollup reviews, rapport reviews, status reviews). Process them first before deciding on next steps.

3. **Determine the next action**:
   - If there are tasks in `Pending` or `In Progress` status that have not yet been assigned to the developer, identify them.
   - If outstanding tasks are ready for implementation, write a session handoff to `project/queue/.session_handoff.json` with `"status": "planning_complete"` so that `on_session_end.sh` routes them to the developer queue.
   - If all tasks are complete, check for epic/story rollup and update board statuses accordingly.

4. **Report** a clear summary to the user: what is done, what is in progress, what is next — and which agent will handle it.
