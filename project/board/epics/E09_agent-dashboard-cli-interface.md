---
id: E09
title: Agent Dashboard — CLI Interface (PoC)
status: Done
date_created: 2026-05-05
date_started:
date_completed: 2026-05-10
stories:
  - E09_S01
  - E09_S02
---

# Epic: Agent Dashboard — CLI Interface (PoC)

## Purpose
Deliver a minimal proof-of-concept CLI interface for starting the jenga API server and opening the dashboard from the terminal. This epic is intentionally thin — it validates the end-to-end flow without building a full terminal emulator. Implemented last, after the API layer and webapp are stable.

## Definition of Done
- [ ] `jenga dashboard start` starts the API server (and optionally serves the web app) from a single command
- [ ] `jenga dashboard open` opens the dashboard in the default browser, or prints the URL if no browser is available
