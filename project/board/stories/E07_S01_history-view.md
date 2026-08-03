---
id: E07_S01
epic_id: E07
title: History View
status: Done
date_created: 2026-05-05
date_started: 2026-05-05
date_completed: 2026-05-05
tasks: [E07_S01_T01, E07_S01_T02]
---

# Story: History View

As a user, I want to see a unified project timeline in the dashboard combining git commits and session rapport summaries so that I can understand what has happened in the project over time.

## Acceptance Criteria
- [ ] History tab fetches data from `GET /history` via the shared API client
- [ ] Entries are displayed in reverse-chronological order
- [ ] Git commits and rapport summaries are visually distinguished (e.g. different icon or label)
- [ ] Each entry shows at minimum: date, type, and title/subject
- [ ] Empty history state is handled gracefully

## Definition of Done
- [ ] History view renders correctly with mixed entry types
- [ ] Chronological ordering is correct
