---
id: E07_S02_T01
story_id: E07_S02
epic_id: E07
title: Implement entry detail panel/modal component
status: Done
date_created: 2026-05-05
date_started: 2026-05-05
date_completed: 2026-05-05
assigned_to: developer
---

# Task: Implement entry detail panel/modal component

## Description
Build a detail panel or modal that opens when a history entry is clicked. The panel must display entry-type-specific fields: for git commits show full commit message, author, date, and diff summary if available; for rapports show the full content. The panel must be dismissible to return the user to the history list. Detail data comes from the already-fetched entries — no additional API call is required.

## Prerequisites
- E07_S01_T01 and E07_S01_T02 — History list must be implemented

## Acceptance Criteria
- [ ] Clicking a history entry opens the detail panel/modal
- [ ] For git commits: full commit message, author, and date are displayed; diff summary is shown if present in the data
- [ ] For rapports: full content is displayed (markdown rendering handled in T02)
- [ ] Panel/modal has a dismiss/close action that returns focus to the history list
- [ ] No additional API call is made when opening the detail panel
