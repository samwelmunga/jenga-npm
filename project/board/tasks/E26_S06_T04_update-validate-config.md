---
id: E26_S06_T04
story_id: E26_S06
epic_id: E26
title: Update validate_config.sh for npm target structure
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

# Task: Update validate_config.sh for npm target structure

## Description
Update `skills/publish/scripts/validate_config.sh` to validate npm target entries in `publish.json`. When a target has `type: npm`, the script must verify that:
- `npm.package_name` is present and non-empty
- `npm.access` is either `"public"` or `"restricted"`
- The `ios` block is NOT required (do not fail if it is absent)

If any required npm field is missing or invalid, exit with code 4 and a descriptive error message. Existing iOS validation must not be regressed.

## Prerequisites

## Acceptance Criteria
- [x] `validate_config.sh` validates `npm.package_name` and `npm.access` for npm targets
- [x] Missing or invalid npm fields cause exit code 4 with a clear message
- [x] Absence of an `ios` block on an npm target does not trigger a validation error
- [x] iOS validation path is unchanged (no regression)
- [x] Script passes `shellcheck` after modification
