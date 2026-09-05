---
name: j:do
description: Polyfill alias of the do skill under a collision-safe directory name. Identical behavior to /do — Execute tasks from the scrum board. Reads from project/todo.md, resolves each entry to its full scrum board context, and drives the developer agent through implementation with the correct sender object and communication contract. Loops until all selected tasks are done or the user exits. Use when the bare /do form is shadowed by another tool's own built-in command of the same name.
keywords:
  - do
  - execute
  - implement
  - work on
  - build
  - j-do
  - polyfill
examples:
  - "implement the login feature"
  - "work on the API endpoint"
  - "j-do"
metadata: 
  prefered_agent: developer
---

# Do — Execute Scrum Board Tasks

This skill is a literal-directory-name duplicate of `skills/do/`. It exists so that `/j-do` (and `j:j-do`) give a guaranteed-unshadowed way to reach the same flow as `/do`, even if a host tool's own built-in command of the same name would otherwise shadow or override the bare `/do` alias (Claude Code's native skill resolution is a literal-string, directory-name-based match — see `docs/skill-authoring.md`'s "Invocation Convention").

This file is generated/synced by `scripts/generate-j-alias.sh do` from `skills/do/SKILL.md` — do not hand-edit it; re-run the generator instead to pick up source changes.

## `--trivial` Flag

**Syntax:** `/do <id> --trivial` — a dispatch-time override, distinct from `/todo --trivial` (a creation-time flag documented in `skills/todo/SKILL.md`). Where `/todo --trivial` writes a brand-new task straight to `execution_scope: inline`, `/do <id> --trivial` overrides an **already-existing** task's `execution_scope` — whatever it currently is, including absent (legacy tasks with no execution-scope fields at all) — to `inline` at the moment it's dispatched. See `### 4.1.5. \`--trivial\` Dispatch-Time Override` below for the full mechanics.

**No softer fallback tier — hard fallback to the full pipeline instead.** Unlike `light` scope (which sits between `inline` and `task`), `--trivial` always forces `inline` directly, with no intermediate tier to fall back to first. To compensate, a `--trivial`-forced run that fails `scripts/smoke-harness.sh` or shows detected scope creep mid-run automatically re-routes to the full `task` pipeline (worktree + developer + tester) via the same `#### Fallback to Full Task-Scope Pipeline` procedure the `light`-tier fallback uses — see `### 4.2`'s failure-handling branches and the shared Fallback subsection under `### 4.3`.

**Human-only, same as `/todo --trivial`.** `--trivial` is invoked by a human typing `/do <id> --trivial` — it is never applied autonomously by `/jenga` or the scrum-master's own breakdown/dispatch passes.

## Instructions

### 0. Load threshold config

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

### 1. Check for `project/todo.md`
Run `bash scripts/todo_manager.sh exists`. If it exits non-zero, inform the user there are no queued tasks and exit.

### 1.5. Story-Bundle Execution Mode

When `/do` is invoked with a story ID (e.g., `/do E##_S##`), skip steps 2–4 and enter story-bundle execution mode:

1. **Read the story file** from `project/board/stories/<E##_S##>_*.md`. Extract the `tasks:` list. If the story file does not exist, emit:
   ```
   ERROR: Story file for <story_id> not found. Cannot execute bundle.
   ```
   and halt.

#### Epic-Level Bundle Lock

Before proceeding, acquire the epic-level sequential lock for this bundle:

a. **Derive the lock file path**: `project/queue/epic-lock-<E##>.json` where `<E##>` is the epic ID extracted from the story ID.

b. **Check for an existing lock**:
   - If `project/queue/epic-lock-<E##>.json` exists:
     1. Parse the JSON and read the `started_at` field (ISO 8601 UTC timestamp).
     2. Compute the lock age: `age_minutes = (now_utc - started_at) / 60`.
     3. Read `bundle_lock_ttl_minutes` from `project/configs/scope-thresholds.json` (already loaded in step 0).
     4. If `age_minutes < bundle_lock_ttl_minutes` (lock is **non-stale**), emit:
        ```
        BLOCKED: Epic <E##> already has a running bundle (<bundle_story_id>, started <started_at>). Wait for it to complete or for the TTL to expire.
        ```
        and **halt** — do not proceed with this bundle.
     5. If `age_minutes >= bundle_lock_ttl_minutes` (lock is **stale**), delete it with `rm -f project/queue/epic-lock-<E##>.json` and continue to the write step below.
   - If `project/queue/epic-lock-<E##>.json` does not exist, continue to the write step below.

c. **Write the lock atomically**:
   1. Compose the lock JSON:
      ```json
      {
        "epic_id": "<E##>",
        "bundle_story_id": "<E##_S##>",
        "started_at": "<current ISO 8601 UTC timestamp>"
      }
      ```
   2. Write this JSON to `project/queue/epic-lock-<E##>.json.tmp` (temporary file in the same directory).
   3. Rename (move) `project/queue/epic-lock-<E##>.json.tmp` to `project/queue/epic-lock-<E##>.json`. This rename is atomic on POSIX filesystems and prevents any observer from reading a partially-written lock file.

> **Note:** Each epic has its own lock file keyed by `<E##>`. Bundles belonging to different epics have separate lock files and do not block each other.

> **Cleanup contract:** The epic lock file **must** be deleted on every exit path — success, failure, and interruption. Register a cleanup/trap handler immediately after writing the lock so that the lock is released even if the skill is interrupted mid-execution (e.g., `trap 'rm -f project/queue/epic-lock-<E##>.json' EXIT` in a shell implementation, or equivalent in other runtimes). Deleting a non-existent lock file must be idempotent — always use `rm -f` (never `rm` alone).

#### Pre-execution cross-bundle conflict check

After acquiring the epic lock and before writing the bundle manifest, scan all other active bundle manifests to detect file-level overlap with the current bundle:

1. **Glob other bundle manifests**: list all files matching `project/queue/bundle-*.json`. Exclude the current bundle's own file (`project/queue/bundle-<E##_S##>.json` — it does not exist yet at this point, so no special filter is needed; simply exclude any path whose basename equals `bundle-<E##_S##>.json`).

2. **If no other manifests exist**: skip steps 3–6 entirely — this step completes silently.

3. **For each other manifest file found**:
   a. Parse the JSON and read its `task_changed_files` map.
   b. Collect the union of all file-path arrays across every key in `task_changed_files` into a flat, deduplicated set called `other_touched_files`.
   c. Record the other bundle's `story_id` (or derive it from the filename: `bundle-<story_id>.json`).

4. **Build the expected file set for the current bundle** (`current_expected_files`):
   For each task in the current bundle's `tasks:` list:
   a. Read the task file at `project/board/tasks/<task_id>_*.md`.
   b. Extract file paths from the task's `scope_rationale` frontmatter field and from the full text of the task's `## Description` section. A string is treated as a file path if it contains a forward-slash (`/`) or a dot-separated extension (e.g. `.md`, `.json`, `.sh`, `.ts`, `.js`, `.py`). Extract all such tokens.
   c. Add all extracted paths to `current_expected_files` (deduplicated set).

5. **Compute overlap**: for each other bundle scanned in step 3, compute the intersection of `other_touched_files` and `current_expected_files`.

6. **If any overlap is found**:
   a. Emit the following log line to the console (one line per conflicting bundle):
      ```
      [CROSS-BUNDLE CONFLICT] Bundle <current_story_id> and bundle <other_story_id> share expected files: <file1>, <file2>
      ```
   b. Store the conflict data in memory as `pending_conflicts`:
      ```json
      {
        "<other_story_id>": ["<file1>", "<file2>"]
      }
      ```
      If multiple other bundles each have overlap, accumulate all of them under their respective story IDs in `pending_conflicts`.

7. **Pass `pending_conflicts` forward**: when writing the bundle manifest in the next step (step 2 below), initialise the `cross_bundle_conflicts` key in the manifest with the contents of `pending_conflicts` (or `{}` if no conflicts were found). See "### Bundle Manifest and Rollback Anchor" for the updated manifest structure.

> **This check is non-blocking.** Regardless of whether conflicts are found, execution always continues to step 2. The conflict data is recorded for later review only.

2. **Invoke rollback anchor**: write a bundle manifest at `project/queue/bundle-<E##_S##>.json` before the first task executes. See "### Bundle Manifest and Rollback Anchor" below for the full procedure.

3. **Spawn one developer subagent** in one shared worktree named `bundle-<E##_S##>`. This is the only developer subagent for the entire story bundle — do not spawn additional subagents per task.

4. **Execute tasks sequentially** in `tasks:` list order, within the same shared developer subagent context:

   For each task in the `tasks:` list:

   a. **Before the task begins** — write `status: In Progress` and `date_started: <today>` to the task's frontmatter using the file-locking protocol:
      1. Locate the task file: `project/board/tasks/<task_id>_*.md`.
      2. Check for an existing lock file at `project/board/tasks/<task_id>_*.md.lock`. If it exists and is less than 60 seconds old, wait 10 seconds and retry once. If still locked after the retry, log a warning and skip this status write (do not block task execution).
      3. Create the lock file: write the current ISO 8601 timestamp into `project/board/tasks/<task_id>_*.md.lock`.
      4. Update the task frontmatter fields `status: In Progress` and `date_started: <YYYY-MM-DD>` (today's date).
      5. Delete the lock file immediately after the write completes (before step b).

   b. **Pass task context** to the shared developer subagent: task file content (title, description, acceptance criteria), parent story file, and parent epic file.

   c. **After successful task**: first run the **Intent-vs-Diff Check** (see `### 5.1. Intent-vs-Diff Check` below) for this task. Then write `status: Passed` and `date_completed: <today>` to the task's frontmatter using the file-locking protocol:
      1. Check for an existing lock file at `project/board/tasks/<task_id>_*.md.lock`. If it exists and is less than 60 seconds old, wait 10 seconds and retry once. If still locked, log a warning and skip this status write.
      2. Create the lock file: write the current ISO 8601 timestamp into `project/board/tasks/<task_id>_*.md.lock`.
      3. Update the task frontmatter fields `status: Passed` and `date_completed: <YYYY-MM-DD>` (today's date).
      4. Delete the lock file immediately after the write completes.
      > The lock must be released before proceeding to task N+1. Never hold a lock across task execution.

   c.1. **Post-task file extraction** — immediately after the status write in step c and before proceeding to the next task, record the files changed by this task into the bundle manifest:
      1. Run `git diff --name-only HEAD~1` to obtain the list of files changed by the just-completed task. Capture each line as a relative file path. If the command returns empty output (the task made no commits), treat the result as an empty array `[]` — this is not an error.
      2. Read the bundle manifest at `project/queue/bundle-<E##_S##>.json`.
      3. Add or update the key `task_changed_files` in the manifest object. Set `task_changed_files[<task_id>]` to the captured file list (an array of strings, or `[]` if no files changed). If `task_changed_files` does not yet exist in the manifest, create it as an empty object first.
      4. Write the updated manifest atomically:
         a. Serialise the updated manifest to JSON.
         b. Write the JSON to `project/queue/bundle-<E##_S##>.json.tmp`.
         c. Rename (move) `project/queue/bundle-<E##_S##>.json.tmp` to `project/queue/bundle-<E##_S##>.json`. The rename is atomic on POSIX filesystems and prevents any consumer from reading a partially-written file.
      > This step is mandatory before proceeding to task N+1. The extraction must complete (even if the file list is empty) before the next task begins.

   c.2. **Conflict report** — immediately after step c.1, compare the extracted file list against the files the task was expected to touch, and write a conflict report if unexpected files are found:

      1. **Extract expected files** from the task's frontmatter field `scope_rationale` and from the task's `## Description` section. Use a best-effort prose heuristic: split the text on whitespace and punctuation, then retain any token that either (a) contains a `/` character or (b) matches the pattern `*.*` (a dot surrounded by non-dot characters on both sides, e.g. `SKILL.md`, `foo.json`). Collect all retained tokens into a set called `expected_files`. This is intentionally permissive — false positives (expected files that were never actually changed) are acceptable and produce no report.

      2. **Compute unexpected files**: let `actual_files` = the array stored at `task_changed_files[<task_id>]` in the bundle manifest (from step c.1). Compute `unexpected = actual_files − expected_files` (set difference: files in `actual_files` that have no match in `expected_files`). Matching is case-sensitive and exact against the relative path or the basename of the path — a token like `SKILL.md` matches any actual file whose basename is `SKILL.md` (e.g. `skills/j-do/SKILL.md`).

      3. **If `unexpected` is non-empty**:
         a. Write a Markdown conflict report to `project/queue/conflict-<task_id>.md` with the following structure:
            ```markdown
            # Conflict Report: <task_id>

            **Generated:** <ISO 8601 UTC timestamp>
            **Bundle:** <E##_S##>

            ## Task ID
            <task_id>

            ## Expected Files
            Files inferred from scope_rationale and description:
            - <file1>
            - ...

            ## Actual Files Changed
            Files changed by this task (from git diff):
            - <file1>
            - ...

            ## Unexpected Files
            Files changed that were not anticipated by the task definition:
            - <file1>
            - ...
            ```
         b. Read the bundle manifest at `project/queue/bundle-<E##_S##>.json`.
         c. Append `<task_id>` to the `conflict_reports` array in the manifest. If the key `conflict_reports` does not yet exist, create it as an empty array first.
         d. Write the updated manifest atomically (tmp-file rename pattern — same as step c.1.4).

      4. **If `unexpected` is empty**: skip this step entirely. Do not write a conflict report. Do not modify the bundle manifest.

      > **This step is non-blocking.** A conflict report does NOT affect the task's `Passed` status or halt bundle execution. It is informational only — a human can review `project/queue/conflict-<task_id>.md` after the bundle completes.

   d. **After task failure** — write `status: Failed` to the task's frontmatter using the file-locking protocol:
      1. Check for an existing lock file at `project/board/tasks/<task_id>_*.md.lock`. If it exists and is less than 60 seconds old, wait 10 seconds and retry once. If still locked, log a warning and skip this status write.
      2. Create the lock file: write the current ISO 8601 timestamp into `project/board/tasks/<task_id>_*.md.lock`.
      3. Update the task frontmatter field `status: Failed`.
      4. Delete the lock file immediately after the write completes.
      Then invoke the rollback anchor cleanup procedure (see "### Bundle Manifest and Rollback Anchor" — failure path). After the rollback anchor completes, **release the epic lock**: run `rm -f project/queue/epic-lock-<E##>.json`. Mark the bundle as failed and **halt** — do not execute any remaining tasks in the sequence.

5. **Post-bundle verification** (runs only if all tasks completed without failure):
   - Inspect each task in the bundle for `needs_docs: true` in its frontmatter.
   - **If any task has `needs_docs: true`**: invoke the tester agent once for the full story. Pass the story ID, the list of all task IDs in the bundle, and the shared worktree path. The tester is responsible for updating individual task statuses.
   - **If all tasks have `needs_docs: false`**: the developer agent self-verifies — reviews each task's implementation against its acceptance criteria without invoking the tester. After self-verification passes, write `status: Passed` and `date_completed: <YYYY-MM-DD>` (today's date) to each task file using the file-locking protocol (steps c.1–c.4 above). No tester invocation occurs.

6. **Cleanup**: on successful bundle completion, invoke the rollback anchor success path (see "### Bundle Manifest and Rollback Anchor" — success path) to delete the bundle manifest. Then **release the epic lock**: run `rm -f project/queue/epic-lock-<E##>.json`.

### Bundle Manifest and Rollback Anchor

The bundle manifest records the repository state before any task in the bundle executes. It serves as the anchor for rollback on failure and as a reference for conflict reports (E32_S07) and concurrency locks (E32_S08).

#### Before the first task executes

1. Run `git rev-parse HEAD` to capture the current HEAD SHA as `anchor_sha`.
2. Write `project/queue/bundle-<E##_S##>.json` with the following structure:
   ```json
   {
     "story_id": "<E##_S##>",
     "anchor_sha": "<SHA from git rev-parse HEAD>",
     "started_at": "<ISO 8601 UTC timestamp>",
     "tasks": ["<E##_S##_T##>", "..."],
     "task_changed_files": {},
     "conflict_reports": [],
     "cross_bundle_conflicts": {}
   }
   ```
   - `story_id`: the story ID for this bundle (e.g. `E32_S05`)
   - `anchor_sha`: the full 40-character SHA returned by `git rev-parse HEAD`
   - `started_at`: current UTC timestamp in ISO 8601 format (e.g. `2026-08-16T12:00:00Z`)
   - `tasks`: ordered array of task IDs drawn from the story's `tasks:` frontmatter list
   - `task_changed_files`: starts as an empty object `{}`; populated after each task completes (see step 4c.1). Each key is a task ID and each value is an array of relative file paths changed by that task.
   - `conflict_reports`: starts as an empty array `[]`; populated after each task's step 4c.2 conflict check. Each entry is a task ID string for which a conflict report was written to `project/queue/conflict-<task_id>.md`.
   - `cross_bundle_conflicts`: populated from the pre-execution conflict check (see "Pre-execution cross-bundle conflict check" above). Each key is the `story_id` of a conflicting bundle and each value is an array of overlapping file paths. Initialised with the `pending_conflicts` data collected during the conflict check; if no conflicts were found, initialised as `{}`.

   Do not proceed to the first task until this file is written successfully.

#### On any task failure (failure path)

Execute the following steps in order. Do not skip any step.

1. **Save partial diff**: run `git diff <anchor_sha> HEAD` and write the output to `project/queue/bundle-<E##_S##>-partial.patch`. This captures all commits made since the anchor, providing a record of partial work for diagnosis.
2. **Verify clean worktree**: run `git status --porcelain`. If the output is non-empty, there are uncommitted changes that would cause `git reset --hard` to error or lose work. In this case, emit:
   ```
   ROLLBACK WARNING: worktree has uncommitted changes. Stashing before reset.
   ```
   Then run `git stash` before proceeding. This ensures the reset completes without git complaints.
3. **Reset to anchor**: run `git reset --hard <anchor_sha>`. The repository returns to the exact state it was in before the bundle started.
4. **Delete bundle manifest**: remove `project/queue/bundle-<E##_S##>.json`.

After completing the failure path, halt bundle execution. Do not execute any remaining tasks in the sequence.

#### On successful bundle completion (success path)

1. **Delete bundle manifest**: remove `project/queue/bundle-<E##_S##>.json`.

No patch file is written on success.

If `/do` is invoked with a task ID (`E##_S##_T##`) or a plain-text title, skip this section and use the normal task execution path (steps 2–8 below).

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

### 4.1. Override validation

Before invoking the developer, check whether this task was manually scoped by a human operator.

1. Read `jenga_assigned` from the resolved task's frontmatter.
2. If `jenga_assigned` is `true` or the field is absent — proceed to step 4.2 without any further check.
3. If `jenga_assigned` is `false`:
   a. Read `override_justification` from the task's frontmatter.
   b. If `override_justification` is absent or its value is an empty string, **halt execution** and emit:
      ```
      OVERRIDE VALIDATION ERROR [<task_id>]: jenga_assigned is false but override_justification is missing or empty. Add a justification before proceeding.
      ```
      Do not invoke the developer. Do not remove the task from `project/todo.md`. Return control to the user.
   c. If `override_justification` is present and non-empty, log:
      ```
      Override acknowledged for <task_id>: <override_justification>
      ```
      Then proceed to step 4.2.

### 4.1.5. `--trivial` Dispatch-Time Override

After override validation (step 4.1) and before branching on `execution_scope` in step 4.2, check whether this invocation was `/do <id> --trivial`.

1. **Detect the flag.** If the task was invoked as `/do <id>` with no `--trivial` flag, skip this entire section and proceed directly to `### 4.2`.

2. **If `--trivial` is present**, read the task's current `execution_scope` from frontmatter. Treat an absent value as `task`, per the epic's backward-compatibility rule (a task that omits `execution_scope` is treated as `execution_scope: task`). Call this the **prior tier** — this covers both tasks nobody flagged as trivial at creation (an already-assigned `story`/`task`/`light` tier) and legacy tasks with no `execution_scope` set at all.

3. **Overwrite `execution_scope` to `inline`** in the task's frontmatter, unconditionally — `--trivial` always forces `inline`, never a softer "lightest safe tier."

4. **Record the override for audit**, reusing the existing `jenga_assigned` / `override_justification` pairing already defined in `templates/SCRUM_BOARD_SCHEMA.md` for exactly this situation ("scope overridden by a human"), rather than inventing a new field:
   - Set `jenga_assigned: false` (if not already `false`).
   - Set (or append to, if already present) `override_justification`:
     ```
     override_justification: "/do --trivial dispatch-time override on <date>: execution_scope forced from '<prior_tier>' to 'inline' by human operator."
     ```
   - Also set (or append to) `scope_rationale`, mirroring the phrasing convention `skills/todo/scripts/add_trivial_task.sh` already uses for the creation-time flag, so both audit fields agree on the prior tier:
     ```
     scope_rationale: "forced inline via /do --trivial (dispatch-time override); prior execution_scope was '<prior_tier>'"
     ```
   - Emit a non-fatal log line (styled like 4.2's `AUTO-CORRECTION` message):
     ```
     TRIVIAL OVERRIDE [<task_id>]: execution_scope forced from "<prior_tier>" to "inline" via --trivial dispatch-time override.
     ```

5. **Set an in-session marker** (this dispatch is a `--trivial`-forced run) — this does not need to be persisted to frontmatter; it only needs to survive for the remainder of this `/do` invocation. This marker is distinct from an organically-assigned `execution_scope: inline` task (one the scrum-master or `/jenga` assigned `inline` to directly, with no `--trivial` involved) because its failure handling differs — see `### 4.2`'s failure-handling steps below. Do not confuse a `--trivial`-forced run with an organic `inline` task when applying those steps.

6. **Proceed to `### 4.2. Inline Execution Path`** with `execution_scope` now `inline`. Everything else about inline execution (implementation, smoke test invocation, commit convention) is identical between an organic `inline` task and a `--trivial`-forced one — only the two failure-handling branches in `### 4.2` differ, per the marker set in step 5 above.

**Precedence with the locked-task dispatch guard.** If `crucial_level: locked` (checked by `### 4.2`'s locked-task dispatch guard, which always runs and always wins), `--trivial` is redundant but harmless — the task was already going to be forced `inline`. The locked-task guard's own audit fields take precedence for that correction; do not double-write conflicting `override_justification` text. A `locked` task's fallback behavior remains "halt and report," never the `--trivial` fallback below, regardless of whether `--trivial` was also passed.

### 4.2. Inline Execution Path (execution_scope: inline)

After resolving the task context (step 4), passing override validation (step 4.1), and applying the `--trivial` dispatch-time override if present (step 4.1.5), read `execution_scope` from the task frontmatter.

**Locked-task dispatch guard (defense-in-depth).** Before branching on `execution_scope` below, read `crucial_level` from the task frontmatter (per `templates/SCRUM_BOARD_SCHEMA.md`'s Crucial Flag Fields). If `crucial_level: locked`:

- This task MUST be routed through the inline execution path below — no worktree, no developer subagent — regardless of what `execution_scope` currently reads. This guards against a locked task reaching dispatch with a non-`inline` `execution_scope` (a race, a manually edited file, or a task added to a story's `tasks:` list after `skills/jenga/SKILL.md` Phase 0.5's Rule 4 last ran).
- If `execution_scope` is already `inline`, proceed directly to the inline steps below — no correction needed.
- If `execution_scope` is anything other than `inline` (absent, `task`, `story`, or `epic`), auto-correct it to `inline` in the task frontmatter now, and record the correction using the **same logged-note convention** as `skills/jenga/SKILL.md` Phase 0.5 Rule 4 (do not invent a second, inconsistent logging mechanism):
  - Append to the task's `override_justification` frontmatter field:
    ```
    override_justification: "/do dispatch guard auto-correction <date>: execution_scope forced from '<previous_value>' to 'inline' because crucial_level: locked."
    ```
  - Then emit (non-fatally — do not halt):
    ```
    AUTO-CORRECTION [<task_id>]: crucial_level=locked requires execution_scope=inline; corrected from "<previous_value>" to "inline".
    ```
  - Then proceed to the inline steps below with the now-corrected `execution_scope: inline`.
- **Under no circumstance does a `crucial_level: locked` task fall through to step 5** (developer agent invocation / worktree creation) — this applies whether the task was resolved individually or would otherwise have entered the normal per-task worktree-creation flow.

**If `execution_scope: inline`** (including tasks corrected above), execute the task directly in the current session without spawning a developer subagent:

1. Read the task file and load its full content (description, acceptance criteria). Do NOT create a worktree. Do NOT spawn a developer subagent.
2. Implement the task inline — make the required changes to files directly in the current session.
3. Run the smoke test harness before committing anything:
   - Run `bash scripts/smoke-harness.sh <changed_file>...`, passing the paths changed in step 2. With no arguments the harness infers them from `git diff --name-only HEAD`. It exits `0` on pass and `1` on failure.
   - If `scripts/smoke-harness.sh` does not exist, log a warning and treat the result as a pass:
     ```
     WARNING [<task_id>]: scripts/smoke-harness.sh not found. Smoke test skipped (stub pass).
     ```
4. **If the smoke test exits non-zero**:
   - **If this is a `--trivial`-forced run** (marker set in step 4.1.5 — and `crucial_level` is not `locked`, which never falls back, per 4.1.5's precedence note): do NOT write `status: Failed`. `--trivial` always forces `inline` with no softer "lightest safe tier" to fall back to first, so a smoke-harness failure here goes straight to the shared `#### Fallback to Full Task-Scope Pipeline` procedure below (origin: `trivial`). Do not proceed with the remaining inline steps below — the Fallback procedure takes over from here.
   - **Otherwise** (an organically-assigned `inline` task, `--trivial` not involved): behavior is unchanged from before —
     - Write `status: Failed` to the task's frontmatter.
     - Emit:
       ```
       INLINE TASK FAILED [<task_id>]: smoke test returned non-zero exit code. Task marked Failed. Halting.
       ```
     - Do not commit. Do not proceed to the next task.
5. **If the smoke test passes**:
   - Commit the changes using the standard commit convention (`task(<task_id>): <short description>`) via `/commit` in inline mode (E32_S04_T03).
   - Run the **Intent-vs-Diff Check** (see `### 5.1. Intent-vs-Diff Check` below) for this task.
   - Self-verify the implementation against the acceptance criteria.
   - Write `status: Passed` and `date_completed: <today>` to the task's frontmatter if verification passes.
   - Remove the task from `project/todo.md`.
6. `inline` tasks do not invoke the tester agent — the smoke test and self-verification are the only gates.
7. `inline` tasks always have `needs_docs: false` — skip plan and summary documentation for the implemented task.
8. Continue to `### 6. Verify documentation`, then `### 7. After successful completion`.

If the implementation cannot be completed inline (scope is larger than anticipated — detected scope creep mid-run):
- **If this is a `--trivial`-forced run** (and `crucial_level` is not `locked`): invoke the shared `#### Fallback to Full Task-Scope Pipeline` procedure below (origin: `trivial`) — the same procedure the smoke-harness-failure branch above uses, not a second bespoke re-route.
- **Otherwise** (an organically-assigned `inline` task): abort and re-route to the normal developer path (step 5), unchanged from before.
- **Regardless of `--trivial`**, if `crucial_level: locked`, do not re-route via either path above; re-attempt inline or halt and report, per the locked-task dispatch guard above.

**If `execution_scope` is `light`** (and `crucial_level` is not `locked` — the locked-task dispatch guard above already ran and takes precedence over any scope check), proceed to `### 4.3. Light Execution Path` below instead of step 5.

**If `execution_scope` is not `inline` and not `light`** (or is absent / `task` / `story` / `epic`) **and `crucial_level` is not `locked`**, proceed to step 5 (invoke the developer agent) as normal.

### 4.3. Light Execution Path (execution_scope: light)

After resolving the task context (step 4), passing override validation (step 4.1), and applying the `--trivial` dispatch-time override if present (step 4.1.5 — note `--trivial` always forces `inline`, so a `light`-scoped task only reaches this section if `--trivial` was *not* passed), if `execution_scope: light` and `crucial_level` is not `locked` (per the locked-task dispatch guard in 4.2, which runs first and always wins), route the task through this path instead of the full `task`-scope pipeline in step 5.

`light` sits between `inline` and `task`: unlike `inline`, it spawns a real developer subagent (so it can handle small branching logic that inline's main-session execution isn't suited for); unlike `task`, it does not create a dedicated worktree and does not invoke the tester as a separate step.

1. **Spawn a developer subagent** (Agent tool, `subagent_type: "developer"`) with the same sender object and context payload as step 5 would use, but with an explicit instruction added to the dispatch prompt: **do not create a worktree** — implement directly against the current checkout (the session's existing working tree), not an isolated `.claude/worktrees/<slug>` copy. This is the one concrete difference from the step-5 `task` path: everything else about how the subagent implements the task (reading the task file, following acceptance criteria, following repo conventions) is unchanged.

2. **After the developer subagent reports implementation complete**, run the smoke test harness using the same invocation convention as `### 4.2. Inline Execution Path`:
   - Run `bash scripts/smoke-harness.sh <changed_file>...`, passing the paths the subagent changed. With no arguments the harness infers them from `git diff --name-only HEAD`. It exits `0` on pass and `1` on failure.
   - If `scripts/smoke-harness.sh` does not exist, log a warning and treat the result as a pass:
     ```
     WARNING [<task_id>]: scripts/smoke-harness.sh not found. Smoke test skipped (stub pass).
     ```

3. **If the smoke test passes**:
   - The developer subagent self-verifies the implementation against the task's acceptance criteria. No tester subagent is invoked for a `light`-scoped task — this is a deliberate, documented exception to "the tester is the sole status-writer" (`agents/tester.md`), mirroring the same exception already established for `inline` scope in step 5 of `### 4.2`. Since no tester runs, the developer/orchestrator is the one who writes the terminal status for a `light`-scoped task.
   - Commit the changes using the standard commit convention (`task(<task_id>): <short description>`) via `/commit`.
   - Run the **Intent-vs-Diff Check** (see `### 5.1. Intent-vs-Diff Check` below) for this task.
   - Write `status: Passed` and `date_completed: <today>` to the task's frontmatter if self-verification passes.
   - Remove the task from `project/todo.md`.
   - Continue to `### 6. Verify documentation`, then `### 7. After successful completion`.

4. **If the smoke test fails (non-zero exit)**: do NOT write `status: Failed` and do NOT halt. Instead, invoke `#### Fallback to Full Task-Scope Pipeline` below (origin: `light`).

#### Fallback to Full Task-Scope Pipeline

This is a self-contained, reusable procedure with two current callers — `### 4.2`'s `--trivial`-forced inline failure branches (origin: `trivial`) and `### 4.3`'s `light`-scope smoke-harness failure (origin: `light`) — given a task that was attempted under a reduced-overhead execution scope and failed its smoke-harness check (or, for `trivial`, showed detected scope creep mid-run), do the following. The only thing that varies by caller is the notice text in step 5; steps 1–4 and 6 are identical regardless of origin.

1. **Do not mark the task `Failed`.** A smoke-harness failure (or detected scope creep) under a reduced-overhead scope means the scope was too small for the task, not that the task itself is unworkable — the correct response is to retry under full isolation, not to reject the work.
2. **Create a worktree** for the task, named `<E##_S##_T##-short-slug>` per standard Worktree Management conventions, if one does not already exist for this task. (A task dispatched under `light` scope, or forced `inline` via `--trivial`, never had one — both premises skip worktree creation — so this step always creates a fresh worktree in that case.)
3. **Spawn a developer subagent** in that worktree and have it pick up from the current state of the code (the changes already made by the reduced-overhead attempt are still present in the working tree / already committed, if any commit occurred — the subagent continues from there rather than starting over).
4. **Invoke the tester agent** per the normal `### 5. Invoke the developer agent` flow's contract — full sender object, commit SHAs, worktree path. The tester is responsible for the terminal status write, exactly as in the standard `task`-scope pipeline.
5. **Emit a clear, non-fatal fallback notice** to the user/orchestrator, using the message matching the caller's origin:
   - origin `light`:
     ```
     LIGHT SCOPE FALLBACK [<task_id>]: smoke test failed; re-routing to full task-scope pipeline (worktree + developer + tester).
     ```
   - origin `trivial`:
     ```
     TRIVIAL OVERRIDE FALLBACK [<task_id>]: smoke test failed (or scope creep detected); re-routing to full task-scope pipeline (worktree + developer + tester).
     ```
6. Resume normal `task`-scope processing (steps 6–8 below) once the tester returns a verdict.

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

### 5.1. Intent-vs-Diff Check (needs_docs: false only)

After the developer agent returns (or after inline execution completes), run the following check if the task has `needs_docs: false` in its frontmatter. If `needs_docs: true`, skip this check entirely — the full documentation lifecycle handles divergence detection for those tasks.

**Steps:**

1. Read `needs_docs` from the task's frontmatter. If `needs_docs: true` (or absent and defaulting to `true`), skip to step 6.

2. Run `git diff --name-only HEAD~1` to retrieve the list of changed file names (relative paths, one per line).

3. Read the prompt template from `skills/j-do/assets/intent-vs-diff-prompt.md`. Extract the prompt block (the content between the triple backticks under `## Prompt`).

4. Substitute the placeholders:
   - `{description}` — full text of the task's `## Description` section
   - `{acceptance_criteria}` — full text of the task's `## Acceptance Criteria` section
   - `{changed_files}` — newline-separated output from step 2

5. Invoke the LLM with the constructed prompt (using the orchestrating agent's LLM access). Ask for a JSON array response only.

6. Parse the LLM response as a JSON array:
   - If parsing fails (malformed JSON): treat as `[]`, emit: `[intent-vs-diff] LLM response was not valid JSON; treating as no divergence.`, and continue.
   - If the array is empty (`[]`): no action — do not modify the task frontmatter.
   - If the array is non-empty: write `divergence_flag: true` to the task's frontmatter, then emit:
     ```
     [DIVERGENCE WARNING] Task <task_id>: the following files were changed but are not mentioned or inferable from the task description:
       - <file1>
       - <file2>
     This is a non-blocking warning. Task outcome is not affected.
     ```

**This check is non-blocking.** It does not change the task's Passed/Failed outcome. It only writes `divergence_flag: true` and emits a warning for human review. Execution continues regardless of the check result.

**Prompt calibration:** The prompt in `skills/j-do/assets/intent-vs-diff-prompt.md` is tuned to flag only files with zero plausible connection to the stated task. Test files, documentation files, lock files, and clearly implied files are excluded from flagging. See the `## False-Positive Tuning Rationale` section in the prompt template for full details.

### 6. Verify documentation
After the developer completes the task, confirm the following documentation was written:
- **Execution plan** — `project/documentation/plans/<E##_S##_T##>-plan.md` must exist (written by the developer before starting work)
- **Execution summary** — `project/documentation/summaries/<E##_S##_T##>-summary.md` must exist (written by the developer before invoking the tester)

If either file is missing, ask the developer to produce it before continuing.

Additionally, if the completed work introduces user-facing changes, update `README.md` and `WARP.md` accordingly.

### 7. After successful completion
- Check for any `_INSTRUCTIONS.md` files in `project/instructions/` whose ID matches the completed task. If found, present them to the user and explain that these actions must be completed before the feature will work correctly.
- Invoke the `/commit` skill to commit the work (if not already committed by the developer)
- Run `bash scripts/todo_manager.sh remove '<task title>'` to remove the completed task from `project/todo.md`
- Run `bash scripts/todo_manager.sh teardown` to delete `project/todo.md` if it is now effectively empty

### 8. Loop
Go back to step 1.

