---
id: E03
title: Parallel Workflow Orchestration
status: Done
date_created: 2026-04-29
date_started: 2026-04-29
date_completed: 2026-05-10
stories:
  - E03_S01
  - E03_S02
  - E03_S03
---

# Epic: Parallel Workflow Orchestration

## Purpose
Extend the Jenga skill system with orchestration capabilities that allow multiple implementation tasks to be executed in parallel by sub-agents. The orchestrator skill (`/dooo`) wraps `/do` with a feedback loop that returns to the scrum board after each implementation is kicked off, identifies tasks that can safely run in parallel with the already-running ones, and presents them to the user so they can choose to fan out further or call it done.

## Definition of Done
- [ ] `/dooo` skill exists and delegates each implementation to a sub-agent via `/do`
- [ ] After each implementation starts, the skill returns to the board and identifies parallelisable tasks
- [ ] A new task/story status (e.g. `running`) exists so the orchestrator can track in-flight implementations
- [ ] User is presented with a list of parallelisable tasks plus a "Done" option at the end
- [ ] Selecting "Done" exits the loop cleanly
- [ ] Behaviour is documented in the skill's README / inline comments
