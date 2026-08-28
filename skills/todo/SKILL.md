---
name: todo
description: Add missions to the project todo list (project/todo.md), optionally linking them to epics and stories. Loops until the user is done, then optionally executes the list.
keywords:
  - todo
  - add task
  - queue work
  - backlog
  - add to list
examples:
  - "add this to the todo list"
  - "queue this as a task"
metadata: 
  prefered_agent: scrum-master
---

# Todo — Add Missions to the Todo List

## Instructions

1. **Ensure `project/todo.md` exists** — If it doesn't exist, it will be auto-created by `todo_manager.sh` — no manual action needed.

2. **Ask the user about the mission:**
   - Where do you want to do this?
   - What would you like to do?
   - What is the goal?

3. **Classify the mission** — Check if it fits into:
   - An existing story
   - A new story inside an existing Epic
   - A new story inside a new Epic
   - None of the above

4. **Update project documentation** — Add the mission to the appropriate files under `project/board/epics/` and `project/board/stories/` if applicable.
   - If the mission involves implementing or modifying a skill, apply the **Skill Implementation Principle — Scripts Over Inline Logic** (see `CLAUDE.md` / `AGENTS.md`): note in the story/task's acceptance criteria that deterministic, repeatable steps must be offloaded to scripts under `skills/<name>/scripts/` (or `scripts/`) rather than encoded as inline agent instructions in `SKILL.md`.
   - If the user indicates the mission is high-risk, or explicitly asks to flag it, set an elevated caution tier directly on the story or task frontmatter: `crucial_level` (one of `advisory`, `gated`, `locked` — see `templates/SCRUM_BOARD_SCHEMA.md` for valid values and their meaning), `crucial_set_by: user`, and `crucial_note` capturing the user's stated reason. This user-initiated flag is written immediately — it does not require the confirm-before-write gate, which applies only to scrum-master-*proposed* caution tiers (a separate, heuristic-driven path).

5. **Add to `project/todo.md`** by running:
   ```
   bash scripts/todo_manager.sh add '<mission title>: <Epic no.>_<Story no.>'
   ```
   The epic and story reference is only required if the mission is assigned to one.

6. **Ask the user**: "Add another todo" or "Done"?
   - If **add another** — go back to step 2.
   - If **done** — ask if they want to execute the todo list.
     - If **yes** — invoke the `/do` skill.
     - If **no** — exit.
