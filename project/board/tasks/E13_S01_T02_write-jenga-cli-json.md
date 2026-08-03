---
id: E13_S01_T02
story_id: E13_S01
epic_id: E13
title: Write collected wizard values to `jenga.cli.json`
status: Passed
date_created: 2026-05-09
date_started: 2026-05-09
date_completed: 2026-05-09
assigned_to: developer
---

# Task: Write collected wizard values to `jenga.cli.json`

## Description
After the wizard completes, write the collected values to `jenga.cli.json` in the project root. The file must conform to the schema defined in E14_S01. Convert session timeout from minutes (wizard input) to milliseconds (config value).

## Prerequisites
- E13_S01_T01

## Acceptance Criteria
- [x] `jenga.cli.json` is created/updated after wizard completion
- [x] Session timeout is stored in ms (minutes × 60000)
- [x] File is valid JSON conforming to the E14_S01 schema
- [x] Exits with "Run `jenga start` to start the router" message
