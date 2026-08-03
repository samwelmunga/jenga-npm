---
id: E26_S02_T02
story_id: E26_S02
epic_id: E26
title: Add publishConfig for public npm access
status: Passed
date_created: 2026-07-31
date_started: 2026-07-31
date_completed: 2026-07-31
dates_previously_completed:
reopened_on:
reopened_reason:
assigned_to: developer
docs: []
---

# Task: Add publishConfig for public npm access

## Description
Add `"publishConfig": { "access": "public" }` to `package.json` so that `npm publish` defaults to public access on the npmjs.com registry without requiring the `--access public` flag at publish time. Also confirm the package name — if `"jenga"` is already taken or unsuitable, rename to `"jenga-agent"` and update all references in `README.md` and documentation.

## Prerequisites
- Check npmjs.com to confirm whether `"jenga"` or `"jenga-agent"` is available before deciding on the final name.

## Acceptance Criteria
- [x] `package.json` has `"publishConfig": { "access": "public" }`
- [x] The package `name` field is confirmed and documented (either `"jenga"` or `"jenga-agent"`)
- [x] If the name was changed, all references in `README.md` and docs are updated
