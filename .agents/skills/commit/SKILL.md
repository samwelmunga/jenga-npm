---
name: j:commit
description: Commit implemented epic, story, or task work using the EST naming convention. Also handles user-action prerequisites and new-epic boundaries. Use after completing any EST work item.
keywords:
  - commit
  - save
  - git commit
  - done
  - push
examples:
  - "commit this work"
  - "save my changes"
---

# Commit — Commit Completed Work

## Inline Mode (called by /do for inline-scoped tasks)

When invoked with the `--inline` flag OR when the environment variable `JENGA_COMMIT_INLINE=1` is set, execute inline mode:

1. **Skip** the reconcile step, the `/doc-sync` scan, and the user-action prerequisites check (steps 1-3 in normal mode). No `/reconcile` invocation, `/doc-sync` invocation, or `_INSTRUCTIONS.md` lookup is performed — inline tasks are single, already-scoped-small changes that reconcile and doc-sync would add overhead to, not risk, disproportionate to the size of the change.
2. **Skip** any worktree merge logic — inline tasks execute in the main session with no dedicated worktree to merge.
3. Stage all changed files relevant to the task (use `git add -A` or specific files if a list was provided by the caller).
4. Commit using the EST naming convention:
   ```
   task(<E##_S##_T##>): <short description of what was done>
   ```
   The task ID (`E##_S##_T##`) must be taken from the context provided by `/do` — do not inspect task frontmatter independently.
5. **Exit** — do not check for the next epic and do not emit "All Done!" in inline mode. `/do` manages the loop and next-epic detection.

If `--inline` is absent **and** `JENGA_COMMIT_INLINE` is not set (or is not `1`), ignore this section entirely and proceed with normal mode below.

---

## Instructions

If no epic, task, or story has been implemented, exit with the message: "No implementation to commit."

1. **Reconcile first, scoped to this commit** — Invoke the `/reconcile` skill before any other action, so the board is never committed in a drifted state.
   - **Determine the scope to pass** (in order):
     1. If `/commit` was invoked with an explicit epic/story/task id argument (e.g. `/commit E46`, `/commit E17_S04_T02`), use that id.
     2. Otherwise, if the calling context already identifies a single task/story/epic just completed (e.g. a developer or tester agent's sender object naming `task_id`/`story_id`/`epic_id`, or a `/do` invocation for one task), use that id.
     3. Otherwise, derive it from what's staged: run `git diff --cached --name-only` and filter to paths under `project/board/epics/`, `project/board/stories/`, and `project/board/tasks/`. Extract the id each matched filename encodes.
        - If every extracted id shares a single common story-or-narrower ancestor (all belong to one story's own file plus any of its own tasks' files, or are all exactly one task's own file, or are all exactly one epic's own file with nothing narrower staged), use that single most-specific id (story/task id if present, else the epic id) as the scope.
        - If matched ids span more than one distinct story, or more than one distinct epic, this case does not resolve — do not guess between them; fall through to case 4.
        - **If no board files at all are staged, skip `/reconcile` entirely — do not fall through to case 4.** A commit that touches no board file cannot itself commit board drift, so there is nothing for a pre-commit reconcile to protect against; running a full unscoped scan here would be pure waste, not a safety net. This is distinct from the multi-item case immediately above, which still falls through to case 4 since board files genuinely are changing there.
     4. Otherwise — no argument, no sender context, and staged board files span more than one distinct story or epic — fall back to unscoped `/reconcile` (full board), unchanged from prior behavior.
   - **Invoke** `/reconcile <scope>` when a scope was determined in cases 1-3, unscoped `/reconcile` on the case-4 fallback, or skip the reconcile step entirely per case 3's no-board-files-staged outcome. Do not re-derive or duplicate `/reconcile`'s own default-scope-to-epic expansion here — passing a bare story or task id through is sufficient; `/reconcile` itself resolves that to the containing epic.
   - **If `/reconcile` was skipped** (case 3's no-board-files-staged outcome) — continue silently to the next step, exactly as the no-drift outcome below.
   - **If reconcile detects and corrects drift** — inform the user what changed (e.g. demoted/promoted statuses, merged orphaned worktrees, cleaned `todo.md` entries) before proceeding.
   - **If reconcile finds no drift** — continue silently to the next step.

2. **Doc-sync scan, scoped to this change (report-only, non-blocking)** — Invoke `/doc-sync` scoped via its `source:` argument to the files actually changed by the work being committed — never a full-repo scan. Determine the changed-file list from the work being committed (e.g. `git diff --name-only HEAD` combined with untracked files from `git status --porcelain`, or the task's known changed-file set when commit context already identifies them) and pass it as `source:` so doc-sync only analyses what this commit touches.
   - **Design decision — report-only, not blocking:** doc-sync's own step 5 ("report findings, ask before applying") is a human-approval gate. When invoked from `/commit`, doc-sync runs only through its own step 5 (report the drift findings) and explicitly does **not** proceed to its step 6 (apply updates) as part of this flow — `/commit` never surfaces doc-sync's apply-confirmation prompt mid-commit. *Rationale: nesting a second approval gate inside an already-in-flight commit either stalls a flow the user expected to complete in one shot, or trains the user to reflexively decline the nested prompt just to get their commit through. Report-only surfaces documentation drift at the cheapest possible moment to notice it — right when the change is fresh — without forcing an apply/skip decision under commit pressure; the user reviews the findings and runs `/doc-sync` standalone afterward if they want to apply them.* This introduces no change to `/doc-sync`'s own step 5 approval semantics and no new auto-apply flag — `/commit` simply never invites it past step 5.
   - **If doc-sync reports drift findings** — surface them to the user as part of the commit output (informational), then continue to the next step regardless of the findings.
   - **If doc-sync reports no drift** — continue silently to the next step.

3. **Verify user-action prerequisites** — Check whether an `_INSTRUCTIONS.md` file exists for this task at `project/instructions/<E##_S##_T##>_INSTRUCTIONS.md`. If the task has out-of-scope prerequisites but no instructions file was created, create one now using `assets/user_instructions_template.md`. If one already exists, surface it to the user as a reminder. (The developer should have created this file during task intake — this is a final safety check.)

4. **Commit** using the following format:
   - **Epic:** `epic(<Epic Title>): <MAX_50_CHAR_SUMMARY>`
   - **Task/Story:** `story(<Epic Title>_<Story Title>): <MAX_50_CHAR_SUMMARY>`
   
   **Fallback: Group changes logically** — prefer one commit per coherent unit of work, but don't force splits. When in doubt, keep it together.

5. **Check for next epic** — If a new epic is to be started, inform the user that a new conversation should be initiated. If there are no subsequent epics left, show the message: "All Done! 🎉"
