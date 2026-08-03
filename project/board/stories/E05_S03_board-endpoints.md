---
id: E05_S03
epic_id: E05
title: Board Endpoints
status: Done
date_created: 2026-05-05
date_started: 2026-05-05
date_completed: 2026-05-05
tasks: [E05_S03_T01, E05_S03_T02, E05_S03_T03]
---

# Story: Board Endpoints

As a dashboard consumer, I want API endpoints that return the full scrum board parsed from local markdown files so that I can render epics, stories, and tasks without reading files directly.

## Acceptance Criteria
- [ ] `GET /board` returns all epics with their nested stories and tasks, parsed from `project/board/`
- [ ] `GET /board/:epicId` returns a single epic with its stories and tasks
- [ ] Response follows the API contract envelope defined in E05_S01
- [ ] Returns `404` with a standard error body if `:epicId` does not exist
- [ ] Statuses, IDs, titles, and dates are all included in the response

## Definition of Done
- [ ] Both endpoints return correct data against the live board files
- [ ] 404 behaviour is confirmed for unknown epic IDs
