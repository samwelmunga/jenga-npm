---
id: E26_S05_T02
story_id: E26_S05
epic_id: E26
title: Create validate_npm_env.sh
status: Passed
date_created: 2026-07-31
date_started: 2026-07-31
date_completed: 2026-08-01
dates_previously_completed:
reopened_on:
reopened_reason:
assigned_to: developer
docs: []
---

# Task: Create validate_npm_env.sh

## Description
Create `skills/publish/scripts/validate_npm_env.sh` — the pre-flight environment check for npm publishing. The script must:
1. Check that `NPM_TOKEN` or `NODE_AUTH_TOKEN` is set in the environment
2. If neither is set, print a clear error message explaining which variable is needed and how to set it, then exit non-zero
3. Optionally: check that `node` and `npm` are available in `PATH`
4. Follow the style of the existing `validate_ios_env.sh`

## Prerequisites

## Acceptance Criteria
- [ ] `skills/publish/scripts/validate_npm_env.sh` exists and is executable
- [ ] Script exits non-zero with a clear error if neither `NPM_TOKEN` nor `NODE_AUTH_TOKEN` is set
- [ ] Script exits 0 if at least one of the token variables is set
- [ ] Script checks that `npm` is available in PATH and exits non-zero with a helpful message if not
- [ ] Script passes `shellcheck` with no errors
