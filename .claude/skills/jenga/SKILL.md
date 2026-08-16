---
name: jenga
description: Fully automated board orchestrator. Decomposes any unbroken Epics into Stories, any unbroken Stories into Tasks, queues all unqueued Tasks into todo.md, then executes every eligible item — no user prompts — until the board is fully started.
keywords:
  - jenga
  - orchestrate
  - auto implement
  - full board
  - automated
examples:
  - "run jenga to implement everything"
  - "start the full automation"
metadata:
  prefered_agent: scrum-master
---

# Jenga — Auto-Implementation Orchestrator

## Purpose

`/jenga` is a hands-free "commit to everything on the board" pipeline. It ensures the entire board is fully decomposed, fully queued, and fully executing — without any user interaction. It runs in four phases: **decompose → queue → execute → loop**.

## Instructions

### Phase 0 — Load threshold config

Read `project/configs/scope-thresholds.json`.

If the file does not exist, emit:
```
ERROR: project/configs/scope-thresholds.json not found. Cannot proceed.
```
and halt. Do not fall back to any default values.

If the file is not valid JSON, emit:
```
ERROR: project/configs/scope-thresholds.json is malformed (invalid JSON). Cannot proceed.
```
and halt.

Extract the following named values for use throughout this skill:
- `inline_max_files` — maximum files a task may touch to qualify for inline execution scope
- `inline_max_lines` — maximum total lines changed for inline scope
- `story_max_files` — maximum files a task may touch to qualify for story-scope bundling
- `bundle_lock_ttl_minutes` — time-to-live in minutes for a story-scope bundle lock

These values must be read fresh on each invocation. Never use hardcoded fallbacks.

### Phase 1 — Decompose Epics into Stories

Read all files in `project/board/epics/`. For each Epic that has no corresponding story files in `project/board/stories/` (i.e. no files whose name starts with that Epic's ID), invoke `/do` via a **scrum-master sub-agent** to break it down into Stories.

Repeat until every Epic has at least one Story on the board.

### Phase 2 — Decompose Stories into Tasks

Read all files in `project/board/stories/`. For each Story that has no corresponding task files in `project/board/tasks/` (i.e. no files whose name starts with that Story's ID), invoke `/do` via a **scrum-master sub-agent** to break it down into Tasks.

Repeat until every Story has at least one Task on the board.

### Phase 3 — Queue all Tasks into `todo.md`

Read all files in `project/board/tasks/`. For every Task not already listed in `project/todo.md`, append its ID (and title as a comment) to `project/todo.md`.

After this phase, `todo.md` reflects the full set of work on the board.

### Phase 3.5 — Story-bundle detection

Before dispatching individual tasks in Phase 4, check each story for bundle eligibility. This phase runs once after Phase 3 completes.

For each story that has one or more tasks listed in `todo.md`:

1. **Read the story file** — parse the `tasks:` frontmatter array to get the ordered list of task IDs.
2. **Guard: empty task list** — if the `tasks:` list is empty (zero entries), this story is **not** eligible for the bundle path. Skip to per-task dispatch in Phase 4.
3. **Read each task file** — for every task ID in the `tasks:` list, read the corresponding task file from `project/board/tasks/`.
4. **Collect `execution_scope`** — extract the `execution_scope` field from each task's YAML frontmatter. If the field is absent or has any value other than `story`, treat that task as **not** story-scoped.
5. **Apply the all-or-nothing rule** — a story qualifies for the bundle path **only if every task** in its `tasks:` list has `execution_scope: story`. A single task with a different scope (or a missing field) disqualifies the entire story.
6. **Route bundle candidates** — if all tasks in the story are `execution_scope: story` and the list is non-empty:
   a. Emit:
      ```
      BUNDLE DETECTED: story <E##_S##> — <N> story-scoped tasks will execute as a bundle.
      ```
      where `<E##_S##>` is the story ID and `<N>` is the count of tasks in the list.
   b. Call `/do <E##_S##>` once (with the story ID, not individual task IDs). This invokes the bundle execution path in `/do` (implemented in E32_S05_T02), which runs all tasks sequentially in one shared worktree.
   c. **Mark these tasks as bundled** — record their task IDs so Phase 4 skips individual dispatch for them.
7. **Non-bundle stories** — stories with a mixed scope, a zero-length task list, or any task missing `execution_scope: story` use the normal per-task dispatch in Phase 4 without any change.

### Phase 4 — Execute

Loop through `todo.md` and execute all eligible items, running independent ones in parallel. Use the threshold values loaded in Phase 0 (`inline_max_files`, `inline_max_lines`, `story_max_files`, `bundle_lock_ttl_minutes`) when applying execution-scope logic to each task. **Skip any task that was bundled in Phase 3.5** — those tasks will be handled by the `/do` story-bundle call already issued.

1. **Collect eligible items** — from `todo.md`, find all items whose board file has `status: Pending` and no unresolved dependencies, **excluding tasks already dispatched as part of a story bundle in Phase 3.5**. A dependency is resolved if the blocking item's status is at least `Running` or `Passed`.
2. **Group by parallelism** — items with no shared dependencies and no overlapping output files can run concurrently. Items that depend on each other must be sequenced.
3. **Invoke `/do` in parallel** — launch each independent item as a **background sub-agent** simultaneously. Do not wait for one to finish before starting another if they are independent.
4. **Mark Running** — update `status: Running` in each launched item's board file (YAML front-matter) immediately after launch.
5. **Wait and loop** — once all active background agents have completed, return to step 1 of this phase to pick up any newly unblocked items.

### Exit condition

When no eligible candidates remain in Phase 4, exit and output:

```
✅ Jenga complete. All eligible tasks have been started.
```

## Edge Cases

- **Epic with no stories after breakdown** — log a warning and continue to the next Epic; do not block the pipeline.
- **Story with no tasks after breakdown** — log a warning and continue to the next Story.
- **Task already in `todo.md`** — skip; do not duplicate.
- **All tasks in `todo.md` already Running/Passed** — exits cleanly with the completion message.
- **Unresolved dependencies** — item is skipped in Phase 4 until its blockers are at least `Running`.
- **`/do` failure (background agent)** — treated as a skip; mark the item's status back to `Pending` and continue the loop with remaining candidates.
- **Story with zero tasks (empty `tasks:` list)** — does not enter the bundle path in Phase 3.5; tasks (if any appear in `todo.md` independently) are dispatched normally in Phase 4.
- **Story with mixed `execution_scope` values** — falls back entirely to per-task dispatch in Phase 4; no partial bundling occurs.
- **Task file missing `execution_scope` field** — treated as not story-scoped; the containing story is disqualified from the bundle path.
- **Bundle `/do` call failure** — treated as a skip for the entire bundle; mark all bundled tasks' status back to `Pending` and continue Phase 4 with remaining non-bundled candidates.
