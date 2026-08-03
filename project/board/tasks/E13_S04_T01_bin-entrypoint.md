---
id: E13_S04_T01
story_id: E13_S04
epic_id: E13
title: Create `bin/jenga.js` CLI entrypoint with subcommand routing
status: Passed
date_created: 2026-05-09
date_started: 2026-05-09
date_completed: 2026-05-09
assigned_to: developer
---

# Task: Create `bin/jenga.js` CLI entrypoint with subcommand routing

## Description
Create `bin/jenga.js` with a `#!/usr/bin/env node` shebang (executable). Implement subcommand routing for `init`, `start`, `status` — each delegating to their respective module. Unknown subcommands print usage help and exit non-zero. Implement `--version` (print from `package.json`) and `--help` (usage summary).

## Prerequisites
None

## Acceptance Criteria
- [x] `bin/jenga.js` exists, is executable, has correct shebang
- [x] `jenga init`, `jenga start`, `jenga status` all delegate correctly
- [x] Unknown subcommands: usage help, exit non-zero
- [x] `jenga --version` prints version from `package.json`
- [x] `jenga --help` prints concise usage summary
