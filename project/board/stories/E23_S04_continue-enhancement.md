---
id: E23_S04
epic: E23
title: /continue enhancement — handoff-aware session start
status: Pending
date_created: 2026-07-11
date_started:
date_completed:
tasks: []
---

# Story: /continue enhancement — handoff-aware session start

## Goal
Update the existing `/continue` skill to check `project/handoffs/` for open
(status: `in_progress`) handoff files at the start of every session. If any
are found, surface them to the user before picking the next pending task —
giving the user the opportunity to `/pickup` the interrupted work rather than
skipping past it.

## Acceptance Criteria
- [ ] `skills/continue/SKILL.md` updated to include a handoff check as its first step
- [ ] Check: read `project/handoffs/` for any `.md` files with `status: in_progress`
- [ ] If **no open handoffs**: continue existing behavior (check board, pick next pending item)
- [ ] If **open handoffs found**: present the user with:
  - List of interrupted tasks (task ID, title, parent story/epic, when interrupted)
  - Options:
    1. `/pickup` one of the interrupted tasks
    2. Skip and continue to next pending board item
    3. Show details of a specific handoff before deciding
- [ ] `/pickup` option: invoke `/pickup` skill with the selected handoff pre-selected (no re-listing needed)
- [ ] Skip option: proceeds with existing `/continue` behavior, leaves handoff files in place
- [ ] If multiple open handoffs exist, list all but recommend the most recently interrupted one first

## Notes
- This is an enhancement to an existing skill — be careful not to break existing `/continue` behavior
- The check should be fast — do not scan the whole project, only read `project/handoffs/*.md` frontmatter
- Open handoffs should feel like a gentle prompt, not a blocker — the user can always skip
