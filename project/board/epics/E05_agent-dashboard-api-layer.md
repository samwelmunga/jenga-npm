---
id: E05
title: Agent Dashboard — API Layer
status: Done
date_created: 2026-05-05
date_started:
date_completed: 2026-05-10
stories:
  - E05_S01
  - E05_S02
  - E05_S03
  - E05_S04
  - E05_S05
---

# Epic: Agent Dashboard — API Layer

## Purpose
Make jenga run as a headless local HTTP/JSON server that exposes scrum board state, project history, and architecture metadata through a well-designed, integration-friendly REST API. MCP bindings are supported as a thin optional layer on top. The server is architecturally independent of any specific consumer — the dashboard webapp, CLI tools, and future third-party integrations all connect to it the same way.

## Definition of Done
- [ ] `GET /health` returns server status
- [ ] `GET /board` and `GET /board/:epicId` return parsed board data from markdown files
- [ ] `GET /history` returns git log entries and local rapport/markdown summaries
- [ ] `GET /architecture` returns tech stack and dependency versions parsed from project config files
- [ ] API contract document exists (resource naming, response envelope, error format, versioning)
- [ ] Server starts and shuts down gracefully
- [ ] Web app and API can run independently (decoupled by `API_BASE_URL`)
