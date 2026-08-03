---
id: E24_S02
epic_id: E24
title: /doc skill contract and target resolution
status: Passed
date_created: 2026-07-23
date_started:
date_completed: 2026-07-24
tasks:
  - E24_S02_T01
  - E24_S02_T02
  - E24_S02_T03
  - E24_S02_T04
---

# Story: /doc skill contract and target resolution

Scaffold the `/doc` skill with argument parsing, the path→objective rule table, and an ambiguity gate that requires user clarification for unknown targets.

## Acceptance Criteria
- [x] `skills/doc/SKILL.md` exists and is invocable as `/doc`
- [x] `/doc` with no arguments defaults to `README.md` as the target
- [x] `/doc <path>` accepts an optional target path argument
- [x] A deterministic path→objective rule table maps known targets (e.g. `README.md` → project overview, `docs/API.md` → API doc, `docs/CLI.md` → CLI usage) to generation objectives
- [x] For unknown/unmapped targets, an ambiguity gate halts and asks the user to clarify the objective before proceeding

## Definition of Done
- [x] `skills/doc/SKILL.md` scaffolded with all acceptance criteria satisfied
- [x] Path→objective rule table documented and tested with known paths
- [x] Ambiguity gate demonstrated with an unknown target path
