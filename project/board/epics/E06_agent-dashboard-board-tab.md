---
id: E06
title: Agent Dashboard — Board Tab
status: Done
date_created: 2026-05-05
date_started:
date_completed: 2026-05-10
stories:
  - E06_S01
  - E06_S02
  - E06_S03
---

# Epic: Agent Dashboard — Board Tab

## Purpose
Deliver a read-only visual board in the dashboard webapp that displays epics, stories, and tasks in a Jira-like layout. The webapp is architecturally independent of the API server — it connects via a configurable `API_BASE_URL` and can be served by jenga or run standalone against any compatible API.

## Definition of Done
- [ ] Web app scaffolded with configurable `API_BASE_URL`, shared API client, and tab routing
- [ ] Board tab renders epics, stories, and tasks with status indicators fetched from `GET /board`
- [ ] Graceful error/loading states when the API server is unreachable
- [ ] Spike document produced for editable board research
