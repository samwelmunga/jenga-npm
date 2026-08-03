---
id: E13_S01_T03
story_id: E13_S01
epic_id: E13
title: Call settings injection from `jenga init`
status: Passed
date_created: 2026-05-09
date_started: 2026-05-09
date_completed: 2026-05-09
assigned_to: developer
---

# Task: Call settings injection from `jenga init`

## Description
After writing `jenga.cli.json`, `jenga init` must call the settings injection logic (E12_S03) to register the hook in `settings.json`. Print success/failure messages for both steps.

## Prerequisites
- E13_S01_T02

## Acceptance Criteria
- [x] `jenga init` calls settings injection as part of its flow
- [x] Both `jenga.cli.json` write and hook injection are reported to the user
- [x] Failure in settings injection is reported but does not crash init
