---
id: E13_S03
epic_id: E13
title: "`jenga status`"
status: Done
date_created: 2026-05-09
date_started:
date_completed: 2026-05-10
tasks: [E13_S03_T01, E13_S03_T02]
---

# Story: `jenga status`

As a user, I want to run `jenga status` to see the current state of the Jenga Router so that I can quickly verify the system is running and check what skill session is active.

## Acceptance Criteria
- [ ] Calls `ping` and `active_session` on the router and formats the results for display
- [ ] Output includes: router status (running/stopped), uptime, skill count, active session (or "none"), session duration if active
- [ ] If router is not running, prints "Router is not running. Run `jenga start` to start it." and exits 0 (not an error)
- [ ] If router is running with no active session: "✓ Router running | 12 skills loaded | No active session"
- [ ] If active session: "✓ Router running | 12 skills loaded | Active session: brainstorm (3m 24s)"

## Definition of Done
- [ ] Output is human-readable and fits in a single terminal block (< 10 lines)
- [ ] Works correctly in both "router up" and "router down" states
- [ ] Active session duration is accurate to within 5 seconds
