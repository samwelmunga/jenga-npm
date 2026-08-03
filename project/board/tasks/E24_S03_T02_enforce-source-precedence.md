---
id: E24_S03_T02
story_id: E24_S03
epic_id: E24
title: Enforce source precedence chain
status: Passed
date_created: 2026-07-23
date_started:
date_completed: 2026-07-23
assigned_to: developer
---

# Task: Enforce source precedence chain

## Description
Implement conflict resolution within the evidence collection step. When two sources provide contradictory information about the same fact (e.g. version number, project name, feature list), the higher-precedence source wins.

Precedence order (highest to lowest):
1. User prompt (explicit instruction from the invoker)
2. Scrum board (authoritative project intent)
3. Codebase inspection (manifests, source files)
4. Git history (historical context)

When a conflict is resolved, the skill should note which source won and what was discarded. This note is included in the synthesis context object (not shown to the user unless they ask).

## Prerequisites
- E24_S03_T01

## Acceptance Criteria
- [ ] When two sources conflict, the higher-precedence source wins
- [ ] The conflict resolution outcome is recorded in the synthesis context object
- [ ] Precedence order matches: user prompt > scrum board > codebase > git history
