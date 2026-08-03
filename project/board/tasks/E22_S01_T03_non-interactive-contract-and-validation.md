---
id: E22_S01_T03
story_id: E22_S01
epic_id: E22
title: Write non-interactive contract spec and implement config-validation stub
status: Passed
date_created: 2026-07-11
date_started:
date_completed: 2026-07-11
assigned_to: developer
---

# Task: Write non-interactive contract spec and implement config-validation stub

## Description
Define the full non-interactive (CI-friendly) execution contract for the `/publish deploy` sub-command, and implement the config-validation stub that will be called on every skill invocation.

**Non-interactive contract** (written as a doc section in `SKILL.md` and/or a dedicated `skills/publish/assets/ci-contract.md`):
- `--target <name>` flag to select the deployment target
- `--yes` flag to skip confirmation prompts
- `PUBLISH_TARGET` and `PUBLISH_YES` env vars as alternatives to flags
- Exit codes: `0` = success, `1` = user abort, `2` = gate failure, `3` = deploy failure, `4` = config missing/invalid
- Which flags/env vars are required vs optional in non-interactive mode
- Example CI invocation: `publish deploy --target staging --yes`

**Config-validation stub** (`skills/publish/scripts/validate_config.sh`):
- Accepts a path to `publish.json` as $1
- Returns exit code 0 if the file exists and is valid JSON matching the schema
- Returns exit code 4 if the file is missing or fails schema validation
- Outputs a human-readable error message to stderr on failure
- The SKILL.md must reference this script and state it runs on every invocation

## Prerequisites
T01 and T02 should be complete first (SKILL.md and schema must exist), but this task may be written in parallel if the schema output path is agreed.

## Acceptance Criteria
- [ ] Non-interactive contract is documented in `SKILL.md` (or linked `ci-contract.md`) with all flags, env vars, and exit codes
- [ ] `skills/publish/scripts/validate_config.sh` exists and is executable
- [ ] Script exits 4 on missing file and on invalid JSON / schema mismatch
- [ ] Script exits 0 on a valid `publish.json`
- [ ] `SKILL.md` states that `validate_config.sh` is called on every invocation before any sub-command executes
