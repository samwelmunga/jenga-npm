---
id: E03
title: Parallel Workflow Orchestration
status: Passed with remarks
date_created: 2026-04-29
date_started: 2026-04-29
date_completed: 2026-10-15
stories:
  - E03_S01
  - E03_S02
  - E03_S03
---

# Epic: Parallel Workflow Orchestration

## Purpose
Extend the Jenga skill system with orchestration capabilities that allow multiple implementation tasks to be executed in parallel by sub-agents. The orchestrator skill (`/dooo`) wraps `/do` with a feedback loop that returns to the scrum board after each implementation is kicked off, identifies tasks that can safely run in parallel with the already-running ones, and presents them to the user so they can choose to fan out further or call it done.

## Definition of Done
- [x] `/dooo` skill exists and delegates each implementation to a sub-agent via `/do`
- [x] After each implementation starts, the skill returns to the board and identifies parallelisable tasks
- [x] A new task/story status (e.g. `running`) exists so the orchestrator can track in-flight implementations (superseded: tracked as `In Progress`, commits d4c8bd5c, d31e4540)
- [x] User is presented with a list of parallelisable tasks plus a "Done" option at the end
- [x] Selecting "Done" exits the loop cleanly
- [x] Behaviour is documented in the skill's README / inline comments (satisfied by `skills/j-dooo/SKILL.md`, the skill's sole documentation; no separate README exists)

## Rollup Remarks (2026-10-15)
- E03_S01 closed `Passed with remarks`; E03_S02 and E03_S03 are `Merged`.
- The `running` status named in the DoD was superseded by `In Progress` (commits d4c8bd5c, d31e4540); E03_S01_T04 (help-skill listing) was `Rejected` as superseded because `/j-help` renders from the live skill list.
- The never-written "test with two parallel-safe stories" item is accepted as proven by later real `/dooo` usage (owner decision).
