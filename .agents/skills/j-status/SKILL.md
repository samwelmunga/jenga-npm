---
name: j.status
description: Print a short board overview (totals, a bar, the epics still in progress) or, for one epic or story id, a progress view of that scope, plus any open rapports and unprocessed queue triggers. `--all` prints the full per-epic and per-story list and `--legacy` selects the old views. Use when you want a quick overview of project state without reading raw files.
output_types: text
keywords:
  - status
  - board summary
  - overview
  - project state
  - what's done
  - j-status
  - status --legacy
  - status --all
examples:
  - "show me the project status"
  - "what's the state of the board?"
  - "j-status"
  - "j.status E92"
  - "j.status --legacy"
  - "j.status --all"
---

# Status — Board Overview

`skills/j-status/` is the **canonical, hand-edited** directory for this skill, per CLAUDE.md's "The Canonical Naming Contract" (the `E50` reopening of 2026-09-09, which promoted `skills/j-status/` from generated twin to sole canonical form). The `j-` prefix is there for collision safety — a real directory under a distinct name, so a host tool shipping its own same-named built-in command cannot shadow it (Claude Code's native skill resolution is a literal-string, directory-name-based match; see `project/documentation/skill-authoring.md`'s "Invocation Convention").

> ⚠️ **`scripts/generate-j-alias.sh` was retired by `E50_S14` and no longer exists — there is nothing to run.** This file was previously generated from a bare `skills/status/SKILL.md` source; `E50_S15` deleted that directory. This file is now the sole canonical, hand-edited source for this skill — edit it directly.

## Instructions

1. **Read `project/configs/workflow.json`** to confirm board paths. Fall back to `project/board/` if the file does not exist.

1.5. **Resolve the mode (`E92_S06_T26`, Node renderer `E92_S08_T06`)** — the arguments of `j.status` (`--legacy`, `--all`,
   one epic or story id, `--root`, `--cols`, `--color`, `--charset`, in any order) are parsed by a script, never by this file. Pass the arguments exactly as
   the user typed them:
   ```
   bash "$([ -f skills/j-status/scripts/resolve-status-mode.sh ] && echo skills/j-status/scripts/resolve-status-mode.sh || echo node_modules/@jenga-ai/agent/skills/j-status/scripts/resolve-status-mode.sh)" mode <the user's arguments>
   ```
   It prints one word. An exit status `2` (a bad flag, a second id, a task id) means the arguments were not valid: show
   its stderr line and stop. The word decides the path:

   - `overview` (no argument) or `scope` (an epic or story id, `--all` allowed): the **default path**, drawn by the Node
     renderer. Run the same command with `render` in place of `mode` and `--charset utf8 --color never` before the user's
     arguments, after step 6.5 (so the renderer sees reconciled statuses), and copy its stdout into the reply (see the
     block below). For `overview` the output stands for the board listing, so skip steps 2-4, 6.9 and 6.10 and the board
     listing of step 7, and still do steps 5, 6, 6.5, 6.7, 6.8 and 6.85 and print their sections (open rapports, queue, the
     `todo.md` warning, the dependency audit, the settings requirements) after it, as laid out in `assets/output_format.md`. For `scope` the view is
     the whole answer: print it and stop. When `render` prints nothing or fails, fall back to the legacy path below and
     show no error for it.
   - `legacy` (`--legacy`, or `--all` with no id) or `legacy-scope` (`--legacy <id>`): the **legacy path**, which is
     everything below from step 2 on, exactly as written. `--all` with no id is the full per-epic and per-story list, so it
     takes this path too.

   **Show the rendering in the reply.** Tool output is folded away in the desktop app, so copy the renderer's stdout
   into your reply as a fenced code block, byte for byte: nothing added, counted, drawn or reworded. `--color never` is
   used because ANSI colour cannot render in chat markdown; colour needs `--color always` in a real terminal.

   The legacy path (steps 2-4, 6.9, 6.10 and the board listing of step 7) is kept as it was before the rework of
   2026-11-13; `render-status-bars.sh` and `render-status-scope.sh` stay as they are.

2. **Scan epics** (legacy path) — Read all files in `project/board/epics/`. For each epic, extract: `id`, `title`, `status`, `date_started`, `date_completed`, and the `stories` list.

3. **Scan stories** (legacy path) — For each story referenced in the epics list, read its file from `project/board/stories/`. Extract: `id`, `title`, `status`, `tasks` list.

4. **Scan tasks** (legacy path) — For each task referenced in each story, read its file from `project/board/tasks/`. Extract: `id`, `title`, `status`, `assigned_to`.

5. **Scan open rapports** (both paths) — List all `.md` files in `project/rapports/problems/` that do **not** end in `.IGNORE.md`. List all `.md` files in `project/rapports/analysis/`.

6. **Check the queue** — If `project/queue/scrum_triggers.jsonl` is non-empty, note the number of pending triggers awaiting the scrum master.

6.5. **Run the deploy-reconcile pass** (`E51_S05`) before printing the summary — `/status` has no
`scripts/` directory of its own comparable to `/self-sync`'s, so invoke the shared pipeline
directly rather than adding a third skill-local wrapper script:
   ```
   bash "$([ -f scripts/mark-deployed.sh ] && echo scripts/mark-deployed.sh || echo node_modules/@jenga-ai/agent/scripts/mark-deployed.sh)"
   ```
   This defaults to invoking its own sibling `scripts/compute-deploy-reconcile.sh`, which
   discovers any not-yet-reconciled `vX.Y.Z-stage`/`vX.Y.Z` tags on the public `jenga-npm` repo
   (unauthenticated read — no credential required) and promotes matching `Publicized`/
   `Deployed to Stage` tickets to `Deployed to Stage`/`Deployed to Prod` (writing
   `date_deployed_prod` on a Prod promotion) by commit ancestry, before this skill re-scans the
   board in steps 2-4 above. This step is **non-fatal**: a failure anywhere in the pipeline
   (including an unreachable public repo) is logged as a warning only and never prevents `/status`
   from printing whatever board state it already has, and never causes a non-zero exit.

6.7. **Check `project/todo.md` formatting** — invoke
   ```
   bash "$([ -f scripts/check-todo-format.sh ] && echo scripts/check-todo-format.sh || echo node_modules/@jenga-ai/agent/scripts/check-todo-format.sh)"
   ```
   Same script `/j-reconcile` uses (never a second, independently-maintained check) — it reuses
   `parsers/todo.js`'s own `LEADING_REF_MISORDER_PATTERN` so both skills and the dashboard's
   `/v1/todo-warnings` route always agree on the same set of lines. Exit `0` with no output means
   nothing to report — skip the warning line in step 7 entirely. A non-zero exit prints one
   `line <N>: <text>` per malformed entry — carry the count (and, per `assets/output_format.md`,
   the first couple of lines) into the summary. Report only, same as `/j-reconcile`: never edit
   `project/todo.md` here.

6.8. **Collect the dependency-audit status** — invoke
   ```
   bash "$([ -f scripts/audit-status.sh ] && echo scripts/audit-status.sh || echo node_modules/@jenga-ai/agent/scripts/audit-status.sh)"
   ```
   It is read-only (no audit is run, no npm call, no file written) and always exits `0`; capture its
   stdout verbatim for step 7 and add nothing to it. Do not parse or reinterpret its output here.

6.85. **Check the settings requirements** (`E100_S05_T04`, both paths, overview and legacy views; a scope view prints only
   its view and skips this step) — invoke
   ```
   bash "$([ -f scripts/settings-doctor.sh ] && echo scripts/settings-doctor.sh || echo node_modules/@jenga-ai/agent/scripts/settings-doctor.sh)" --quiet
   ```
   and decide by its exit status, never by parsing beyond it. Exit `0` (nothing printed): run the same command once more
   without `--quiet` and count its `: active` lines as N; the section is the single line `Settings requirements: all N
   active`. Exit `1`: the section lists each inactive requirement with its indented fix lines, copied unchanged from stdout.
   Exit `2`, a missing script or anything else: the section is the single line `Settings requirements: could not be
   checked`. This step is **non-fatal** like 6.5: no error is shown and `j.status` never fails or blocks on it. The
   section is printed as plain text outside the renderer's fenced block, so the renderer stdout copied into the reply is
   unchanged.

6.9. **Collect the progress bars** (legacy path only) — invoke, once,
   ```
   bash "$([ -f skills/j-status/scripts/render-status-bars.sh ] && echo skills/j-status/scripts/render-status-bars.sh || echo node_modules/@jenga-ai/agent/skills/j-status/scripts/render-status-bars.sh)"
   ```
   (add `--root <dir>` when the board is not under the current directory). It prints one `<id><TAB><bar>` line
   per epic, then per story, and is the **only** source of the bars: this skill counts nothing and draws
   nothing, it only copies each returned bar. When the script prints nothing, is missing or fails, step 7 prints every
   epic and story row exactly as it did before bars existed, and no error is shown for it.

6.10. **Collect the extended scope block (legacy path only, only for a scope argument)** — when the user called `j.status` with a
   specific epic or story id (for example `j.status E03` or `j.status E03_S05`), invoke, once,
   ```
   bash "$([ -f skills/j-status/scripts/render-status-scope.sh ] && echo skills/j-status/scripts/render-status-scope.sh || echo node_modules/@jenga-ai/agent/skills/j-status/scripts/render-status-scope.sh)" <id>
   ```
   (add `--root <dir>` when the board is not under the current directory). Capture its stdout verbatim for step 7 and
   add nothing to it. The plain overview (no argument) never runs this script and never shows the extended block.
   When the script prints nothing, is missing or fails, the overview prints as before and no error is shown for it.

7. **Print the summary** (on the default path the renderer's own output stands for the board listing, see step 1.5; the
   rest of this step is the legacy path) following the layout and icon conventions in `assets/output_format.md`, adding each
   step 6.9 bar at the end of the epic or story row whose id it carries. After the
   queue section, add a `Dependency audit` heading (same banner style as the other sections) and print step
   6.8's output under it unchanged. After it, add the `Settings requirements` section from step 6.85, as laid out in
   `assets/output_format.md`. When step 6.10 returned a block, print it unchanged after the scoped part of the
   overview, as laid out in `assets/output_format.md`.

8. If no epics exist, print: `No board items found. Run /pi-plan to define epics or /todo to add items.`

## Scope note: playbook step status (E53_S04_T03 audit)

This skill reports board-level status only (steps 2-4 above: epic/story/task `status` from
`project/board/`). It never reads or reports `/jenga` playbook run state
(`skills/jenga/scripts/run-playbook-step.sh`'s temp state file, its `step_ready`/`complete`/
`halted` reports, or per-step `passed`/`failed`/`skipped` outcomes) — a playbook run is ephemeral,
session-local execution state, not a board item, and has no representation in
`project/board/`. This is confirmed as intentional, not a gap: `skipped` is scoped strictly to
playbook-step context and is never written to a task/story's board-level `status` field (see
`templates/SCRUM_BOARD_SCHEMA.md`'s Status Values table, unmodified by `E53_S04`).
