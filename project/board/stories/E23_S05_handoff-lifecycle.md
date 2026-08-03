---
id: E23_S05
epic: E23
title: Handoff lifecycle management & /reconcile integration
status: Pending
date_created: 2026-07-11
date_started:
date_completed:
tasks: []
---

# Story: Handoff lifecycle management & /reconcile integration

## Goal
Complete the handoff lifecycle: archive handoffs when Tester passes, update
`/init` to scaffold the `project/handoffs/` directory, and extend `/reconcile`
to detect and clean up stale handoff files (tasks already Done in git/board but
whose handoff was never archived).

## Acceptance Criteria
- [ ] `project/handoffs/` and `project/handoffs/archive/` directories added to `/init` scaffold (`scripts/init.sh`)
- [ ] Tester agent (`agents/tester.md`) updated: on task `Passed`, move `project/handoffs/<task-id>.md` to `project/handoffs/archive/<task-id>.md` and update status to `archived`
- [ ] `/reconcile` skill (`skills/reconcile/SKILL.md`) updated to:
  - Scan `project/handoffs/` for `in_progress` files whose `task_id` maps to a task already marked `Done` or `Passed` on the board
  - For each stale handoff: prompt user "This handoff is for a completed task — archive it?" and move to archive on confirmation
  - Scan `project/handoffs/archive/` for files older than 30 days and surface them as candidates for deletion
- [ ] Handoff lifecycle documented in `skills/handoff/assets/lifecycle.md`:
  - `in_progress` → written/updated by Developer during implementation
  - `completed` → finalized by Developer before Tester invocation
  - `archived` → moved by Tester on pass, or by `/reconcile` for stale cleanup
- [ ] `project/handoffs/` directory excluded from git (added to `.gitignore`) — handoffs are session-local artifacts

## Notes
- Handoffs should NOT be committed to git — they are transient session state. Add to `.gitignore`.
- The archive directory is also local-only; it exists only for audit/recovery within the same machine
- If a task failed (Tester rejected), the handoff stays `in_progress` so `/pickup` can still find it
