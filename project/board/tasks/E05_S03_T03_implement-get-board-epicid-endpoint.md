---
id: E05_S03_T03
story_id: E05_S03
epic_id: E05
title: Implement GET /board/:epicId Endpoint
status: Done
date_created: 2026-05-05
date_started: 2026-05-05
date_completed: 2026-05-05
assigned_to: developer
---

# Task: Implement GET /board/:epicId Endpoint

## Description
Add a `GET /board/:epicId` route that returns a single epic (with its nested stories and tasks) identified by the `epicId` URL parameter (e.g. `E05`).

The handler must:
- Parse the full board, then find the epic whose `id` matches `:epicId` (case-insensitive)
- Return HTTP 200 with the matching epic object wrapped in `successResponse`
- Return HTTP 404 with `errorResponse('EPIC_NOT_FOUND', 'Epic <epicId> does not exist')` when no match is found
- Return HTTP 500 on unexpected parser errors

## Prerequisites
- E05_S03_T01 (board parser implemented)
- E05_S03_T02 (GET /board implemented — shares parser logic)
- E05_S01_T02 (envelope helpers)

## Acceptance Criteria
- [ ] `GET /board/E05` returns HTTP 200 with the matching epic
- [ ] Response follows `ApiEnvelope` shape
- [ ] Request for a non-existent epicId returns HTTP 404 with `code: "EPIC_NOT_FOUND"`
- [ ] 404 body includes a human-readable `message` naming the requested epicId
- [ ] IDs, titles, statuses, and dates are all present in the returned epic object
