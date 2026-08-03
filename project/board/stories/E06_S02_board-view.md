---
id: E06_S02
epic_id: E06
title: Board View
status: Done
date_created: 2026-05-05
date_started: 2026-05-05
date_completed: 2026-05-05
tasks: [E06_S02_T01, E06_S02_T02, E06_S02_T03]
---

# Story: Board View

As a user, I want to see my scrum board rendered visually in the dashboard so that I can review epics, stories, and tasks at a glance without reading markdown files.

## Acceptance Criteria
- [ ] Board tab fetches data from `GET /board` via the shared API client
- [ ] Epics are displayed as columns or grouped sections
- [ ] Each epic shows its stories; each story shows its tasks
- [ ] Status is visually indicated for epics, stories, and tasks (e.g. Pending, In Progress, Done)
- [ ] Board is read-only — no editing, drag-and-drop, or inline actions
- [ ] Empty board state is handled gracefully

## Definition of Done
- [ ] Board renders correctly against live board data
- [ ] All statuses display correctly
- [ ] View is read-only with no interactive editing affordances
