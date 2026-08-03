---
id: E05_S05
epic_id: E05
title: Architecture Endpoints
status: Done
date_created: 2026-05-05
date_started: 2026-05-05
date_completed: 2026-05-05
tasks: [E05_S05_T01, E05_S05_T02]
---

# Story: Architecture Endpoints

As a dashboard consumer, I want an endpoint that returns the project's tech stack and dependency versions parsed from local config files so that I can display an up-to-date architecture overview.

## Acceptance Criteria
- [ ] `GET /architecture` returns tech stack entries and a dependency version map
- [ ] Dependency versions are parsed from `package.json`, `project.config.json`, or other relevant local config files
- [ ] Each dependency entry includes: name, version, and type (runtime/dev/peer)
- [ ] Response follows the API contract envelope defined in E05_S01
- [ ] No live registry lookups (npm, PyPI, etc.) are made

## Definition of Done
- [ ] Endpoint returns accurate data parsed from project files
- [ ] Handles missing or malformed config files gracefully
