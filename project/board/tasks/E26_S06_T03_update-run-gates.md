---
id: E26_S06_T03
story_id: E26_S06
epic_id: E26
title: Add npm quality gates to run_gates.sh
status: Passed
date_created: 2026-07-31
date_started: 2026-08-01
date_completed: 2026-08-01
dates_previously_completed:
reopened_on:
reopened_reason:
assigned_to: developer
docs: []
---

# Task: Add npm quality gates to run_gates.sh

## Description
Update `skills/publish/scripts/run_gates.sh` to run npm-specific quality gates when the target type is `npm`. Gates to run:
1. `npm test` — if a `test` script is defined in the project's `package.json`
2. `npm run build` — if a `build` script is defined in the project's `package.json`
3. `npm run lint` — if a `lint` script is defined in the project's `package.json`

Each gate should be skipped gracefully (with a note) if the corresponding script is not defined in `package.json`. iOS gates must not run for npm targets.

## Prerequisites

## Acceptance Criteria
- [x] `run_gates.sh` runs `npm test`, `npm run build`, and `npm run lint` for `type: npm` targets
- [x] Each npm gate is skipped with a clear message if the script is not defined in `package.json`
- [x] iOS gates (`xcodebuild` etc.) do not run for npm targets
- [x] Script passes `shellcheck` after modification
- [x] Gate failures exit with code 2 (consistent with existing behaviour)
