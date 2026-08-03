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
