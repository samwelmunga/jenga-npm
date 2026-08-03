---
id: E12_S02_T01
story_id: E12_S02
epic_id: E12
title: Document the `[JENGA:SESSION_END]` completion signal protocol
status: Passed
date_created: 2026-05-09
date_started: 2026-05-09
date_completed: 2026-05-09
assigned_to: developer
---

# Task: Document the `[JENGA:SESSION_END]` completion signal protocol

## Description
Create `docs/JENGA_PROTOCOL.md` (or equivalent) that defines the completion signal format: `[JENGA:SESSION_END:<skill_name>]` on its own line. Document the full flow: skill emits signal → hook/watcher detects it → calls `end_session` on router → signal is stripped from output.

## Prerequisites
None

## Acceptance Criteria
- [x] `docs/JENGA_PROTOCOL.md` (or equivalent) exists
- [x] Signal format is clearly defined: `[JENGA:SESSION_END:<skill_name>]`
- [x] Full detection and stripping flow is documented
- [x] Skill author responsibilities are clearly stated
