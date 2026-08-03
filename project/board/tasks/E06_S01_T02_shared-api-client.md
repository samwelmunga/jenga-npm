---
id: E06_S01_T02
story_id: E06_S01
epic_id: E06
title: Implement shared API client
status: Done
date_created: 2026-05-05
date_started: 2026-05-05
date_completed: 2026-05-05
assigned_to: developer
---

# Task: Implement shared API client

## Description
Create a shared API client module (e.g. `dashboard/src/api/client.js`) that all data-fetching in the app goes through. It must read `API_BASE_URL` from the environment and prepend it to all request paths. The client should handle: network errors, non-2xx HTTP responses, and the standard JSON response envelope (unwrapping `data` from `{ ok, data, error }` or equivalent). Export typed helper functions: `get(path)`, and optionally `post(path, body)` for future use.

## Prerequisites
- E06_S01_T01 (scaffold) must be complete so the module has a project to live in.

## Acceptance Criteria
- [ ] `dashboard/src/api/client.js` (or `.ts`) exists
- [ ] Base URL is sourced from `API_BASE_URL` env var
- [ ] `get(path)` returns unwrapped data on success
- [ ] Network errors and non-2xx responses throw/reject with a consistent error shape `{ status, message }`
- [ ] Response envelope is parsed and unwrapped transparently
- [ ] Module is re-exported from a barrel (e.g. `dashboard/src/api/index.js`)
