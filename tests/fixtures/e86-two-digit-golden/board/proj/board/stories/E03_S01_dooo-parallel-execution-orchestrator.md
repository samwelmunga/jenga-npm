---
id: E03_S01
epic_id: E03
title: /dooo Skill — Parallel Execution Orchestrator
status: Passed with remarks
date_created: 2026-04-29
date_started: 2026-04-29
date_completed: 2026-10-15
---

# Story: /dooo Skill — Parallel Execution Orchestrator

## Goal
Create a `/dooo` skill that wraps `/do` and orchestrates parallel sub-agent implementations. After each implementation is kicked off, the skill returns to the scrum board, identifies tasks that can run in parallel with the currently running ones, and lets the user pick the next one to start (or exit).

## Acceptance Criteria
- [x] `/dooo` calls `/do` to start an implementation via a sub-agent (background mode)
- [x] After launch, the skill reads the board and identifies tasks whose dependencies are all met and that don't conflict with running tasks
- [x] A new status value `running` is introduced for tasks/stories to mark in-flight implementations (superseded: now In Progress) (commits d4c8bd5c, d31e4540)
- [x] The user is shown a numbered list of parallelisable tasks; the last option is always **"Done"**
- [x] Selecting "Done" exits the loop without starting a new implementation
- [x] The loop repeats until the user selects "Done" or no more parallelisable tasks exist
- [x] The skill is placed at `skills/dooo/` (now canonical `skills/j-dooo/`) following standard skill conventions

## Tasks
- [x] Define `running` status in the project's status conventions (AGENT.md or workflow.json) (superseded: now In Progress)
- [x] Scaffold `skills/dooo/` directory with `skill.md`
- [x] Implement orchestration loop logic in the skill body
- [x] Test with at least two parallel-safe stories from the board — accepted via later /dooo usage (no separate test task)
- [x] Update `skills/help/` listing to include `/dooo` — superseded: T04 closed Rejected (j-help renders from the live skill list)

## Closure Notes (2026-10-15, tester)
- Status `Passed with remarks`: T02 Passed; T01 and T03 Passed with remarks (the `running` wording is superseded by `In Progress`, commits d4c8bd5c E42_S01_T03 and d31e4540 E51_S01_T02); T04 Rejected (closed as superseded, `skills/j-help/SKILL.md` renders from the live skill list).
- The "Test with at least two parallel-safe stories" item has no task file and will not get one: the project owner accepted /dooo's later real usage (`project/queue/concurrency-slots-dooo-*.json` files, many later commits touching `skills/j-dooo`) as proof.
- This story has no `## Definition of Done` section (legacy story, `validate-story-format.sh` exits 3); closed on the owner's explicit instruction, no DoD boxes to tick.
