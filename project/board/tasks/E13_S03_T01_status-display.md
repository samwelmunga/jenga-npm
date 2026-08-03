---
id: E13_S03_T01
story_id: E13_S03
epic_id: E13
title: Implement `jenga status` display command
status: Passed
date_created: 2026-05-09
date_started: 2026-05-09
date_completed: 2026-05-09
assigned_to: developer
---

# Task: Implement `jenga status` display command

## Description
Implement `jenga status` to call `ping` and `active_session` on the router and format the results. Display: router status (running/stopped), uptime, skill count, active session (or "none"), session duration if active. If router is not running, print "Router is not running. Run `jenga start` to start it." and exit 0.

## Prerequisites
None

## Acceptance Criteria
- [x] Router up, no session: "✓ Router running | 12 skills loaded | No active session"
- [x] Router up, active session: "✓ Router running | 12 skills loaded | Active session: brainstorm (3m 24s)"
- [x] Router down: prints guidance message, exits 0
- [x] Output fits in < 10 lines
- [x] Session duration accurate to within 5 seconds
