---
id: E13_S01
epic_id: E13
title: "`jenga init`"
status: Passed
date_created: 2026-05-09
date_started:
date_completed: 2026-05-10
tasks: [E13_S01_T01, E13_S01_T02, E13_S01_T03]
---

# Story: `jenga init`

As a new user, I want to run `jenga init` and be guided through a short wizard so that the Jenga framework is fully configured with no manual file editing.

## Acceptance Criteria
- [ ] Wizard prompts: (1) agent selection (claude / copilot / custom), (2) skills directory path (default: `skills/`), (3) match threshold (default: 0.75), (4) session timeout in minutes (default: 5)
- [ ] Writes `jenga.cli.json` to the project root with the collected values
- [ ] Calls settings injection (E12_S03) to register the hook in `settings.json`
- [ ] Confirms router is registered and prints next-step instructions: "Run `jenga start` to start the router"
- [ ] Re-runnable: if `jenga.cli.json` already exists, shows current values as defaults and only updates changed fields
- [ ] Exits with clear success/failure message

## Definition of Done
- [ ] New project: `jenga init` produces a valid `jenga.cli.json` and updated `settings.json`
- [ ] Re-run: existing config values shown as defaults; no data loss on re-run
- [ ] Wizard is completable in < 60 seconds with all defaults accepted via Enter
