---
id: E24_S03
epic_id: E24
title: Evidence collection and precedence
status: Passed
date_created: 2026-07-23
date_started:
date_completed: 2026-07-23
tasks:
  - E24_S03_T01
  - E24_S03_T02
  - E24_S03_T03
---

# Story: Evidence collection and precedence

Collect evidence from all configured sources (user prompt, scrum board, codebase, git history) and enforce a strict precedence chain when sources conflict.

## Acceptance Criteria
- [ ] Evidence is collected from: user prompt, scrum board (`PROJECT_SUMMARY.md`, epics, stories, tasks), codebase (manifests, source files), and git history
- [ ] A strict source precedence is enforced: user prompt → scrum board → codebase inspection → git history
- [ ] When sources conflict, higher-precedence sources win and the conflict is noted
- [ ] Evidence is normalized into a reusable synthesis context object for downstream generation steps

## Definition of Done
- [ ] Evidence collection logic implemented in `/doc` skill
- [ ] Precedence chain documented and enforced
- [ ] Synthesis context object schema defined
- [ ] All acceptance criteria pass
