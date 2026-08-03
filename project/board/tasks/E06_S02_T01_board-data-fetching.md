---
id: E06_S02_T01
story_id: E06_S02
epic_id: E06
title: Board tab data fetching and state management
status: Done
date_created: 2026-05-05
date_started: 2026-05-05
date_completed: 2026-05-05
assigned_to: developer
---

# Task: Board tab data fetching and state management

## Description
Wire up the Board tab to fetch data from `GET /board` using the shared API client (E06_S01_T02). Manage three states: loading, error, and success (data loaded). On mount, trigger the fetch and transition between states accordingly. On error, display `<ErrorMessage />` with a retry button that re-triggers the fetch. On success, pass the board data down to the layout component. Store the fetched data in local component state (no global store required for MVP).

## Prerequisites
- E06_S01_T02 (shared API client) must be complete.
- E06_S01_T04 (loading/error components) must be complete.

## Acceptance Criteria
- [ ] Board tab calls `GET /board` via the shared API client on mount
- [ ] `<LoadingSpinner />` is shown while the request is in-flight
- [ ] `<ErrorMessage />` with a retry button is shown on fetch failure
- [ ] On success, board data is passed to the layout component as props
- [ ] Re-fetch is triggered when the retry button is clicked
