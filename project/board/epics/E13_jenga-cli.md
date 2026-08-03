---
id: E13
title: Jenga CLI
status: Done
date_created: 2026-05-09
date_started:
date_completed: 2026-05-10
stories:
  - E13_S01
  - E13_S02
  - E13_S03
  - E13_S04
---

# Epic: Jenga CLI

## Purpose
Create the `jenga` command-line tool that users run to configure and operate the Jenga framework. The CLI provides three core commands: `jenga init` (first-time setup wizard that writes `jenga.cli.json` and injects the router hook into the agent's settings), `jenga start` (starts the router as a background daemon), and `jenga status` (shows active session, loaded skills, router uptime). The CLI is packaged via the `bin` field in `package.json` and installable globally via `npm install -g`.

## Definition of Done
- [ ] `jenga init` wizard runs, writes `jenga.cli.json`, and injects hook config — idempotent on re-run
- [ ] `jenga start` launches the router daemon, writes PID file, and confirms it is responsive before exiting
- [ ] `jenga status` queries the router and prints active skill session, skill count, and uptime
- [ ] `package.json` `bin` field points to `bin/jenga.js`; `npm install -g` makes `jenga` available globally
