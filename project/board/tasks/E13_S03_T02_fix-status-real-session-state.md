---
id: E13_S03_T02
story_id: E13_S03
epic_id: E13
title: Fix jenga status to display real session state from .session.json
status: Done
date_created: 2026-05-10
date_started: 2026-05-10
date_completed: 2026-05-10
assigned_to: developer
---

# Task: Fix jenga status to display real session state from .session.json

## Description
`jenga status` currently hardcodes "No active session" regardless of actual router state (see `lib/commands/status.js` line 36 comment: "MCP client integration in E11_S04_T01"). The misleading hint "Run 'jenga start' again to check if router responds to ping" also creates a confusing loop since `jenga start` doesn't ping — it just prints "Router already running".

Fix `jenga status` to:
1. Read `mcp/router/.session.json` to get real session state (written by E11_S04_T03)
2. Display the active skill name and elapsed duration if session is active
3. Show "No active session" only when the file confirms no session is running
4. Remove the misleading "Run 'jenga start' again to check if router responds to ping" line

Expected output formats:
- No session: `✓ Router running (PID: 11021) | No active session`
- Active session: `✓ Router running (PID: 11021) | Active session: brainstorm (3m 24s)`

## Prerequisites
- E11_S04_T03 (router must write .session.json)
- E13_S03_T01

## Acceptance Criteria
- [ ] `jenga status` reads `.session.json` to determine actual session state
- [ ] If session active: shows skill name and elapsed time since `startedAt`
- [ ] If no session: shows "No active session" (no misleading hint)
- [ ] If `.session.json` is missing or unreadable: falls back gracefully to "No active session"
- [ ] Misleading "Run 'jenga start' again..." hint is removed
- [ ] Story E13_S03 acceptance criteria are fully met
