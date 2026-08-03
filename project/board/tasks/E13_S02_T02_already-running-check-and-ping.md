---
id: E13_S02_T02
story_id: E13_S02
epic_id: E13
title: Add already-running check and startup ping health check
status: Passed
date_created: 2026-05-09
date_started: 2026-05-09
date_completed: 2026-05-09
assigned_to: developer
---

# Task: Add already-running check and startup ping health check

## Description
Before spawning, check if a PID file exists and the process is alive. If so, print "Router already running (PID: <n>)" and exit 0. After spawning, call `ping` on the router within 3 seconds to confirm it is responsive. If no response within 3s, print error with router log path and exit non-zero.

## Prerequisites
- E13_S02_T01

## Acceptance Criteria
- [x] Running `jenga start` twice does not launch two router processes
- [x] Ping health check confirms router responsiveness before printing success
- [x] Failed ping: error message with log path, exit non-zero
