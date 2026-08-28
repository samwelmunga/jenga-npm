---
name: jenga
description: Interactive-by-default board orchestrator with a fully automated escape hatch. Bare `/jenga` renders a picker and confirmation tree before scoping the run; `/jenga <ids>` resolves an explicit fuzzy-ID scope and confirms it; `/jenga *` reproduces the original zero-prompt behavior — decomposing any unbroken Epics into Stories, any unbroken Stories into Tasks, queuing all unqueued Tasks into todo.md, then executing every eligible item with no user prompts — until the board is fully started.
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

`/jenga` is interactive by default — it never silently commits to the whole board without showing the user what it's about to run and letting them scope or edit that selection first. It has three entry modes:

- **Bare `/jenga`** (no argument) — renders a numbered picker of the full board, then an editable confirmation tree, before anything executes.
- **`/jenga <ids>`** (explicit comma-separated scope) — resolves the given IDs via the fuzzy-ID grammar, skipping the picker, then still shows the same editable confirmation tree before executing.
- **`/jenga *`** (literal wildcard) — the explicit escape hatch. Skips both the picker and the confirmation step entirely and reproduces the original hands-free "commit to everything on the board" pipeline: the entire board is fully decomposed, fully queued, and fully executing — without any user interaction, no user prompts. This is the only path where `/jenga` runs with no user prompts at all.

Once a run's scope is established (by confirmation, or unconditionally under `*`), `/jenga` runs the same underlying phases against that scope: **entry mode resolution → decompose → queue → execute → loop**.

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

### Phase 0.5 — Pre-flight Validation

Before accepting any task for decomposition or execution, the executing agent must validate the task's scope fields. The threshold values loaded in Phase 0 may be referenced in error messages for context, but are not required for the core validation rules below.

For each task read from the board, apply the following checks in order:

#### Rule 1 — Valid execution_scope value

If the task frontmatter contains an `execution_scope` field, its value must be one of: `task`, `story`, `epic`, `inline`.

If the value is anything else, halt immediately with:

```
VALIDATION ERROR [<task_id>]: execution_scope "<value>" is not a valid scope. Allowed: task, story, epic, inline.
```

Do not proceed with this task.

#### Rule 2 — scope_rationale must contain a measurable claim

If `execution_scope` is present, `scope_rationale` must also be present and must contain at least one digit (0–9) or the word "file" (case-insensitive).

If `scope_rationale` is absent, or present but contains no digit and does not contain the word "file", halt with:

```
VALIDATION ERROR [<task_id>]: scope_rationale is missing or lacks a numeric/file-count claim. Provide a rationale that includes a digit (e.g. "touches 2 files") or the word "file".
```

Do not proceed with this task.

#### Rule 3 — epic scope requires explicit human approval

If `execution_scope` is `"epic"`, the task must also have `epic_scope_approval: true` set explicitly in its frontmatter. A missing `epic_scope_approval` field and a value of `false` are both rejection conditions.

If `epic_scope_approval` is absent or is not exactly `true`, halt with:

```
VALIDATION ERROR [<task_id>]: execution_scope=epic requires epic_scope_approval: true (set by human operator). This field must be added manually — it is never assigned autonomously.
```

Do not proceed with this task.

#### Rule 4 — crucial_level: locked forces execution_scope: inline

If the task frontmatter contains `crucial_level: locked` (per `templates/SCRUM_BOARD_SCHEMA.md`'s Crucial Flag Fields), `execution_scope` for that task MUST be `inline` — only the current foreground/inline session can pause mid-run for a live confirmation; a backgrounded subagent has no live channel back to the user.

This rule **auto-corrects and continues**; unlike Rules 1-3, it never halts.

- If `execution_scope` is present and its value is anything other than `inline`, correct it to `inline` directly in the task file, and record a logged note of the correction by appending to that task's `override_justification` frontmatter field (the auditable mechanism for this rule — do not use `events.json` or any other location) a line of the form:

  ```
  override_justification: "Rule 4 auto-correction <date>: execution_scope forced from '<previous_value>' to 'inline' because crucial_level: locked."
  ```

  Then emit (non-fatally — do not halt):

  ```
  AUTO-CORRECTION [<task_id>]: crucial_level=locked requires execution_scope=inline; corrected from "<previous_value>" to "inline".
  ```

- If `execution_scope` is absent entirely, set it to `inline` directly in the task frontmatter. Do **not** fall through to the Backward-compatibility default of `execution_scope: task` documented immediately below — a `locked` item overrides that default even when no other execution-scope fields are present. No `override_justification` note is required in this case, since there is no prior value being overridden.

Proceed to the next rule (or the next phase, if this was the last applicable rule) after applying the correction.

#### Backward compatibility — legacy tasks

If the task frontmatter contains **none** of `execution_scope`, `scope_rationale`, `needs_docs`, `jenga_assigned`, or `override_justification`, treat the task as a legacy task:

- Assume `execution_scope: task`
- Assume `needs_docs: true`
- Skip all three rules above and proceed without error.

#### Validation success

If all applicable rules pass (or the task is a legacy task), proceed to the next phase for that task without any error output.

---

### Phase 0.75 — Entry Mode Resolution

This phase determines **how `/jenga` was invoked** and, for two of the three entry modes, produces a **scoped set** — a confirmed list of board IDs (epics/stories/tasks) that Phases 1-4 must restrict themselves to. All board scanning, ID parsing, cascade expansion, and rendering used by this phase already live in `skills/jenga/scripts/` per this repo's "Scripts Over Inline Logic" principle — this phase never re-implements any of that logic inline. The executing agent's job here is limited to: invoking the right script with the right arguments, relaying its STDOUT verbatim to the user when the contract calls for that, capturing the `STATE_FILE:` line from STDERR for the next turn, and forwarding the user's raw reply back into the next invocation unmodified.

**Determine the invocation form** from the raw argument (if any) passed to `/jenga`:

- No argument at all → **bare branch**.
- The argument is the literal string `*` → **wildcard branch**.
- Any other non-empty argument → **scoped branch** (treat the whole argument as the comma-separated raw ID list).

#### Wildcard branch (`/jenga *`)

Skip both the picker and the confirmation step entirely. There is no scoped set — proceed to Phase 1 unrestricted, exactly as `/jenga` behaved before this phase existed.

#### Bare branch (`/jenga`)

1. Invoke `skills/jenga/scripts/render-picker.sh` with no arguments (start mode). Relay its STDOUT (the numbered checklist) to the user verbatim — no summarizing, no reformatting. Capture the `STATE_FILE:` path from STDERR.
2. Wait for the user's chat reply, then invoke `skills/jenga/scripts/render-picker.sh <state_file> "<raw_reply>"` (continue mode).
   - **Error turn** (plain text on STDOUT, state file retained) — relay verbatim and return to step 2 for another reply.
   - **Cancellation** — relay the cancellation acknowledgement and halt the entire `/jenga` run; do not proceed to any later phase.
   - **Resolved** (JSON object on STDOUT, state file removed) — extract `resolved_ids_csv` and continue to the shared confirmation step below.

#### Scoped branch (`/jenga <ids>`)

1. Invoke `skills/jenga/scripts/resolve-id.sh "<raw argument>"` directly — the picker is skipped entirely in this branch.
2. Parse the JSON array response, one object per comma-delimited input segment.
   - If **every** segment has `status: "resolved"`, collect their `resolved_id` values into a comma-separated list and continue to the shared confirmation step below.
   - If **any** segment has `status: "rejected"`, halt this phase (do not proceed to confirmation or Phase 1) and report each rejected segment's `input` and `reason` to the user verbatim, per `resolve-id.sh`'s own contract — a partial or ambiguous ID is never guessed. The user must re-invoke `/jenga <ids>` with corrected input.

#### Shared confirmation step (bare and scoped branches only)

1. Invoke `skills/jenga/scripts/render-confirmation.sh "<comma-separated resolved ids from whichever branch above>"` (start mode). Relay STDOUT (the confirmation tree) to the user verbatim. Capture the `STATE_FILE:` path from STDERR.
2. Wait for the user's chat reply, then invoke `skills/jenga/scripts/render-confirmation.sh <state_file> "<raw_reply>"` (continue mode).
   - **Toggle or error turn** (plain text on STDOUT, state file retained) — relay verbatim and return to step 2 for another reply.
   - **Cancellation** — relay the cancellation acknowledgement and halt the entire `/jenga` run; do not proceed to any later phase.
   - **Confirmed** (JSON object on STDOUT, state file removed) — this is the final **scoped set**. Take `resolved_ids` (or `resolved_ids_csv`) as the exact set of board IDs Phases 1-4 restrict themselves to for the rest of this run.
3. **Handoff to cascade resolution** — do not invoke `cascade-resolve.sh` again here. `render-confirmation.sh` already invoked it internally to build the tree, and the CONFIRMED JSON's own `undecomposed` field is that same result already scoped down to the checked-only set. Use that `undecomposed` field directly to identify which epics/stories in the scoped set still need Phase 1/2 decomposition.

After this phase completes (bare and scoped branches via confirmation, wildcard branch immediately), proceed to Phase 1.

---

### Phase 1 — Decompose Epics into Stories

If Phase 0.75 produced a scoped set, restrict this phase to epics that are members of that set (directly selected, or flagged in its `undecomposed` list). Under `/jenga *`, this phase is unrestricted, exactly as before.

Read all files in `project/board/epics/`. For each in-scope Epic that has no corresponding story files in `project/board/stories/` (i.e. no files whose name starts with that Epic's ID), invoke `/do` via a **scrum-master sub-agent** to break it down into Stories.

Repeat until every in-scope Epic has at least one Story on the board.

### Phase 2 — Decompose Stories into Tasks

If Phase 0.75 produced a scoped set, restrict this phase to stories that are members of that set (directly selected, expanded from an in-scope epic, or flagged in its `undecomposed` list). Under `/jenga *`, this phase is unrestricted, exactly as before.

Read all files in `project/board/stories/`. For each in-scope Story that has no corresponding task files in `project/board/tasks/` (i.e. no files whose name starts with that Story's ID), invoke `/do` via a **scrum-master sub-agent** to break it down into Tasks.

Repeat until every in-scope Story has at least one Task on the board.

### Phase 3 — Queue all Tasks into `todo.md`

If Phase 0.75 produced a scoped set, restrict this phase to tasks that are members of that set (directly selected, or expanded from an in-scope epic/story). Under `/jenga *`, this phase is unrestricted, exactly as before.

Read all files in `project/board/tasks/`. For every in-scope Task not already listed in `project/todo.md`, append its ID (and title as a comment) to `project/todo.md`.

After this phase, `todo.md` reflects the full set of in-scope work (or the full board, under `*`).

### Phase 3.5 — Story-bundle detection

Before dispatching individual tasks in Phase 4, check each story for bundle eligibility. This phase runs once after Phase 3 completes.

If Phase 0.75 produced a scoped set, restrict this phase to stories that are members of that set (directly selected, or expanded from an in-scope epic) — a story with tasks sitting in `todo.md` from an earlier, differently-scoped run but that is **not** a member of the current run's scoped set is skipped entirely by this phase (not considered for bundling, and not dispatched via the bundle path) so that Phase 4's own scoped-set exclusion is never bypassed by a bundle call issued here. Under `/jenga *`, this phase is unrestricted, exactly as before.

For each in-scope story that has one or more tasks listed in `todo.md`:

1. **Read the story file** — parse the `tasks:` frontmatter array to get the ordered list of task IDs.
2. **Guard: empty task list** — if the `tasks:` list is empty (zero entries), this story is **not** eligible for the bundle path. Skip to per-task dispatch in Phase 4.
3. **Read each task file** — for every task ID in the `tasks:` list, read the corresponding task file from `project/board/tasks/`.
4. **Collect `execution_scope`** — extract the `execution_scope` field from each task's YAML frontmatter. If the field is absent or has any value other than `story`, treat that task as **not** story-scoped.
5. **Guard: locked-task disqualifier (defense-in-depth)** — for each task file already read in step 3, also read `crucial_level` (per `templates/SCRUM_BOARD_SCHEMA.md`'s Crucial Flag Fields). If **any** task in the story's `tasks:` list has `crucial_level: locked`, this story is **not** eligible for the bundle path — skip to per-task dispatch in Phase 4 for this story, **regardless of that task's `execution_scope` value**, even if it already reads `inline`. This check is defense-in-depth alongside Phase 0.5's Rule 4 (which forces a locked task's own `execution_scope` to `inline` when Rule 4 processes it): it exists for the race window where Rule 4 hasn't (yet) corrected the task — e.g. the task was added to the story's `tasks:` list after Rule 4 last ran, or the file was edited by hand after validation. It is not a replacement for Rule 4.
6. **Apply the all-or-nothing rule** — a story qualifies for the bundle path **only if every task** in its `tasks:` list has `execution_scope: story`. A single task with a different scope (or a missing field) disqualifies the entire story.
7. **Route bundle candidates** — if all tasks in the story are `execution_scope: story` and the list is non-empty:
   a. Emit:
      ```
      BUNDLE DETECTED: story <E##_S##> — <N> story-scoped tasks will execute as a bundle.
      ```
      where `<E##_S##>` is the story ID and `<N>` is the count of tasks in the list.
   b. Call `/do <E##_S##>` once (with the story ID, not individual task IDs). This invokes the bundle execution path in `/do` (implemented in E32_S05_T02), which runs all tasks sequentially in one shared worktree.
   c. **Mark these tasks as bundled** — record their task IDs so Phase 4 skips individual dispatch for them.
8. **Non-bundle stories** — stories with a mixed scope, a zero-length task list, any task missing `execution_scope: story`, or any task with `crucial_level: locked` (step 5) use the normal per-task dispatch in Phase 4 without any change.

### Phase 4 — Execute

Loop through `todo.md` and execute all eligible items, running independent ones in parallel. Use the threshold values loaded in Phase 0 (`inline_max_files`, `inline_max_lines`, `story_max_files`, `bundle_lock_ttl_minutes`) when applying execution-scope logic to each task. **Skip any task that was bundled in Phase 3.5** — those tasks will be handled by the `/do` story-bundle call already issued.

1. **Collect eligible items** — from `todo.md`, find all items whose board file has `status: Pending` and no unresolved dependencies, **excluding tasks already dispatched as part of a story bundle in Phase 3.5**. If Phase 0.75 produced a scoped set, also exclude any item not a member of that set — execution never runs outside the confirmed/resolved scope. Under `/jenga *`, no such exclusion applies. A dependency is resolved if the blocking item's status is at least `In Progress` or `Passed`.
2. **Group by parallelism** — items with no shared dependencies and no overlapping output files can run concurrently. Items that depend on each other must be sequenced.
3. **Invoke `/do` in parallel** — launch each independent item as a **background sub-agent** simultaneously. Do not wait for one to finish before starting another if they are independent.
4. **Mark In Progress** — update `status: In Progress` in each launched item's board file (YAML front-matter) immediately after launch.
5. **Wait, drain, and loop** — once all active background agents in the wave have completed:
   a. **Drain the scrum triggers queue** — invoke the `## Drain Scrum Triggers Queue` procedure from `agents/scrum-master.md` against `project/queue/scrum_triggers.jsonl`. `/jenga`'s orchestrating agent is the scrum-master, and this is the same session-start procedure applied mid-run: process any `rapport_review`, `status_review`, and `story_rollup` triggers written by the tester sub-sessions that just completed, then clear the file. This ensures rollups become visible on the board (story/epic status updates) before the next wave is collected, instead of sitting unprocessed until some future scrum-master session start.
   b. **Return to step 1** of this phase to pick up any newly unblocked items — including items unblocked by the rollups just processed in (a).

### Exit condition

When no eligible candidates remain in Phase 4, exit and output:

```
✅ Jenga complete. All eligible tasks have been started.
```

## Edge Cases

- **Epic with no stories after breakdown** — log a warning and continue to the next Epic; do not block the pipeline.
- **Story with no tasks after breakdown** — log a warning and continue to the next Story.
- **Task already in `todo.md`** — skip; do not duplicate.
- **All tasks in `todo.md` already In Progress/Passed** — exits cleanly with the completion message.
- **Unresolved dependencies** — item is skipped in Phase 4 until its blockers are at least `In Progress`.
- **`/do` failure (background agent)** — treated as a skip; mark the item's status back to `Pending` and continue the loop with remaining candidates.
- **Story with zero tasks (empty `tasks:` list)** — does not enter the bundle path in Phase 3.5; tasks (if any appear in `todo.md` independently) are dispatched normally in Phase 4.
- **Story with mixed `execution_scope` values** — falls back entirely to per-task dispatch in Phase 4; no partial bundling occurs.
- **Task file missing `execution_scope` field** — treated as not story-scoped; the containing story is disqualified from the bundle path.
- **Story containing a `crucial_level: locked` task** — disqualified from the bundle path at Phase 3.5 step 5, independent of that task's `execution_scope`; falls back to per-task dispatch in Phase 4, where `/do` Section 4.2's locked-task dispatch guard (E39_S03_T04) provides the second enforcement layer before any worktree or subagent is created.
- **Bundle `/do` call failure** — treated as a skip for the entire bundle; mark all bundled tasks' status back to `Pending` and continue Phase 4 with remaining non-bundled candidates.
- **Picker cancelled (bare branch)** — the entire `/jenga` run halts immediately after relaying the cancellation acknowledgement; no phase past 0.75 runs, and nothing on the board is modified.
- **Confirmation cancelled (bare or scoped branch)** — same as picker cancellation: the entire `/jenga` run halts immediately; no scoped set is produced and no later phase runs.
- **`resolve-id.sh` rejects one or more segments (scoped branch)** — the whole invocation halts at Phase 0.75 with the rejected segments' reasons reported verbatim; no partial scope is assembled from the segments that did resolve, and no fallback guess is made for the rejected ones. The user must re-invoke `/jenga <ids>` with corrected input.
- **`/jenga *` (wildcard branch)** — never produces a scoped set; Phases 1-4 run fully unrestricted over the entire board, identical to `/jenga`'s behavior before Phase 0.75 existed.
- **Stale out-of-scope story queued in `todo.md` from an earlier run (scoped run only)** — Phase 3.5's scoped-set guard skips it entirely (not considered for bundling), so it cannot be dispatched via a bundle `/do <E##_S##>` call that would otherwise bypass Phase 4's own scoped-set exclusion; it remains untouched in `todo.md` until a future run's scope includes it.
