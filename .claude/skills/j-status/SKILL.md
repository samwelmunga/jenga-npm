---
name: j.status
description: Polyfill alias of the status skill under a collision-safe directory name. Identical behavior to /status — Print a human-readable summary of the entire scrum board — all epics, stories, and tasks with their statuses — plus any open rapports and unprocessed queue triggers. Use when you want a quick overview of project state without reading raw files. Use when the bare /status form is shadowed by another tool's own built-in command of the same name.
output_types: text
keywords:
  - status
  - board summary
  - overview
  - project state
  - what's done
  - j-status
  - polyfill
examples:
  - "show me the project status"
  - "what's the state of the board?"
  - "j-status"
---

# Status — Board Overview

This skill is a literal-directory-name duplicate of `skills/status/`. It exists so that `/j-status` (and `j.j-status`) give a guaranteed-unshadowed way to reach the same flow as `/status`, even if a host tool's own built-in command of the same name would otherwise shadow or override the bare `/status` alias (Claude Code's native skill resolution is a literal-string, directory-name-based match — see `docs/skill-authoring.md`'s "Invocation Convention").

This file is generated/synced by `scripts/generate-j-alias.sh status` from `skills/status/SKILL.md` — do not hand-edit it; re-run the generator instead to pick up source changes.

## Instructions

1. **Read `project/configs/workflow.json`** to confirm board paths. Fall back to `project/board/` if the file does not exist.

2. **Scan epics** — Read all files in `project/board/epics/`. For each epic, extract: `id`, `title`, `status`, `date_started`, `date_completed`, and the `stories` list.

3. **Scan stories** — For each story referenced in the epics list, read its file from `project/board/stories/`. Extract: `id`, `title`, `status`, `tasks` list.

4. **Scan tasks** — For each task referenced in each story, read its file from `project/board/tasks/`. Extract: `id`, `title`, `status`, `assigned_to`.

5. **Scan open rapports** — List all `.md` files in `project/rapports/problems/` that do **not** end in `.IGNORE.md`. List all `.md` files in `project/rapports/analysis/`.

6. **Check the queue** — If `project/queue/scrum_triggers.jsonl` is non-empty, note the number of pending triggers awaiting the scrum master.

7. **Print the summary** following the layout and icon conventions in `assets/output_format.md`.

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
