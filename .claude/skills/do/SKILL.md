---
name: do
description: Execute tasks from the scrum board. Reads from project/todo.md, resolves each entry to its full scrum board context, and drives the developer agent through implementation with the correct sender object and communication contract. Loops until all selected tasks are done or the user exits.
keywords:
  - do
  - execute
  - implement
  - work on
  - build
examples:
  - "implement the login feature"
  - "work on the API endpoint"
metadata: 
  prefered_agent: developer
---

# Do — Execute Scrum Board Tasks

## Instructions

### 1. Check for `project/todo.md`
Run `bash scripts/todo_manager.sh exists`. If it exits non-zero, inform the user there are no queued tasks and exit.

### 2. List tasks and let the user choose
Run `bash scripts/todo_manager.sh list` to display the queued tasks. Ask the user:
- Execute a specific task (by number or title)
- Execute the next task from the top of the list
- Exit

### 3. Detect and break down Epics or Stories (scrum-master phase)

Before resolving a task for execution, inspect the selected entry's ID:

- **Epic (`E##`)** — the entry refers to a whole epic that has not yet been broken into stories.
  Use the scrum-master agent to read the epic's board file (`$(bash scripts/board_resolver.sh)epics/`) and decompose it into stories. For each story produced:
  1. Write a story file to `$(bash scripts/board_resolver.sh)stories/`.
  2. Run `bash scripts/todo_manager.sh add '<story title>: <E##_S##>'`
  After breakdown, Run `bash scripts/todo_manager.sh remove '<epic entry title>'` and go back to step 2 so the new stories are visible.

- **Story (`E##_S##`) with no tasks** — the entry refers to a story that has not yet been broken into tasks.
  Check `$(bash scripts/board_resolver.sh)tasks/` for any task files whose front-matter `story_id` matches this story. If none exist, use the scrum-master agent to read the story's board file and decompose it into tasks. For each task produced:
  1. Write a task file to `$(bash scripts/board_resolver.sh)tasks/`.
  After breakdown, keep the story entry in `project/todo.md` (tasks are discovered from it automatically). Go back to step 2.

- **Story (`E##_S##`) with existing tasks**, or **Task (`E##_S##_T##`)** — no breakdown needed; proceed to step 4.

### 4. Resolve the task to full scrum board context
Each todo entry uses the format: `<mission title>: <E##_S##_T##>` (or `E##_S##` if no task ID).

Before starting:
1. Locate and read the matching file from `$(bash scripts/board_resolver.sh)tasks/` (or `$(bash scripts/board_resolver.sh)stories/` if story-level)
2. If the file does not exist, warn the user and skip — do not proceed with a task that has no scrum board definition
3. Present a brief summary of the task: title, acceptance criteria, parent story, parent epic

### 5. Invoke the developer agent
Pass the following to the developer agent:

**Sender object**: Copy `assets/sender_template.json` and populate all known fields (session_id, task_id, story_id, epic_id, current ISO 8601 UTC date).

**Context payload** (plain text alongside the sender object):
- Full task/story file content (title, description, acceptance criteria)
- Parent story and epic summaries (read from board files)
- Any relevant context from `project/PROJECT_SUMMARY.md`

The developer agent will:
- Log the incoming sender object to `project/logs/events.json`
- Create a worktree named `<E##_S##_T##-short-slug>`
- Implement, commit at milestones, and invoke the tester agent
- Return when the tester has verified the work

### 6. Verify documentation
After the developer completes the task, confirm the following documentation was written:
- **Execution plan** — `project/documentation/plans/<E##_S##_T##>-plan.md` must exist (written by the developer before starting work)
- **Execution summary** — `project/documentation/summaries/<E##_S##_T##>-summary.md` must exist (written by the developer before invoking the tester)

If either file is missing, ask the developer to produce it before continuing.

Additionally, if the completed work introduces user-facing changes, update `README.md` and `WARP.md` accordingly.

### 7. After successful completion
- Check for any `_INSTRUCTIONS.md` files in `$(bash scripts/board_resolver.sh)tasks/` whose ID matches the completed task. If found, present them to the user and explain that these actions must be completed before the feature will work correctly.
- Invoke the `/commit` skill to commit the work (if not already committed by the developer)
- Run `bash scripts/todo_manager.sh remove '<task title>'` to remove the completed task from `project/todo.md`
- Run `bash scripts/todo_manager.sh teardown` to delete `project/todo.md` if it is now effectively empty

### 8. Loop
Go back to step 1.

