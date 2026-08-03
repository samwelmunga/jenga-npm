---
id: E15_S01
epic: E15
title: Project-scoped router state
status: Done
date_created: 2026-05-10
tasks:
  - E15_S01_T01
  - E15_S01_T02
---

# Story: Project-scoped router state

## Goal
Move all runtime state out of the jenga install directory and into `.jenga/` inside the calling project. `jenga start`, `jenga stop`, and `jenga status` all resolve their state paths from `process.cwd()`.

## Acceptance Criteria
- [ ] PID file written to `<cwd>/.jenga/router.pid`, not inside the jenga package
- [ ] Session file (if any) written to `<cwd>/.jenga/session.json`
- [ ] `jenga stop` reads PID from `<cwd>/.jenga/router.pid`
- [ ] `jenga status` reads state from `<cwd>/.jenga/`
- [ ] Running `jenga start` from two different projects simultaneously works without conflict
- [ ] `.jenga/` is added to `.gitignore` template written by `jenga init`
