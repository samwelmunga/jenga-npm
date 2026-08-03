---
id: E12_S02_T03
story_id: E12_S02
epic_id: E12
title: Update SKILL.md template and brainstorm skill with signal stub
status: Passed
date_created: 2026-05-09
date_started: 2026-05-09
date_completed: 2026-05-09
assigned_to: developer
---

# Task: Update SKILL.md template and brainstorm skill with signal stub

## Description
Update the skill creation template to include a reminder/stub for emitting `[JENGA:SESSION_END:<skill_name>]` at session end. Update the `brainstorm` skill (if it exists) to emit the signal when its session concludes.

## Prerequisites
- E12_S02_T01

## Acceptance Criteria
- [x] Skill template includes the signal stub with a comment explaining it
- [x] `brainstorm` skill emits `[JENGA:SESSION_END:brainstorm]` at conclusion
- [x] After signal, next unrelated prompt is matched normally
