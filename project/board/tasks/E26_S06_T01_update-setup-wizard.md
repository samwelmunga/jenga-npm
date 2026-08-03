---
id: E26_S06_T01
story_id: E26_S06
epic_id: E26
title: Add npm branch to setup_wizard.sh
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

# Task: Add npm branch to setup_wizard.sh

## Description
Update `skills/publish/scripts/setup_wizard.sh` to handle `--type npm` by invoking the npm wizard (`wizards/npm.md`). Add a conditional branch: if `--type npm`, run the npm wizard; if `--type mobile-ios`, run the iOS wizard (unchanged). If `--type` is not provided, prompt the user to choose a type.

## Prerequisites

## Acceptance Criteria
- [ ] `setup_wizard.sh` accepts `--type npm` and invokes `wizards/npm.md`
- [ ] `setup_wizard.sh` still handles `--type mobile-ios` exactly as before (no regression)
- [ ] If `--type` is not supplied, the script prompts the user to select a type from a list
- [ ] Script passes `shellcheck` after modification
