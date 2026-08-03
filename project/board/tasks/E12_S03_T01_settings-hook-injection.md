---
id: E12_S03_T01
story_id: E12_S03
epic_id: E12
title: Implement `UserPromptSubmit` hook injection into settings.json
status: Passed
date_created: 2026-05-09
date_started: 2026-05-09
date_completed: 2026-05-09
assigned_to: developer
---

# Task: Implement `UserPromptSubmit` hook injection into settings.json

## Description
Implement the logic (callable from `jenga init`) to read `settings.json` (project-level or `~/.claude/settings.json`) and inject the `UserPromptSubmit` hook entry for `hooks/prompt_router.sh` under `hooks.UserPromptSubmit`. If `settings.json` does not exist, create it with minimum required structure. After injection, print "✓ Hook registered in settings.json".

## Prerequisites
None

## Acceptance Criteria
- [x] `settings.json` is updated with the hook entry
- [x] If `settings.json` is absent, it is created
- [x] Existing hook entries are preserved
- [x] Prints "✓ Hook registered in settings.json" on success
