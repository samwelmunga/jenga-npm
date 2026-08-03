---
id: E23_S02
epic: E23
title: /handoff skill — explicit handoff trigger
status: Pending
date_created: 2026-07-11
date_started:
date_completed:
tasks: []
---

# Story: /handoff skill — explicit handoff trigger

## Goal
Create a `/handoff` skill the user can invoke when they see tokens running low.
The skill forces the Developer agent to immediately write or update the handoff
document for the current task, then presents the user with a clear summary:
what has been done, what remains to do manually, and which files were touched.

## Acceptance Criteria
- [ ] `skills/handoff/SKILL.md` created with correct frontmatter (`name`, `description`, `keywords`, `examples`)
- [ ] Skill determines the currently active task (from `project/todo.md` + active worktree)
- [ ] Skill writes/updates `project/handoffs/<task-id>.md` immediately using the schema from S01
- [ ] After writing, skill outputs to the user:
  - Task title and parent story/epic
  - ✅ What has been completed so far (from handoff)
  - ⬜ What remains (human-readable checklist the user can follow manually)
  - 🗂 Files modified so far
  - ⚠️ Any known issues or watch-outs
  - Instruction: "Run `/pickup` in a new session when ready to hand back to the agent"
- [ ] If no active task is detected, skill informs the user and exits gracefully
- [ ] Skill listed in `/help` output with keywords: `handoff`, `tokens`, `take over`, `manual`

## Notes
- This skill is intentionally lightweight — it delegates writing to the Developer agent's handoff logic (S01), it just forces an immediate write
- The output is designed to be the last thing the user reads before the session dies — make it scannable
