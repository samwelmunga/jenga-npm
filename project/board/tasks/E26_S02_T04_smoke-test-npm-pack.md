---
id: E26_S02_T04
story_id: E26_S02
epic_id: E26
title: Smoke test npm pack and local install
status: Passed
date_created: 2026-07-31
date_started: 2026-07-31
date_completed: 2026-07-31
dates_previously_completed:
reopened_on:
reopened_reason:
assigned_to: tester
docs: []
---

# Task: Smoke test npm pack and local install

## Description
End-to-end validation of the package.json configuration. Pack the package locally, install it in a fresh temp directory, and confirm the postinstall hook fires and places files correctly.

Steps:
1. Run `npm pack` from the repo root to produce a `.tgz` tarball
2. Create a fresh temp directory
3. Run `npm install <path-to-tarball>` in the temp directory
4. Verify that `skills/`, `agents/`, `hooks/`, `scripts/`, `templates/` are present in the temp directory root
5. Confirm no board/queue/log files leaked into the tarball

## Prerequisites

## Acceptance Criteria
- [x] `npm pack` succeeds without errors
- [x] Tarball contents match the `files` array in `package.json` (no unexpected files)
- [x] After `npm install <tarball>` in a fresh directory, all five framework directories appear at the project root
- [x] No `project/`, `jobs/`, `.jenga_paths`, or internal files are present in the install output
