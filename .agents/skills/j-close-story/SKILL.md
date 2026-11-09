---
name: j.close-story
description: Close a story by verifying all tasks are in terminal state, extracting actual diff stats per task, computing scope divergence flags, and writing closure metadata to task frontmatter.
keywords:
  - close story
  - close
  - finish story
  - complete story
  - story done
  - j-close-story
examples:
  - "close story E17_S06"
  - "/close-story E32_S06"
  - "mark story E12_S03 as done"
  - "j-close-story"
---

# close-story — Close a Story

`skills/j-close-story/` is the **canonical, hand-edited** directory for this skill, per CLAUDE.md's "The Canonical Naming Contract" (the `E50` reopening of 2026-09-09, which promoted `skills/j-close-story/` from generated twin to sole canonical form). The `j-` prefix is there for collision safety — a real directory under a distinct name, so a host tool shipping its own same-named built-in command cannot shadow it (Claude Code's native skill resolution is a literal-string, directory-name-based match; see `project/documentation/skill-authoring.md`'s "Invocation Convention").

> ⚠️ **`scripts/generate-j-alias.sh` was retired by `E50_S14` and no longer exists — there is nothing to run.** This file was previously generated from a bare `skills/close-story/SKILL.md` source; `E50_S15` deleted that directory. This file is now the sole canonical, hand-edited source for this skill — edit it directly.

## Purpose

`/close-story <story-id>` performs the final closure steps for a story:

1. Verifies all tasks in the story are in a terminal state (Passed, Passed with remarks, or Done).
2. Extracts actual `git diff --stat` metrics for each task from the commit history.
3. Writes `actual_files_changed`, `actual_lines_delta`, and `scope_divergence_flag` to each task's frontmatter.
4. Runs a static `.publicignore` blocklist check (E51_S03_T03) against each task's and the story's
   own touched files, marking `status: Privatized` in place of the normal terminal status wherever
   every touched file is permanently excluded from the public mirror — independent of any
   `/mirror-public` run having occurred.
5. Updates the story's frontmatter `status` to `Done` (or `Privatized`, per step 4) and records
   `date_completed`.
6. Persists each task's token usage totals next to the diff stats (non-blocking; E76_S03_T01) via
   `scripts/task-usage.sh --persist`, and reports them, or "not measured", per task. Skipped silently when that
   script is not installed.
7. Rolls the story's task totals plus its allocated overhead up into the story record (non-blocking;
   E76_S03_T05) via `scripts/task-usage.sh --report --stories`, as a separate task part, overhead part and total,
   and reports them, or "not measured". Skipped silently when that script is not installed.

---

## Instructions

### Step 1 — Verify story is closeable

Run the guard script:

```bash
bash "$([ -f skills/j-close-story/scripts/check-story-closeable.sh ] && echo skills/j-close-story/scripts/check-story-closeable.sh || echo node_modules/@jenga-ai/agent/skills/j-close-story/scripts/check-story-closeable.sh)" <story-id>
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
   bash "$([ -f scripts/commits-for-item.sh ] && echo scripts/commits-for-item.sh || echo node_modules/@jenga-ai/agent/scripts/commits-for-item.sh)" <task-id>
   ```
   This is the shared resolver. It prints one SHA per line for the commits that belong to the task: those whose
   message names the EST task identifier (e.g. `E32_S06_T01`, not followed by a digit or underscore) or that carry a
   `Jenga-Task: <task-id>` trailer. No output means no commit was found (exit 0).

3. **Run per-task diff stat extraction:**
   ```bash
   bash "$([ -f skills/j-close-story/scripts/extract-task-diff-stats.sh ] && echo skills/j-close-story/scripts/extract-task-diff-stats.sh || echo node_modules/@jenga-ai/agent/skills/j-close-story/scripts/extract-task-diff-stats.sh)" <task-id>
   ```
   The script outputs:
   ```
   actual_files_changed: <N>
   actual_lines_delta: <N>
   ```
   Parse these values from stdout.

4. **Write stats to task frontmatter:**
   ```bash
   bash "$([ -f skills/j-close-story/scripts/update-task-frontmatter.sh ] && echo skills/j-close-story/scripts/update-task-frontmatter.sh || echo node_modules/@jenga-ai/agent/skills/j-close-story/scripts/update-task-frontmatter.sh)" \
     "project/board/tasks/<task-id>_*.md" \
     actual_files_changed <N>

   bash "$([ -f skills/j-close-story/scripts/update-task-frontmatter.sh ] && echo skills/j-close-story/scripts/update-task-frontmatter.sh || echo node_modules/@jenga-ai/agent/skills/j-close-story/scripts/update-task-frontmatter.sh)" \
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
   DIVERGENCE_FLAG=$(bash "$([ -f skills/j-close-story/scripts/compute-scope-divergence.sh ] && echo skills/j-close-story/scripts/compute-scope-divergence.sh || echo node_modules/@jenga-ai/agent/skills/j-close-story/scripts/compute-scope-divergence.sh)" \
     "<execution_scope>" <actual_files_changed> <actual_lines_delta>)
   ```

   Write the result to task frontmatter:
   ```bash
   bash "$([ -f skills/j-close-story/scripts/update-task-frontmatter.sh ] && echo skills/j-close-story/scripts/update-task-frontmatter.sh || echo node_modules/@jenga-ai/agent/skills/j-close-story/scripts/update-task-frontmatter.sh)" \
     "project/board/tasks/<task-id>_*.md" \
     scope_divergence_flag "$DIVERGENCE_FLAG"
   ```

   Track diverging tasks in a running list for the final report (Step 5).

6. **Skip tasks with no matched commits** — If `actual_files_changed` is `0`
   and `actual_lines_delta` is `0`, it likely means the task predates this
   feature or uses an untracked commit. Write the `0` values anyway so the
   field is present but do not treat this as an error. Run divergence
   computation with `0 0` — this will return `false` for all scopes.

7. **Run the static Privatized check** (E51_S03_T03) — immediately after the
   frontmatter writes and divergence computation above, check whether this
   task's own work is permanently excluded from the public mirror:
   ```bash
   bash "$([ -f skills/j-close-story/scripts/check-privatized.sh ] && echo skills/j-close-story/scripts/check-privatized.sh || echo node_modules/@jenga-ai/agent/skills/j-close-story/scripts/check-privatized.sh)" <task-id> "project/board/tasks/<task-id>_*.md"
   ```
   This is a **static** check (per `$([ -f templates/SCRUM_BOARD_SCHEMA.md ] && echo templates/SCRUM_BOARD_SCHEMA.md || echo node_modules/@jenga-ai/agent/templates/SCRUM_BOARD_SCHEMA.md)`'s "Static
   vs. Reactive Status Setting" section) — it derives the task's touched-file
   list from its own EST-tagged commit history (same technique as Step 2) and
   tests every file against `.publicignore`, with **no dependency on any
   `/mirror-public` run having ever occurred**.
   - Prints `PRIVATIZED` on stdout if every touched file matched the
     blocklist — the script has already written `status: Privatized` to the
     task's frontmatter (superseding whatever status was there, including a
     contradictory `Publicized`, in which case the script also logs a
     `publicized_privatized_mismatch` event to `project/logs/events.json` as a single appended JSONL line, never a rewrite; manual writes use the dual-path form of `scripts/events-append.sh`).
   - Prints `UNCHANGED` if the task has zero matched commits, only partial
     blocklist coverage, or is already `Privatized` — no error, no board
     write.
   - Track any task that came back `PRIVATIZED` for the final report
     (Step 5).

**After the per-task loop, persist the story's usage totals** (E76_S03_T01), once for the whole story:
```bash
bash "$([ -f skills/j-close-story/scripts/persist-task-usage.sh ] && echo skills/j-close-story/scripts/persist-task-usage.sh || echo node_modules/@jenga-ai/agent/skills/j-close-story/scripts/persist-task-usage.sh)" <story-id>
```
The helper locates the script with the same idiom as this skill's other scripts
(`[ -f scripts/task-usage.sh ] && echo scripts/task-usage.sh || echo node_modules/@jenga-ai/agent/scripts/task-usage.sh`),
runs `bash scripts/task-usage.sh --persist --story <story-id>`, and prints the ready-made `Usage (...)` block for Step 5. All
measuring, locking and frontmatter writes are done by `task-usage.sh`; this step adds no persistence rules.
- **Non-blocking.** Whatever the helper prints or however `task-usage.sh` exited, the close continues and no task or
  story status changes because of it. Keep the helper's output verbatim for Step 5.
- **Silent when absent.** If the helper prints nothing, `task-usage.sh` is installed in neither location (for
  example the public mirror or an older install): skip the usage step entirely, with no warning, no "not measured"
  lines and no `Usage` section in the report.

---

### Step 3 — Bundle task attribution

A **bundle task** is one where a single commit message contains multiple task
IDs (e.g. `task(E32_S06_T01, E32_S06_T02): ...`). In this case:

- Each task matched by `scripts/commits-for-item.sh` will independently resolve to the same
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

After all tasks have been updated, run the same static Privatized check
against the story's own direct commits (E51_S03_T03) **before** deciding the
story's terminal status:

```bash
bash "$([ -f skills/j-close-story/scripts/check-privatized.sh ] && echo skills/j-close-story/scripts/check-privatized.sh || echo node_modules/@jenga-ai/agent/skills/j-close-story/scripts/check-privatized.sh)" <story-id> "project/board/stories/<story-id>_*.md"
```

Passing the story id (`E##_S##`) rather than a task id makes the script's
anchored-grep commit matching (`"<id>([^0-9_]|$)"`) match only the story's
own direct commits (e.g. `story(E51_S03): ...`) — not its children's, since
a story id is a literal string prefix of every one of its own tasks' ids.

- If the script prints `PRIVATIZED`, it has already written
  `status: Privatized` to the story's frontmatter. **Do not also write
  `status: Done`** — `Privatized` supersedes `Done` as the more specific
  terminal status (a story cannot be both), matching how `Merged`/`Publicized`
  supersede an otherwise-unremarkable closed status on tasks. Still set
  `date_completed: <YYYY-MM-DD>` (today's date in UTC).
- If the script prints `UNCHANGED`, proceed as normal: set the following
  fields in the story's frontmatter:
  - `status: Done`
  - `date_completed: <YYYY-MM-DD>` (today's date in UTC)

Use `update-task-frontmatter.sh` targeting the story file, or edit directly.

**Then roll the story's usage up into the story record** (E76_S03_T05), once, after the status and `date_completed`
writes above and after Step 2's per-task persist:
```bash
bash "$([ -f skills/j-close-story/scripts/write-story-usage.sh ] && echo skills/j-close-story/scripts/write-story-usage.sh || echo node_modules/@jenga-ai/agent/skills/j-close-story/scripts/write-story-usage.sh)" <story-id>
```
The helper locates `task-usage.sh` with the same idiom as `persist-task-usage.sh`, runs
`bash scripts/task-usage.sh --report --stories <story-id>`, writes the story's usage fields (task part, allocated
overhead part, total: see `templates/SCRUM_BOARD_SCHEMA.md`, "Usage fields on stories") with
`update-task-frontmatter.sh`, and prints the ready-made `Story usage (...)` block for Step 5. It calculates nothing
itself: the three numbers are `task-usage.sh`'s, and it refuses to write unless total = task part + overhead part.
- **Non-blocking.** Whatever the helper prints, the close continues and the story's `status` and `date_completed` are
  not touched by it. Keep its output verbatim for Step 5.
- **Never a guess.** When the numbers cannot be produced the helper writes no story field and its block says
  `not measured: <reason>`; never write a story usage field by hand from a guessed or zero value.
- **Silent when absent.** If the helper prints nothing, `task-usage.sh` is installed in neither location (for example
  the public mirror or an older install): skip the rollup entirely, with no warning, no "not measured" line and no
  `Story usage` section in the report.

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

#### Usage

If the Step 2 usage helper printed anything, include its block verbatim, after the diff-stat lines. It lists, per
task, the persisted totals (`total=<N> tokens (...)`), or `not measured: <reason>` for a task nothing could be
measured for (never a zero), flags a task whose persisted total is marked `usage_possibly_incomplete`, and shows any
failure as a prominent `WARNING` naming the task and the reason. A usage failure never changes the closing status:
say so in the report and carry on. If the helper printed nothing (`task-usage.sh` not installed), omit the section.

```
Usage (task-usage.sh --persist --story <story-id>):
  <task-id>: total=<N> tokens (input=<N>, output=<N>, cache_write=<N>, cache_read=<N>), transcripts=<N>
  <task-id>: total=<N> tokens (...), transcripts=<N> [usage_possibly_incomplete: the transcripts looked partly pruned]
  <task-id>: not measured: <reason>
```

#### Story usage

If the Step 4 story-usage helper printed anything, include its block verbatim, after the `Usage` section (or after
the diff-stat lines when that section is omitted). It shows the story's task part, its allocated overhead part and
their total (the total is always the task part plus the overhead part), the story's tasks that have no measurement
(the task part is then a lower bound), and any unallocated overhead of the story's session, so the numbers' origin is
visible. When the numbers could not be produced it shows `not measured: <reason>`, and no story field was written. A
failure never changes the closing status: say so and carry on. If the helper printed nothing (`task-usage.sh` not
installed), omit the section.

```
Story usage (task-usage.sh --report --stories <story-id>):
  tasks:    total=<N> tokens (input=<N>, output=<N>, cache_write=<N>, cache_read=<N>)
  overhead: total=<N> tokens (input=<N>, output=<N>, cache_write=<N>, cache_read=<N>)
  story:    total=<N> tokens (tasks <N> + overhead <N>)
  unallocated overhead in this story's session: none | <total and reason>
  recorded in project/board/stories/<story-id>_<slug>.md
  not measured: <reason>
```

#### Privatized

Include a "Privatized" note listing any task (from Step 2) or the story itself (from Step 4) that
`check-privatized.sh` marked `status: Privatized` — every one of its touched files was permanently
excluded from the public mirror via `.publicignore`, independent of any `/mirror-public` run.

```
Privatized:
  <task-id>: all touched files matched .publicignore
  ...
Story <story-id>: Privatized (all touched files matched .publicignore) — closed as Privatized, not Done
```

Or, if none were Privatized:
```
Privatized: none
```

If any ticket was overwritten from `Publicized` to `Privatized` (a precedence mismatch), note it
explicitly and point to the logged `publicized_privatized_mismatch` event in
`project/logs/events.json` for investigation:
```
  <id>: WARNING — was Publicized, found fully blocklisted, overwritten to Privatized (see
  project/logs/events.json: publicized_privatized_mismatch)
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
| `scripts/extract-diff-stats.sh <story-id>` | Story-level aggregate diff stats (for story frontmatter): the story's own commits plus its tasks' commits, via `scripts/commits-for-item.sh` |
| `scripts/extract-task-diff-stats.sh <task-id>` | Per-task diff stats from the task's commits, resolved by `scripts/commits-for-item.sh` |
| `scripts/update-task-frontmatter.sh <file> <key> <value>` | Write/update a YAML field in task or story frontmatter |
| `scripts/compute-scope-divergence.sh <execution_scope> <actual_files_changed> <actual_lines_delta>` | Compute scope divergence flag: prints `true` or `false` |
| `scripts/persist-task-usage.sh <story-id>` | Persist the story's per-task token usage via `task-usage.sh --persist --story` and print the report's `Usage` block; non-blocking (always exits 0), silent when `task-usage.sh` is not installed |
| `scripts/write-story-usage.sh <story-id>` | Roll the story's task totals plus allocated overhead up into the story record via `task-usage.sh --report --stories` (task part, overhead part, total, `usage_*` fields) and print the `Story usage` block; non-blocking (always exits 0), writes nothing and says `not measured: <reason>` when the numbers cannot be produced, silent when `task-usage.sh` is not installed |
| `scripts/check-privatized.sh <id> <board-file-path>` | Static `.publicignore` membership check (task or story); prints `PRIVATIZED` (status written) or `UNCHANGED` — no `/mirror-public` run required |
