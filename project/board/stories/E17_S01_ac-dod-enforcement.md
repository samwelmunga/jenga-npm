---
id: E17_S01
epic_id: E17
title: AC/DoD Enforcement in Agent Workflow
status: Passed
date_created: 2026-06-06
date_started:
date_completed: 2026-06-06
tasks:
  - E17_S01_T01
  - E17_S01_T02
  - E17_S01_T03
  - E17_S01_T04
  - E17_S01_T05
---

# Story: AC/DoD Enforcement in Agent Workflow

As a developer using the scrum board, I want Acceptance Criteria and Definition of Done to be systematically verified and updated before any story is marked Passed — so that a story's completion status is always backed by evidence, not just task rollup counts.

## Acceptance Criteria
- [ ] `templates/SCRUM_BOARD_SCHEMA.md` documents the required format: AC section (format-agnostic), DoD section (must use `- [ ]` checkboxes)
- [ ] `scripts/validate-story-format.sh` exists, is executable, and exits non-zero with a clear message if a story file is missing an AC section, a DoD section, or DoD has no checkboxes
- [ ] `agents/scrum-master.md` instructs the Scrum Master to run the validation script before writing any new story file, and to fix the format if validation fails
- [ ] `agents/tester.md` includes an explicit step in the test execution flow: run `validate-story-format.sh` on the story file, read the AC section to confirm test coverage, tick each DoD checkbox (`- [ ]` → `- [x]`), and only then write the `Passed` status
- [ ] `skills/reconcile/SKILL.md` Phase 4 includes a DoD-gap detection sub-step: for every story with a completed status, check for unchecked DoD boxes and list them in the reconcile report

## Definition of Done
- [x] All five tasks completed and passing
- [x] `validate-story-format.sh` tested against a valid story, a story missing AC, a story missing DoD, and a story with DoD as plain bullets (no checkboxes)
- [x] Tester instruction update reviewed and unambiguous — a developer reading it could implement the step without asking clarifying questions
- [x] Reconcile report format updated to include a "DoD Gaps" section when unchecked boxes are found
