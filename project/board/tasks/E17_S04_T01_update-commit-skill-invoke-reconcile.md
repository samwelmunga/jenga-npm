---
id: E17_S04_T01
story_id: E17_S04
epic_id: E17
title: Update /commit skill to invoke /reconcile as initial step
status: Passed
date_created: 2026-07-17
date_started: 2026-07-17
date_completed: 2026-07-17
dates_previously_completed:
reopened_on:
reopened_reason:
assigned_to: developer
---

# Task: Update /commit skill to invoke /reconcile as initial step

## Description
Modify `skills/commit/SKILL.md` so that the very first action in the commit flow is to invoke `/reconcile`. This ensures the scrum board is always in sync with the actual implementation state before any commit is made. After reconcile completes, the normal commit flow continues unchanged (prerequisite check → commit → next-epic check).

## Prerequisites
None.

## Acceptance Criteria
- [ ] `skills/commit/SKILL.md` has `/reconcile` as its first instruction step, before any other action
- [ ] The instruction describes the two outcomes: (a) drift found — inform user of changes before proceeding; (b) no drift — continue silently
- [ ] All existing commit steps (user-action prerequisite check, commit format, next-epic check) are preserved after the reconcile step
