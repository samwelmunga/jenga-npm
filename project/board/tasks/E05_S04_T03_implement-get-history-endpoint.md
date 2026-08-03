---
id: E05_S04_T03
story_id: E05_S04
epic_id: E05
title: Implement GET /history Endpoint
status: Done
date_created: 2026-05-05
date_started: 2026-05-05
date_completed: 2026-05-05
assigned_to: developer
---

# Task: Implement GET /history Endpoint

## Description
Add a `GET /history` route that combines git commit entries and rapport entries, sorts them by date descending, and returns them in the standard API envelope.

The handler must:
- Call the git log reader and rapport parser in parallel (or sequentially)
- Merge the two arrays into a single list
- Sort by `date` descending (most recent first)
- Wrap in `successResponse(data, meta)` and return HTTP 200
- Return HTTP 500 with `errorResponse` on unexpected errors

Optional query params for v1 (implement if straightforward):
- `?limit=N` — return only the first N entries (default: no limit)
- `?type=git_commit|rapport` — filter by entry type

## Prerequisites
- E05_S04_T01 (git log reader)
- E05_S04_T02 (rapport parser)
- E05_S01_T02 (envelope helpers)
- E05_S02_T01 (server scaffolded)

## Acceptance Criteria
- [ ] `GET /history` returns HTTP 200 with a combined list of `git_commit` and `rapport` entries
- [ ] List is sorted by `date` descending
- [ ] Each entry retains its `type` field
- [ ] Response follows `ApiEnvelope` shape
- [ ] No external network calls are made
- [ ] Endpoint is reachable via `curl http://localhost:3001/history`
