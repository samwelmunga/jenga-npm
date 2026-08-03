---
id: E13_S04_T02
story_id: E13_S04
epic_id: E13
title: Update `package.json` with bin field and verify npm install
status: Passed
date_created: 2026-05-09
date_started: 2026-05-09
date_completed: 2026-05-09
assigned_to: developer
---

# Task: Update `package.json` with bin field and verify npm install

## Description
Update `package.json` to add a `bin` field mapping `"jenga"` to `"bin/jenga.js"`. Verify that `npm install -g .` results in a working `jenga` command in PATH. Ensure `--version` and `--help` work without any config file.

## Prerequisites
- E13_S04_T01

## Acceptance Criteria
- [x] `package.json` has `"bin": { "jenga": "bin/jenga.js" }`
- [x] `npm install -g .` results in `jenga` available in PATH
- [x] `jenga --version` and `jenga --help` work without config file
