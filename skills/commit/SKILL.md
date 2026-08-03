---
name: commit
description: Commit implemented epic, story, or task work using the EST naming convention. Also handles user-action prerequisites and new-epic boundaries. Use after completing any EST work item.
keywords:
  - commit
  - save
  - git commit
  - done
  - push
examples:
  - "commit this work"
  - "save my changes"
---

# Commit — Commit Completed Work

## Instructions

If no epic, task, or story has been implemented, exit with the message: "No implementation to commit."

1. **Verify user-action prerequisites** — Check whether an `_INSTRUCTIONS.md` file exists for this task at `project/board/tasks/<E##_S##_T##>_INSTRUCTIONS.md`. If the task has out-of-scope prerequisites but no instructions file was created, create one now using `assets/user_instructions_template.md`. If one already exists, surface it to the user as a reminder. (The developer should have created this file during task intake — this is a final safety check.)

2. **Commit** using the following format:
   - **Epic:** `epic(<Epic Title>): <MAX_50_CHAR_SUMMARY>`
   - **Task/Story:** `story(<Epic Title>_<Story Title>): <MAX_50_CHAR_SUMMARY>`
   
   **Fallback: Group changes logically** — prefer one commit per coherent unit of work, but don't force splits. When in doubt, keep it together.

3. **Check for next epic** — If a new epic is to be started, inform the user that a new conversation should be initiated. If there are no subsequent epics left, show the message: "All Done! 🎉"
