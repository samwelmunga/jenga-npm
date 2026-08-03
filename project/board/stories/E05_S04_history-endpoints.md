---
id: E05_S04
epic_id: E05
title: History Endpoints
status: Done
date_created: 2026-05-05
date_started: 2026-05-05
date_completed: 2026-05-05
tasks: [E05_S04_T01, E05_S04_T02, E05_S04_T03]
---

# Story: History Endpoints

As a dashboard consumer, I want an endpoint that returns a combined project history of git commits and local rapport/session summaries so that I can display a unified timeline without reading raw files.

## Acceptance Criteria
- [ ] `GET /history` returns a chronological list of entries — each entry is either a `git_commit` or a `rapport` type
- [ ] Git entries include: SHA, author, date, subject, and body
- [ ] Rapport entries include: filename, date, and content summary parsed from local markdown files in `project/rapports/`
- [ ] Results are sorted by date descending by default
- [ ] Response follows the API contract envelope defined in E05_S01
- [ ] No GitHub API or external network calls are made

## Definition of Done
- [ ] Endpoint returns correct data for both entry types
- [ ] Handles empty git history or missing rapports directory gracefully
