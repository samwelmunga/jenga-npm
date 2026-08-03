---
id: E23_S01
epic: E23
title: Handoff document schema & Developer agent rolling checkpoint
status: Pending
date_created: 2026-07-11
date_started:
date_completed:
tasks: []
---

# Story: Handoff document schema & Developer agent rolling checkpoint

## Goal
Define the handoff document schema and update the Developer agent to write and
update a handoff file at every major implementation milestone. The handoff must
be usable by both the user (human-readable checklist) and the agent (machine-readable
JSON block). A stub is written at task start; the file is updated after each
meaningful step; it is finalized when the Tester is invoked.

## Acceptance Criteria
- [ ] Handoff schema defined and documented (template at `skills/handoff/assets/handoff_template.md`)
- [ ] Schema includes: `task_id`, `story_id`, `epic_id`, `worktree_path`, `status` (in_progress | completed | archived), `interrupted_at`, `last_commit`
- [ ] Human-readable sections: task summary, ✅ completed steps, ⬜ remaining steps checklist, 🗂 files modified, ⚠️ known issues
- [ ] Machine-readable section: JSON block with `completed_steps[]`, `remaining_steps[]`, `worktree_path`, `last_commit`
- [ ] Developer agent (`agents/developer.md`) updated to:
  - Write stub handoff at task start (status: `in_progress`, all steps in `remaining_steps`)
  - Update handoff after each major milestone (move step from remaining → completed, update `last_commit`)
  - Finalize handoff (status: `completed`, remaining: []) before invoking Tester
- [ ] Handoff files stored at `project/handoffs/<task-id>.md`
- [ ] `project/handoffs/` directory created by `/init` scaffold script

## Notes
- "Major milestone" = any file created or significantly modified, or any discrete step in the task plan completed
- The rolling checkpoint approach means the handoff is always current — no dependency on detecting token limits
- Finalized handoffs (status: completed) are not yet archived — that happens in S05 after Tester passes
