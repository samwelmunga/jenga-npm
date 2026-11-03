---
name: j.close-task
description: Close one already-implemented task by having the Tester verify it and write its status, then have the Scrum Master drain the trigger queue so the story and epic roll up when everything beneath them is complete, and report exactly how far the rollup got.
keywords:
  - close task
  - close the task
  - roll up epic
  - rollup
  - finish task
  - j-close-task
examples:
  - "close E65_S05_T08 and roll up the epic"
  - "j-close-task E65_S05_T08"
  - "verify the last task and roll up the story"
---

# close-task — Verify a Task and Roll Up

`skills/j-close-task/` is the canonical, hand-edited directory for this skill.

## Purpose

`/j-close-task <task_id>` closes a task whose implementation is already committed and merged, without going through `j.do`. It runs two agents in turn, because the board's write rules split the work:

1. The **Tester** verifies the task and writes its judged status (`Passed`, `Passed with remarks`, `Failed`). Only the Tester may write that status (`templates/SCRUM_BOARD_SCHEMA.md`, "Status Writers"). When this was the last open task of its story, the Tester also writes a `story_rollup` trigger.
2. The **Scrum Master** runs its "Drain Scrum Triggers Queue" procedure, which turns that trigger into the story status and, when every story of the epic is complete, the epic status (`agents/scrum-master.md`, "Rollup Logic", including the epic scope test gate).

This skill sets no `prefered_agent` because it orchestrates both agents itself; it never writes a status or a trigger.

`<task_id>` must be `E##_S##_T##`. Anything else: ask for it as a numbered list of the open tasks, free text last.

## Instructions

### 1. Resolve the context

```bash
bash "$([ -f skills/j-close-task/scripts/close-task-context.sh ] && echo skills/j-close-task/scripts/close-task-context.sh || echo node_modules/@jenga-ai/agent/skills/j-close-task/scripts/close-task-context.sh)" context <task_id>
```

Pass `--session <id>` when this run was started by an orchestrator that supplied a session id, so the sender object reuses it. A non-zero exit means the task, story or epic file is missing or ambiguous: report the stderr line and stop.

### 2. Decide whether the Tester is needed

Branch on `status_class` and the commit lists in the output:

| Condition | Action |
|---|---|
| `status_class` is `completed` or `ladder` | The task is already closed. Skip to step 4. |
| `task_status` is `Blocked` or `Rejected` | Stop and report. Neither is a state this skill may override. |
| `commits` is empty and `other_branch_commits` is not | Stop. The task's work exists only on other branches, so the Tester would verify the wrong tree. Name the SHAs and suggest `j.reconcile` to merge them. |
| `commits` is empty and so is `other_branch_commits` | Stop. The Tester requires at least one commit SHA, and the task has no commit evidence. |
| otherwise | Continue to step 3. `other_branch_commits` alone is not a problem: it is usually a rewritten copy of merged work. |

### 3. Verify with the Tester

Dispatch the `tester` agent. Its prompt carries the task file path, the story and epic ids, the commit SHAs, and the `sender` object from step 1 unchanged. Call it directly and use its return value; never poll for its completion.

Take its reported status. On `failed` or `error`, stop: report the status and the rapport path, and do not start the rollup.

### 4. Check what the rollup would touch

```bash
bash "$([ -f skills/j-close-task/scripts/close-task-context.sh ] && echo skills/j-close-task/scripts/close-task-context.sh || echo node_modules/@jenga-ai/agent/skills/j-close-task/scripts/close-task-context.sh)" report <task_id>
```

The Scrum Master's procedure processes every trigger in `project/queue/scrum_triggers.jsonl` and then clears the file. If `queue.types` holds anything besides `story_rollup` and `status_review` (a `rapport_review`, say), tell the user what else would be processed and ask:

    What would you like to do?
    1. Drain the whole queue (rapports and all)
    2. Stop before the rollup
    3. Other (describe below)

An empty queue means the Tester wrote no trigger, which is correct when the story still has open tasks. Go to step 6 and report that.

### 5. Roll up with the Scrum Master

Dispatch the `scrum-master` agent with this instruction: run the "Drain Scrum Triggers Queue" procedure and apply "Rollup Logic" for the story and epic above, and report the story and epic statuses it wrote.

The epic scope test gate is run by the Tester. If the Scrum Master reports that it needs the gate and cannot dispatch the Tester itself, dispatch the Tester to run it and hand the exit code back. Do not run the suites yourself and do not skip the gate.

### 6. Report

Run the `report` command from step 4 again and present the task, story and epic statuses. State the outcome with one of these:

- **Closed and rolled up**: the task, its story and the epic are all complete.
- **Closed, story rolled up, epic open**: name `epic.open_stories`.
- **Closed, story open**: name `story.open_tasks`; there was nothing to roll up yet.
- **Closed, rollup queued**: the trigger is still in the queue (the user chose to stop, or the Scrum Master did not run).
- **Not closed**: the Tester reported `failed` or `error`, or a guard in step 2 stopped the run.

Never describe a rollup as done from the Scrum Master's summary alone; the `report` output is the evidence.
