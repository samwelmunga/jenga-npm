---
name: status
description: Print a human-readable summary of the entire scrum board — all epics, stories, and tasks with their statuses — plus any open rapports and unprocessed queue triggers. Use when you want a quick overview of project state without reading raw files.
keywords:
  - status
  - board summary
  - overview
  - project state
  - what's done
examples:
  - "show me the project status"
  - "what's the state of the board?"
---

# Status — Board Overview

## Instructions

1. **Read `project/configs/workflow.json`** to confirm board paths. Fall back to `project/board/` if the file does not exist.

2. **Scan epics** — Read all files in `project/board/epics/`. For each epic, extract: `id`, `title`, `status`, `date_started`, `date_completed`, and the `stories` list.

3. **Scan stories** — For each story referenced in the epics list, read its file from `project/board/stories/`. Extract: `id`, `title`, `status`, `tasks` list.

4. **Scan tasks** — For each task referenced in each story, read its file from `project/board/tasks/`. Extract: `id`, `title`, `status`, `assigned_to`.

5. **Scan open rapports** — List all `.md` files in `project/rapports/problems/` that do **not** end in `.IGNORE.md`. List all `.md` files in `project/rapports/analysis/`.

6. **Check the queue** — If `project/queue/scrum_triggers.jsonl` is non-empty, note the number of pending triggers awaiting the scrum master.

7. **Print the summary** following the layout and icon conventions in `assets/output_format.md`.

8. If no epics exist, print: `No board items found. Run /pi-plan to define epics or /todo to add items.`
