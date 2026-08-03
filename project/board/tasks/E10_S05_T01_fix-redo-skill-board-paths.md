---
id: E10_S05_T01
story_id: E10_S05
epic_id: E10
title: Fix hardcoded board paths in /redo SKILL.md
status: Done
date_created: 2026-05-08
date_started: 2026-05-08
date_completed: 2026-05-08
assigned_to: developer
---

# Task: Fix hardcoded board paths in /redo SKILL.md

## Description
Edit `skills/redo/SKILL.md` to replace every hardcoded board-path reference (`project/epics/`, `project/stories/`) with `$(bash scripts/board_resolver.sh)`. No hardcoded paths should remain in the skill body. Steps 1, 2, and 4+ must be preserved and unchanged in intent.

## Prerequisites
- E10_S02_T01 (board_resolver.sh must exist)

## Acceptance Criteria
- [ ] All `project/epics/` and `project/stories/` path references replaced with resolver call
- [ ] No hardcoded board paths remain
- [ ] Steps 1, 2, 4+ are unchanged in intent
