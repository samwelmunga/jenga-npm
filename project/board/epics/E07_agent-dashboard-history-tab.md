---
id: E07
title: Agent Dashboard — History Tab
status: Done
date_created: 2026-05-05
date_started:
date_completed: 2026-05-10
stories:
  - E07_S01
  - E07_S02
---

# Epic: Agent Dashboard — History Tab

## Purpose
Display a chronological project history view combining git commit log and session rapport/markdown summaries sourced entirely from local files. No GitHub API or external network calls.

## Definition of Done
- [ ] History tab renders a chronological list of git log entries and rapport summaries from `GET /history`
- [ ] Selecting a history entry shows an expanded detail panel (commit message, diff summary, rapport body)
