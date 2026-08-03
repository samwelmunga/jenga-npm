---
id: E22_S02_T03
story_id: E22_S02
epic_id: E22
title: Auto-trigger wizard on missing config during deploy
status: Passed
date_created: 2026-07-11
date_started: 2026-07-11
date_completed: 2026-07-11
assigned_to: developer
---

# Task: Auto-trigger wizard on missing config during deploy

## Description
Add auto-trigger logic so that when `/publish deploy` (or any sub-command requiring a target) detects that `publish.json` is missing or the selected target has incomplete config, it automatically runs the setup wizard before proceeding.

**Config completeness check** (`skills/publish/scripts/check_target_config.sh`):
- Accepts `<target_name> <publish_json_path>` as arguments
- Checks:
  1. `publish.json` exists (else: exit 4)
  2. Target `<target_name>` exists in `targets[]` (else: exit 4)
  3. All required fields for the target type are non-empty (type-specific required fields listed per adapter type)
  4. For `mobile-ios`: required fields are `bundle_id`, `team_id`, `scheme`, `export_method` + all secrets references
- Exits 0 if complete, exits 4 with a descriptive message if incomplete

**Auto-trigger integration** (documented in `SKILL.md` deploy section):
- Before the gate runner is invoked, the deploy flow calls `check_target_config.sh`
- If it exits 4:
  - Print: `⚠️  Target '<name>' has missing or incomplete config. Running setup wizard...`
  - Invoke `setup_wizard.sh <target_name> --type <type>`
  - After the wizard completes (saved), re-run `check_target_config.sh` to verify completeness
  - If still incomplete after wizard, exit 4 with message and halt
- Non-interactive mode (`--yes`): if config is missing/incomplete, do NOT auto-run the wizard — exit 4 immediately with a message listing what is missing

**SKILL.md update**:
- The `deploy` sub-command section should document the auto-trigger behavior and note that `--yes` disables it

## Prerequisites
T02 (setup wizard script) must be complete.

## Acceptance Criteria
- [ ] `skills/publish/scripts/check_target_config.sh` exists and is executable
- [ ] Script exits 4 on missing `publish.json`, missing target, or incomplete required fields
- [ ] Script exits 0 on a fully configured target
- [ ] Auto-trigger documented in SKILL.md deploy section
- [ ] Non-interactive mode skips wizard and exits 4 with descriptive message
- [ ] After wizard auto-run, config completeness is re-checked before proceeding
