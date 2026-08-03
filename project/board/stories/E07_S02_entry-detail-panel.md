---
id: E07_S02
epic_id: E07
title: Entry Detail Panel
status: Done
date_created: 2026-05-05
date_started: 2026-05-05
date_completed: 2026-05-05
tasks: [E07_S02_T01, E07_S02_T02]
---

# Story: Entry Detail Panel

As a user, I want to click a history entry and see its full detail so that I can read a complete commit message or rapport without leaving the dashboard.

## Acceptance Criteria
- [ ] Clicking a history entry opens a detail panel or modal
- [ ] For git commits: shows full commit message, author, date, and diff summary if available
- [ ] For rapports: shows full markdown content rendered as HTML
- [ ] Panel can be dismissed to return to the history list
- [ ] Detail is loaded from the data already fetched (no additional API call required unless content is paginated)

## Definition of Done
- [ ] Detail panel renders correctly for both entry types
- [ ] Panel opens and closes without navigation side-effects
