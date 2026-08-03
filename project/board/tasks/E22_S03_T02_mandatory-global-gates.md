---
id: E22_S03_T02
story_id: E22_S03
epic_id: E22
title: Mandatory global gates — build and test always enforced
status: Passed
date_created: 2026-07-11
date_started:
date_completed:
assigned_to: developer
---

# Task: Mandatory global gates — build and test always enforced

## Description
Implement the two mandatory global pre-deploy gates within `run_gates.sh`: **build** and **test**. These gates run unconditionally on every `pre` phase invocation; they cannot be disabled by `publish.json` config.

Implementation requirements:
- `build` gate: runs the project's build command. The build command is resolved in this order: (1) `checks.build_command` in `publish.json` if present, (2) a conventional default per project type (e.g. `npm run build`, `xcodebuild build`). If no build command can be resolved, the gate is skipped with a warning.
- `test` gate: runs the project's test command. Resolved the same way via `checks.test_command` or a conventional default (e.g. `npm test`, `xcodebuild test`). If no test command can be resolved, the gate is skipped with a warning.
- Both are prepended to the gate list before any per-target gates — they always run first
- If either fails, capture full stdout/stderr and surface it. Exit with code `2`. Do not continue to per-target gates.
- Document in `SKILL.md` (or `skills/publish/assets/ci-contract.md`) that mandatory gates cannot be disabled

## Prerequisites
T01 (run_gates.sh scaffold) should be complete.

## Acceptance Criteria
- [ ] `build` gate implemented in `run_gates.sh` — runs build command, exits 2 on failure
- [ ] `test` gate implemented in `run_gates.sh` — runs test command, exits 2 on failure
- [ ] Both gates run before any per-target gates on every `pre` phase invocation
- [ ] On failure: full stdout/stderr surfaced to the user with a clear error header
- [ ] Mandatory gate behaviour documented in SKILL.md or `ci-contract.md`
