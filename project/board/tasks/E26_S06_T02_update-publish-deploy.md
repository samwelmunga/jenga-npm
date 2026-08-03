---
id: E26_S06_T02
story_id: E26_S06
epic_id: E26
title: Add npm dispatch to publish_deploy.sh
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

# Task: Add npm dispatch to publish_deploy.sh

## Description
Update `skills/publish/scripts/publish_deploy.sh` to dispatch to `npm_pipeline.sh` when the active target's `type` is `npm`. The existing dispatch to `ios_pipeline.sh` for `mobile-ios` targets must remain unchanged. Pass the `--dry-run` flag through to `npm_pipeline.sh` if it was supplied to `publish_deploy.sh`.

## Prerequisites

## Acceptance Criteria
- [x] `publish_deploy.sh` dispatches to `npm_pipeline.sh` when `target.type == "npm"`
- [x] `publish_deploy.sh` continues to dispatch to `ios_pipeline.sh` for `mobile-ios` (no regression)
- [x] `--dry-run` flag is forwarded to `npm_pipeline.sh` when present
- [x] Script passes `shellcheck` after modification
