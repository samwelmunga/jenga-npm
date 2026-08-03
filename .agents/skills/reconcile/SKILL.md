---
name: reconcile
description: Reconcile the scrum board with actual implementation state. Cross-checks every task's board status against git history and worktrees, merges orphaned worktree branches, demotes unimplemented "Done" items, promotes secretly-implemented items, and cleans stale entries from todo.md. Use when the board feels out of sync, after a big merge session, when tasks were completed outside the normal workflow, or when todo.md has grown stale. Trigger on phrases like "sync the board", "clean up the board", "reconcile", "board is out of date", "todo is stale", or "check what's really done".
metadata:
  prefered_agent: scrum-master
---

# Reconcile — Board ↔ Code Synchronisation

Walks the full board (epics → stories → tasks), verifies each item's status against what actually exists in git, and fixes any drift. Also cleans `project/todo.md` of entries that are already done.

## Instructions

### 0. Read configuration
Read `project/configs/workflow.json` for board paths. Fall back to `project/board/` if missing.
The statuses that count as "completed" are: **Done**, **Passed**, **Passed with remarks**.

### 1. Snapshot the board
Scan every file in `epics/`, `stories/`, and `tasks/`. For each item record:
- `id`, `title`, `status` (the **pre-reconcile** status — needed in phase 4)
- `date_completed` (if set)

Also read `project/todo.md` and parse every non-comment, non-blank line into a list of todo entries.

### 2. Verify "completed" tasks — are they really implemented?
For every task whose status is a completed status:

1. **Search git history** — run `git log --all --oneline --grep="<task_id>"` (e.g. `E01_S01_T01`). A matching commit is strong evidence of implementation.
2. **Check documentation artefacts** — look for a plan or summary file under `project/documentation/plans/` or `project/documentation/summaries/` whose name contains the task ID.
3. **Read the task's acceptance criteria** and spot-check the codebase for the key deliverables described (e.g. if the task says "create `scripts/foo.sh`", verify the file exists).

If implementation **is confirmed** — no action needed; the status is correct.

If implementation **cannot be confirmed**:
1. List git worktrees (`git worktree list`) and branches (`git branch --all`) that appear to match the task ID or its slug (the branch naming convention is `<E##_S##_T##-short-slug>`).
2. If a matching worktree or branch exists:
   - Inform the user and ask for confirmation before merging.
   - On confirmation, merge the branch into the current branch (`git merge <branch>`).
   - After a successful merge, the task stays at its completed status.
   - If the merge has conflicts, alert the user and **do not** change the status — leave it for manual resolution.
3. If **no** matching branch or worktree exists:
   - Change the task's status to **Pending** in its board file.
   - Clear `date_started` and `date_completed`.
   - Report the demotion.

### 3. Verify "incomplete" tasks — are they secretly implemented?
For every task whose status is **not** a completed status (Pending, In Progress, Running, Blocked, etc.):

1. **Search git history** for commits referencing the task ID.
2. **Check documentation artefacts** as in phase 2.
3. **Spot-check acceptance criteria** against the codebase.

If implementation **is confirmed**:
- Update the task's status to **Passed** in its board file.
- Set `date_completed` to today (ISO 8601).
- If the task is listed in `project/todo.md`, **comment it out** by wrapping the line:
  ```
  <!-- RECONCILED: <original line> -->
  ```
- Report the promotion.

If implementation **is not confirmed** — no action needed; the status is already correct.

### 4. Roll up story and epic statuses
After all tasks have been reconciled:

- For each **story**: if all of its tasks are now in a completed status, set the story to **Done** (if not already). If any task was demoted, and the story was previously completed, set the story back to **In Progress**.
- For each **epic**: apply the same roll-up logic over its stories.

#### DoD Gap Detection

After rolling up statuses, scan every story whose status is a completed status (`Passed`, `Passed with remarks`, `Done`) for unchecked Definition of Done items:

1. Read the story file and locate the `## Definition of Done` section. If the section is absent, skip this story gracefully (no error).
2. Scan the DoD section for any lines matching `^- \[ \]` (unchecked checkboxes).
3. If unchecked boxes are found: record the story ID, story title, and the full text of each unchecked item.
4. If all DoD boxes are already ticked (`- [x]`), or the DoD section is absent, no gap is reported for that story.

At the end of Phase 4, if any DoD gaps were found across any stories, include a **"DoD Gaps"** section in the reconcile report (see `assets/report_format.md`) listing each affected story and its unchecked items.

**Important:** Gap detection is **report-only**. Do not automatically change the status of any story or epic based on unchecked DoD boxes — surface the gaps so a human can review and decide.

### 5. Clean `project/todo.md`
Walk the todo entries parsed in phase 1:

- **Already-done entries** — if an entry references a task/story/epic whose pre-reconcile status (from the snapshot in phase 1) was already a completed status **and** whose implementation has been confirmed (phase 2), **remove the line entirely** from `project/todo.md`.
- **Newly-reconciled entries** — entries that were commented out in phase 3 stay as `<!-- RECONCILED: ... -->`.
- If `project/todo.md` is left with only the header, the format comment, and blank lines, delete the file.

### 6. Print a summary
Output a reconciliation report using the format in `assets/report_format.md`.

If no changes were made, print: `Board and todo.md are in sync — nothing to reconcile. ✅`
