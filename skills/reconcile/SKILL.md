---
name: reconcile
description: Reconcile the scrum board with actual implementation state. Cross-checks every task's board status against git history and worktrees, merges orphaned worktree branches, demotes unimplemented "Done" items, promotes secretly-implemented items, flags code with no board provenance and offers /uncharted segment for it, and cleans stale entries from todo.md. Use when the board feels out of sync, after a big merge session, when tasks were completed outside the normal workflow, or when todo.md has grown stale. Trigger on phrases like "sync the board", "clean up the board", "reconcile", "board is out of date", "todo is stale", or "check what's really done".
metadata:
  prefered_agent: scrum-master
---

# Reconcile — Board ↔ Code Synchronisation

Walks the full board (epics → stories → tasks), verifies each item's status against what actually exists in git, and fixes any drift. Also cleans `project/todo.md` of entries that are already done. Then runs the same check in reverse — code that exists with no board item and no EST-tagged commit behind it — and offers `/uncharted segment` for what it finds.

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

### 5. Detect unlinked code (no board provenance)
Phases 2 and 3 ask "does this board item exist in the code?". This phase asks the inverse —
**"does this code exist on the board?"** — and finds paths with no Jenga provenance at all.

Run:

```bash
skills/reconcile/scripts/detect-unlinked-code.sh
```

It emits a single JSON object and exits `0` whether or not it finds anything; read
`summary.uncharted_paths` rather than branching on the exit status. All the deterministic work —
exclusions, the board check, the commit check, grouping — is in the script. Everything below is
judgement and presentation.

A path is reported as unlinked only when **both** provenance signals are absent: no board file
references it, **and** no commit naming a board item added it. Either signal alone is provenance,
so a file created by a `task(...)` commit is not reported even if no board file names it by path.
Signal B accepts the current EST tags (`epic(...)`, `story(...)`, `task(E##_S##_T##)`) and the two
older conventions still present in this repo's history (`E04_S01: ...` and
`feat(train): implement E01_S05 - ...`).

The script reuses the board-linkage check from
`skills/uncharted/scripts/resolve-segment-target.sh` through its batch interface. Do not
re-derive linkage yourself, and do not substitute a `grep` over `project/board/` if the script
fails — a second answer to "is this path on the board" is what that reuse exists to prevent.
If the script exits non-zero, report the failure in the reconcile report and continue to phase 6.

#### Reading the result

- **`groups[]`** — the actionable findings, sorted by `unlinked_count` descending. Each entry is
  a directory, not a file, because the useful unit for `/uncharted segment` is a directory or
  feature. Every group directory has itself been checked against the board, so these are
  directories with no provenance of their own either. `fully_unlinked: true` means *every*
  candidate file beneath the directory is unlinked — those are the strongest segment candidates
  and should be offered first. When `false`, the directory holds a mix and only the listed files
  are unlinked.
- **`covered_groups[]`** — files with no provenance of their own that nonetheless sit under a
  directory the board *does* reference (`directory_linkage.status: "linked"`, with the owning
  board items in `directory_linkage.items` and the spelling that matched in `matched_as`).
  **Do not offer `/uncharted segment` for these** — the board already owns that directory and a
  segment run would duplicate existing items. Mention them in the report as a one-line count so
  the information is not lost, and move on.
- **`files`** is capped by `--limit` (default 10); `files_truncated` gives the remainder. The
  counts are always true totals, so never re-count `files` to report a number.
- **`not_checked[]`** — **this is a third state, not a quiet synonym for unlinked.** It means the
  linkage question could not be answered for that path (it is outside the repository, it is the
  repo root, there is no board directory, or it is a stale index entry that no longer exists on
  disk). Report these under their own heading with the `reason` shown, and:
  - **never** describe them as unlinked or add them to the unlinked totals;
  - **never** include them in the `/uncharted segment` offer.

  A group whose `directory_linkage.status` is `not_checked` is a different case: its *files* were
  checked and are genuinely unlinked, only the directory verdict is missing. Keep offering it, but
  say the directory itself could not be verified.

  Saying "no board item references this" about a path we never managed to check is a false
  claim of a verified absence. If a `not_checked` entry looks like it matters, the follow-up is
  to investigate that path directly, not to assume the worst about it.
- **`notices[]`** — surface verbatim in the report if non-empty.

#### The `/uncharted segment` offer

Drive this off **`summary.uncharted_paths`** and `groups[]`, not `unlinked_paths` —
`unlinked_paths` includes the covered files, which must never be offered.
(`unlinked_paths` == `uncharted_paths` + `covered_paths`.)

If `summary.uncharted_paths` is `0`, note "no unlinked code found" in the report and continue to
phase 6. Otherwise present the top groups and offer `/uncharted segment`, using the numbered
form from `CLAUDE.md`'s Interaction Pattern with the free-text option last:

```
Found <N> path(s) with no board provenance, in <M> director(y|ies):

  1. <directory>  — <unlinked_count> file(s)<, entire directory if fully_unlinked>
  2. <directory>  — <unlinked_count> file(s)
  ...

Neither these files nor their directories are referenced by any board item, and no commit
naming a board item introduced them. How would you like to handle it?
1. Run `/uncharted segment <directory>` on <top group> now
2. Choose a different group to run `/uncharted segment` on
3. Skip for now — carry on with the rest of the reconcile pass
4. Other (describe below)
```

List at most the top 10 groups; if there are more, say how many were not shown.

**This offer is non-blocking.** Declining it — option 3, an unrecognised answer, or no answer at
all — changes nothing about the rest of the reconcile run. Record the finding in the report and
**continue to phase 6 regardless**. Detection is report-only in the same way DoD gap detection
is: never change a board status, create a board item, or modify any file on the strength of this
phase. If the user picks option 1 or 2, finish the reconcile pass first, then hand off to
`/uncharted segment` at the end so the board is consistent before new items are written.

### 6. Clean `project/todo.md`
Walk the todo entries parsed in phase 1:

- **Already-done entries** — if an entry references a task/story/epic whose pre-reconcile status (from the snapshot in phase 1) was already a completed status **and** whose implementation has been confirmed (phase 2), **remove the line entirely** from `project/todo.md`.
- **Newly-reconciled entries** — entries that were commented out in phase 3 stay as `<!-- RECONCILED: ... -->`.
- If `project/todo.md` is left with only the header, the format comment, and blank lines, delete the file.

### 7. Print a summary
Output a reconciliation report using the format in `assets/report_format.md`, with one
additional section from phase 5 placed just before `TODO CLEANUP`:

```
🗺️  UNLINKED CODE (no board item for the files or their directory)
   📁 <directory>  — <N> file(s)  [entire directory]
   📁 <directory>  — <N> file(s)
   Offered `/uncharted segment`: <accepted for <directory> | declined>
   Covered: <N> file(s) in <M> director(y|ies) already owned by a board item — not offered

❓ NOT CHECKED (board linkage could not be determined — not a finding of unlinked)
   <path>  — <reason>
```

Omit `UNLINKED CODE` when `summary.uncharted_paths` is 0, omit its `Covered:` line when
`summary.covered_paths` is 0, and omit `NOT CHECKED` when
`not_checked[]` is empty. Keep the two separate: merging them would report paths as unlinked
that were never actually checked.

If no changes were made, print: `Board and todo.md are in sync — nothing to reconcile. ✅`
