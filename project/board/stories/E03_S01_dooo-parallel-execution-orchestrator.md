---
id: E03_S01
epic: E03
title: /dooo Skill — Parallel Execution Orchestrator
status: Done
date_created: 2026-04-29
date_started: 2026-04-29
date_completed: 2026-05-10
---

# Story: /dooo Skill — Parallel Execution Orchestrator

## Goal
Create a `/dooo` skill that wraps `/do` and orchestrates parallel sub-agent implementations. After each implementation is kicked off, the skill returns to the scrum board, identifies tasks that can run in parallel with the currently running ones, and lets the user pick the next one to start (or exit).

## Acceptance Criteria
- [ ] `/dooo` calls `/do` to start an implementation via a sub-agent (background mode)
- [ ] After launch, the skill reads the board and identifies tasks whose dependencies are all met and that don't conflict with running tasks
- [ ] A new status value `running` is introduced for tasks/stories to mark in-flight implementations
- [ ] The user is shown a numbered list of parallelisable tasks; the last option is always **"Done"**
- [ ] Selecting "Done" exits the loop without starting a new implementation
- [ ] The loop repeats until the user selects "Done" or no more parallelisable tasks exist
- [ ] The skill is placed at `skills/dooo/` following standard skill conventions

## Tasks
- [ ] Define `running` status in the project's status conventions (AGENT.md or workflow.json)
- [ ] Scaffold `skills/dooo/` directory with `skill.md`
- [ ] Implement orchestration loop logic in the skill body
- [ ] Test with at least two parallel-safe stories from the board
- [ ] Update `skills/help/` listing to include `/dooo`
