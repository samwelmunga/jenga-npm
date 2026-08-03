---
id: E23
title: Human↔Agent Handoff Protocol
status: Pending
date_created: 2026-07-11
date_started:
date_completed:
stories:
  - E23_S01
  - E23_S02
  - E23_S03
  - E23_S04
  - E23_S05
---

# Epic: Human↔Agent Handoff Protocol

## Purpose
Establish a formal protocol for toggling between agentic and manual development.
When tokens run out mid-task, the agent writes a rolling checkpoint handoff that
the user can follow manually. When the agent resumes, it reads the handoff + the
original task spec to continue from exactly the right point — routing completed
manual work through the Tester as normal.

## Core components
- **Handoff documents** — `project/handoffs/<task-id>.md`, written as rolling checkpoints
- **`/handoff` skill** — explicit user-triggered handoff write
- **`/pickup` skill** — agent resumption after manual work
- **`/continue` enhancement** — detects open handoffs at session start
- **Lifecycle management** — archive, cleanup, `/reconcile` integration

## Definition of Done
- [ ] Developer agent writes/updates `project/handoffs/<task-id>.md` at every major milestone
- [ ] Handoff contains: completed steps, remaining steps (human checklist), files modified, machine-readable JSON block
- [ ] `/handoff` skill forces an immediate handoff write and surfaces remaining steps to user
- [ ] `/pickup` skill lists open handoffs, reconciles git + task spec, resumes remaining steps, routes to Tester
- [ ] `/continue` checks `project/handoffs/` at session start and surfaces interrupted tasks
- [ ] Completed handoffs archived to `project/handoffs/archive/` after Tester passes
- [ ] `/reconcile` cleans stale handoff files for tasks already marked Done
