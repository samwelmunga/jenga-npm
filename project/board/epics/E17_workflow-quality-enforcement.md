---
id: E17
title: Workflow Quality & Enforcement
status: Pending
date_created: 2026-06-06
date_started:
date_completed:
stories:
  - E17_S01
  - E17_S02
  - E17_S03
  - E17_S04
  - E17_S05
---

# Epic: Workflow Quality & Enforcement

## Purpose
Structural improvements to the agent workflow — format standards, enforcement gates, and quality guardrails that ensure agent-generated board items are consistently structured and that completion statuses are always backed by verifiable evidence, not just mechanical rollup counts.

## Definition of Done
- [ ] Every new story written by the Scrum Master has a correctly-formatted DoD (checkboxes) validated at write time
- [ ] The Tester explicitly verifies AC coverage and ticks DoD checkboxes before writing any `Passed` status
- [ ] `scripts/validate-story-format.sh` exists and is used by the Tester as a pre-flight check
- [ ] `SCRUM_BOARD_SCHEMA.md` documents the required AC and DoD format standards
- [ ] `/reconcile` flags any Passed/Done story with unchecked DoD boxes in its report
