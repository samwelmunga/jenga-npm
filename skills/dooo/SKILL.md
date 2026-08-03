---
name: dooo
description: Parallel execution orchestrator. Calls /do to start implementations via sub-agents, then loops back to the board to identify and offer parallelisable tasks until the user selects "Done".
keywords:
  - dooo
  - parallel
  - batch
  - multiple tasks
  - orchestrate
examples:
  - "run all pending tasks in parallel"
  - "execute multiple tasks at once"
metadata:
  prefered_agent: scrum-master
---

# Dooo — Parallel Execution Orchestrator

## Instructions

### 1. Invoke `/do`
Call the `/do` skill to let the user select and start an implementation. `/do` will launch a background sub-agent to handle the implementation. Once the sub-agent is launched, `/do` returns control here.

After `/do` hands back control, mark the story/task that was just started as **Running** in its board file (update the `status:` field in the YAML front-matter).

### 2. Return to the board — identify parallelisable tasks

Collect candidates from two sources:

1. **Stories** — read all files from `project/board/stories/`.
2. **Tasks derived from stories** — read all files from `project/board/tasks/`. A task is considered in-scope if its parent story (`story_id` in the task's front-matter) is listed in `project/todo.md`, even if the task itself is not directly listed there.

A story or task is **eligible** to be presented as a parallel candidate if ALL of the following are true:
- Its status is `Pending` (not `Running`, `In Progress`, `Passed`, etc.)
- It has no unresolved dependencies (all blocking stories/tasks are at least `Running` or `Passed`)
- It is directly listed in `project/todo.md`, **OR** its parent story is listed in `project/todo.md`

### 3. Present choices to the user

Build a numbered list of eligible story titles (use `ask_user` with `choices`). **Always append "Done" as the last option.**

Example:
```
Which task would you like to start next?
1. Create /spinoff skill (E02_S02)
2. Training Skill Assets & Templates (E01_S06)
3. Done
```

If there are **no eligible tasks** (all remaining todos are blocked or already running), skip straight to step 4.

### 4. Branch on user selection

- If the user selects **"Done"** — exit the loop and inform the user that no more implementations will be started in this session.
- If the user selects a task — go back to step 1 (invoke `/do` for the selected task, then loop).

### 5. Loop termination
The loop ends when:
- The user selects "Done", OR
- There are no more eligible parallel tasks to offer
