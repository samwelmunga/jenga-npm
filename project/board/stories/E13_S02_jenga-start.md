---
id: E13_S02
epic_id: E13
title: "`jenga start`"
status: Passed
date_created: 2026-05-09
date_started:
date_completed: 2026-05-10
tasks: [E13_S02_T01, E13_S02_T02]
---

# Story: `jenga start`

As a user, I want to run `jenga start` to launch the Jenga Router as a background daemon so that the hook has a live router to connect to during my Claude Code session.

## Acceptance Criteria
- [ ] Reads `jenga.cli.json` to determine router configuration before starting
- [ ] Spawns `mcp/router/index.js` as a detached background process (survives terminal close)
- [ ] Writes the router PID to the PID file path defined in config
- [ ] Calls `ping` on the router within 3 seconds to confirm it is responsive before printing success
- [ ] If a router process is already running (PID file exists and process is alive), prints "Router already running (PID: <n>)" and exits 0
- [ ] If startup fails (no response to ping within 3s), prints an error with the router log path and exits non-zero
- [ ] Prints: "✓ Jenga Router started (PID: <n>)"

## Definition of Done
- [ ] `jenga start` followed by `jenga status` shows an active router
- [ ] Running `jenga start` twice does not launch two router processes
- [ ] Router survives the terminal that started it being closed
