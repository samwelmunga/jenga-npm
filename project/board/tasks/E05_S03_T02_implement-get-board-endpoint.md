---
id: E05_S03_T02
story_id: E05_S03
epic_id: E05
title: Implement GET /board Endpoint
status: Done
date_created: 2026-05-05
date_started: 2026-05-05
date_completed: 2026-05-05
assigned_to: developer
---

# Task: Implement GET /board Endpoint

## Description
Add a `GET /board` route to the API server that calls the board parser and returns all epics with their nested stories and tasks in the standard API envelope.

The handler must:
- Invoke the board parser on every request (no caching in v1)
- Wrap the result array in `successResponse(data, meta)`
- Return HTTP 200 on success
- Return HTTP 500 with a standard `errorResponse` body if the parser throws

## Prerequisites
- E05_S03_T01 (board parser implemented)
- E05_S01_T02 (envelope helpers)
- E05_S02_T01 (server scaffolded)

## Acceptance Criteria
- [ ] `GET /board` returns HTTP 200 with all epics, stories, and tasks
- [ ] Response body follows `ApiEnvelope` shape (`data`, `meta`, `error`)
- [ ] Statuses, IDs, titles, and all date fields are present in the response
- [ ] Parser errors result in HTTP 500 with a standard error envelope
- [ ] Endpoint is reachable via `curl http://localhost:3001/board`
