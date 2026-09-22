---
name: j.status
description: Print a human-readable summary of the entire scrum board — all epics, stories, and tasks with their statuses — plus any open rapports and unprocessed queue triggers. Use when you want a quick overview of project state without reading raw files.
output_types: text
keywords:
  - status
  - board summary
  - overview
  - project state
  - what's done
  - j-status
examples:
  - "show me the project status"
  - "what's the state of the board?"
  - "j-status"
---

# Status — Board Overview

`skills/j-status/` is the **canonical, hand-edited** directory for this skill, per CLAUDE.md's "The Canonical Naming Contract" (the `E50` reopening of 2026-09-09, which promoted `skills/j-status/` from generated twin to sole canonical form). The `j-` prefix is there for collision safety — a real directory under a distinct name, so a host tool shipping its own same-named built-in command cannot shadow it (Claude Code's native skill resolution is a literal-string, directory-name-based match; see `docs/skill-authoring.md`'s "Invocation Convention").

> ⚠️ **`scripts/generate-j-alias.sh` was retired by `E50_S14` and no longer exists — there is nothing to run.** This file was previously generated from a bare `skills/status/SKILL.md` source; `E50_S15` deleted that directory. This file is now the sole canonical, hand-edited source for this skill — edit it directly.

## Instructions

1. **Read `project/configs/workflow.json`** to confirm board paths. Fall back to `project/board/` if the file does not exist.

2. **Scan epics** — Read all files in `project/board/epics/`. For each epic, extract: `id`, `title`, `status`, `date_started`, `date_completed`, and the `stories` list.

3. **Scan stories** — For each story referenced in the epics list, read its file from `project/board/stories/`. Extract: `id`, `title`, `status`, `tasks` list.

4. **Scan tasks** — For each task referenced in each story, read its file from `project/board/tasks/`. Extract: `id`, `title`, `status`, `assigned_to`.

5. **Scan open rapports** — List all `.md` files in `project/rapports/problems/` that do **not** end in `.IGNORE.md`. List all `.md` files in `project/rapports/analysis/`.

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
