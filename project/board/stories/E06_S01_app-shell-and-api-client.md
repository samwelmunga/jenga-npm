---
id: E06_S01
epic_id: E06
title: App Shell & API Client
status: Done
date_created: 2026-05-05
date_started: 2026-05-05
date_completed: 2026-05-05
tasks: [E06_S01_T01, E06_S01_T02, E06_S01_T03, E06_S01_T04]
---

# Story: App Shell & API Client

As a developer, I want the web app scaffolded with a configurable API base URL and tab routing so that the dashboard can connect to any running jenga API server and navigate between tabs.

## Acceptance Criteria
- [ ] Web app is scaffolded with a chosen frontend framework
- [ ] `API_BASE_URL` is configurable via environment variable (defaults to `http://localhost:3001`)
- [ ] A shared API client handles all fetch requests, including error handling and the response envelope
- [ ] Tab/route structure exists for: Board, History, Architecture
- [ ] Loading and error states are handled consistently across all data-fetching components
- [ ] App can be run standalone (separate origin from API) without CORS issues assuming server allows it

## Definition of Done
- [ ] App starts, connects to a running API server, and navigates between empty tab placeholders
- [ ] API client correctly surfaces errors when the server is unreachable
