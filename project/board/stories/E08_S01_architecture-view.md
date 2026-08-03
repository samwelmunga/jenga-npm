---
id: E08_S01
epic_id: E08
title: Architecture View
status: Done
date_created: 2026-05-05
date_started: 2026-05-05
date_completed: 2026-05-05
tasks: [E08_S01_T01, E08_S01_T02]
---

# Story: Architecture View

As a user, I want to see my project's tech stack and dependency versions displayed in the dashboard so that I have a quick reference for what the project is built with.

## Acceptance Criteria
- [ ] Architecture tab fetches data from `GET /architecture` via the shared API client
- [ ] Tech stack is displayed as a set of cards or a structured list
- [ ] Dependencies are displayed in a table with: name, version, and type (runtime/dev/peer)
- [ ] Empty or unavailable data states are handled gracefully

## Definition of Done
- [ ] Architecture view renders correctly against live project config data
- [ ] Both tech stack and version table sections are present
