---
id: E03_S01_T03
story_id: E03_S01
epic_id: E03
title: Implement /dooo orchestration loop logic
status: Done
date_created: 2026-05-08
date_started: 2026-05-08
date_completed: 2026-05-08
assigned_to: developer
---

# Task: Implement /dooo orchestration loop logic

## Description
Implement the full orchestration loop body in `skills/dooo/SKILL.md`. The loop must: (1) call `/do` to start an implementation via a background sub-agent, (2) mark the launched task as `running`, (3) read the board to identify tasks whose dependencies are all met and that don't conflict with running tasks, (4) show the user a numbered list of parallelisable tasks with "Done" as the last option, (5) repeat until the user selects "Done" or no more parallelisable tasks exist.

## Prerequisites
- E03_S01_T02 (skill scaffold must exist)

## Acceptance Criteria
- [ ] `/dooo` calls `/do` to start an implementation via a background sub-agent
- [ ] Launched task is marked `running` in its board file
- [ ] Board is re-read after each launch to identify new parallel candidates
- [ ] User sees a numbered list; last option is always "Done"
- [ ] Loop exits when "Done" selected or no more candidates
