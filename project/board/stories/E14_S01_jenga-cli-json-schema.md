---
id: E14_S01
epic_id: E14
title: "`jenga.cli.json` Schema"
status: Passed
date_created: 2026-05-09
date_started:
date_completed: 2026-05-10
tasks: [E14_S01_T01, E14_S01_T02, E14_S01_T03]
---

# Story: `jenga.cli.json` Schema

As the router and CLI, I want a validated `jenga.cli.json` config schema so that misconfiguration is caught early with clear error messages rather than silent failures at runtime.

## Acceptance Criteria
- [ ] Schema defines the following fields:
  - `skillsPath` (string, required) — path to skills directory relative to project root
  - `matchThreshold` (number, required, 0–1) — confidence cutoff for skill matching
  - `sessionTimeout` (number, required) — ms before an idle session auto-expires
  - `agentTarget` (string, required) — target agent identifier (`"claude"`, `"copilot"`, `"custom"`)
- [ ] Router validates config on startup using the schema; exits non-zero with a descriptive error if invalid
- [ ] `jenga.cli.json.example` is created in the project root as a reference template
- [ ] Schema is documented in `docs/` or inline in the example file

## Definition of Done
- [ ] Missing required field: router exits with "Missing required field: skillsPath" (or equivalent)
- [ ] `matchThreshold` outside 0–1: clear validation error
- [ ] Valid config: router starts normally
