---
name: close-story
description: Close a story by verifying all tasks are in terminal state, extracting actual diff stats per task, computing scope divergence flags, and writing closure metadata to task frontmatter.
keywords:
  - close story
  - close
  - finish story
  - complete story
  - story done
examples:
  - "close story E17_S06"
  - "/close-story E32_S06"
  - "mark story E12_S03 as done"
---

# close-story — Close a Story

## Purpose

`/close-story <story-id>` performs the final closure steps for a story:

1. Verifies all tasks in the story are in a terminal state (Passed or Done).
2. Extracts actual `git diff --stat` metrics for each task from the commit history.
3. Writes `actual_files_changed`, `actual_lines_delta`, and `scope_divergence_flag` to each task's frontmatter.
4. Updates the story's frontmatter `status` to `Done` and records `date_completed`.

---

## Instructions

### Step 1 — Verify story is closeable

Run the guard script:

```bash
bash skills/close-story/scripts/check-story-closeable.sh <story-id>
```

- If it exits with code 0 and prints `CLOSEABLE`, continue.
- If it exits with code 1, halt and report the blocking tasks to the user. Do not proceed.

---

### Step 2 — Extract per-task diff stats and compute scope divergence

**At the start of this step**, read `project/configs/scope-thresholds.json` to check that it
exists and is parseable. If it is missing or malformed, log a warning and continue — divergence
flags will be skipped (non-blocking). The `compute-scope-divergence.sh` script handles this
gracefully by always printing `false` on error.

For **each task ID** listed in the story's `tasks:` frontmatter array:

1. **Find the task file** at `project/board/tasks/<task-id>_*.md`.

2. **Extract commit SHA(s)** for this task:
   ```bash
   git log --all --no-merges --grep="<task-id>" --pretty=format:"%H" 2>/dev/null
   ```
   This matches commits whose message contains the EST task identifier (e.g. `E32_S06_T01`).

3. **Run per-task diff stat extraction:**
   ```bash
   bash skills/close-story/scripts/extract-task-diff-stats.sh <task-id>
   ```
   The script outputs:
   ```
   actual_files_changed: <N>
   actual_lines_delta: <N>
   ```
   Parse these values from stdout.

4. **Write stats to task frontmatter:**
   ```bash
   bash skills/close-story/scripts/update-task-frontmatter.sh \
     "project/board/tasks/<task-id>_*.md" \
     actual_files_changed <N>

   bash skills/close-story/scripts/update-task-frontmatter.sh \
     "project/board/tasks/<task-id>_*.md" \
     actual_lines_delta <N>
   ```

5. **Compute and write scope divergence flag:**

   Read the task's `execution_scope` from its frontmatter:
   ```bash
   EXECUTION_SCOPE=$(grep '^execution_scope:' "project/board/tasks/<task-id>_*.md" \
     | head -1 | awk '{print $2}')
   ```

   If `execution_scope` is empty or absent, treat it as `task` (no divergence).

   Run the divergence computation:
   ```bash
   DIVERGENCE_FLAG=$(bash skills/close-story/scripts/compute-scope-divergence.sh \
     "<execution_scope>" <actual_files_changed> <actual_lines_delta>)
   ```

   Write the result to task frontmatter:
   ```bash
   bash skills/close-story/scripts/update-task-frontmatter.sh \
     "project/board/tasks/<task-id>_*.md" \
     scope_divergence_flag "$DIVERGENCE_FLAG"
   ```

   Track diverging tasks in a running list for the final report (Step 5).

6. **Skip tasks with no matched commits** — If `actual_files_changed` is `0`
   and `actual_lines_delta` is `0`, it likely means the task predates this
   feature or uses an untracked commit. Write the `0` values anyway so the
   field is present but do not treat this as an error. Run divergence
   computation with `0 0` — this will return `false` for all scopes.

---

### Step 3 — Bundle task attribution

A **bundle task** is one where a single commit message contains multiple task
IDs (e.g. `task(E32_S06_T01, E32_S06_T02): ...`). In this case:

- Each task matched by `git log --grep` will independently resolve to the same
  commit SHA, and each will receive the **full bundle stats** as its
  `actual_files_changed` and `actual_lines_delta` values.
- This is the **"full credit"** attribution model: each task is credited with
  the total work of the bundle commit since the individual contribution cannot
  be mechanically separated.
- An alternative **proportional split** (divide total stats by number of tasks
  in the bundle) is mathematically cleaner but requires detecting the bundle
  size at query time, which is not supported by the current scripts.
- The full-credit model is the default. Future work may introduce proportional
  splitting if telemetry shows significant over-counting in bundle scenarios.

> Note for tester: bundle attribution means the sum of `actual_lines_delta`
> across tasks may exceed the true total for stories where bundle commits were
> used.

---

### Step 4 — Update story frontmatter

After all tasks have been updated, set the following fields in the story's
frontmatter:

- `status: Done`
- `date_completed: <YYYY-MM-DD>` (today's date in UTC)

Use `update-task-frontmatter.sh` targeting the story file, or edit directly.

---

### Step 5 — Report

Print a summary to the user:

```
Story <story-id> closed.
Tasks updated with actual diff stats:
  <task-id>: files_changed=<N>, lines_delta=<N>, scope_divergence_flag=<true|false>
  ...
```

If any task had `0` for both fields, note it as potentially untracked:
```
  <task-id>: files_changed=0, lines_delta=0 (no EST-tagged commit found)
```

#### Scope Divergence

Include a "Scope Divergence" section listing every task whose `scope_divergence_flag` was set
to `true`. If no tasks diverged, note that explicitly.

```
Scope Divergence:
  <task-id> [scope=<execution_scope>]: files_changed=<N>, lines_delta=<N> — exceeded threshold
  ...
```

Or, if none diverged:
```
Scope Divergence: none
```

The divergence thresholds applied are those from `project/configs/scope-thresholds.json`:
- `inline` scope: max_files=<inline_max_files>, max_lines=<inline_max_lines>
- `story` scope: max_files=<story_max_files>
- `task` / `epic` scope: no threshold (always false)

If the config was missing or malformed, note that divergence flags were skipped:
```
Scope Divergence: skipped (scope-thresholds.json missing or malformed)
```

---

## Scripts Reference

| Script | Purpose |
|--------|---------|
| `scripts/check-story-closeable.sh <story-id>` | Guard: verify all tasks in terminal state |
| `scripts/extract-diff-stats.sh <story-id>` | Story-level aggregate diff stats (for story frontmatter) |
| `scripts/extract-task-diff-stats.sh <task-id>` | Per-task diff stats from EST-tagged commits |
| `scripts/update-task-frontmatter.sh <file> <key> <value>` | Write/update a YAML field in task or story frontmatter |
| `scripts/compute-scope-divergence.sh <execution_scope> <actual_files_changed> <actual_lines_delta>` | Compute scope divergence flag: prints `true` or `false` |
