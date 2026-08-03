---
id: E17_S04
epic_id: E17
title: Auto-Reconcile on Commit
status: Done
date_created: 2026-07-17
date_started: 2026-07-17
date_completed: 2026-07-17
tasks:
  - E17_S04_T01
---

# Story: Auto-Reconcile on Commit

As a developer using the `/commit` skill, I want the board to be automatically reconciled before any commit is made — so that the scrum board always reflects the true implementation state and no stale or drifted entries are committed alongside the work.

## Acceptance Criteria
- [ ] The `/commit` skill invokes `/reconcile` as its first step before any other action
- [ ] If reconcile detects and corrects drift, the user is informed of what changed before commit proceeds
- [ ] If reconcile finds no drift, commit continues without interruption
- [ ] The existing commit flow (prerequisite check, format, next-epic check) is preserved and runs after reconcile

## Definition of Done
- [ ] `skills/commit/SKILL.md` updated to invoke `/reconcile` as the initial action
- [ ] Tested: running `/commit` triggers reconcile first, then proceeds with the normal commit flow
