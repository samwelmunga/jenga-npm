---
id: E10_S06_T02
story_id: E10_S06
epic_id: E10
title: Update /do SKILL.md board paths to use board_resolver.sh
status: Done
date_created: 2026-05-08
date_started: 2026-05-08
date_completed: 2026-05-08
assigned_to: developer
---

# Task: Update /do SKILL.md board paths to use board_resolver.sh

## Description
Edit `skills/do/SKILL.md` to replace all hardcoded `project/board/` path references with `$(bash scripts/board_resolver.sh)`. No hardcoded board paths should remain in the skill body. Skill behaviour from a user perspective must be unchanged.

## Prerequisites
- E10_S02_T01 (board_resolver.sh must exist)

## Acceptance Criteria
- [ ] All `project/board/` path references replaced with resolver call
- [ ] No hardcoded board paths remain
- [ ] Skill behaviour unchanged
