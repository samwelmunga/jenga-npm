---
id: E01_S06_T07
story_id: E01_S06
epic_id: E01
title: Implement two-phase CLI orchestration in /train skill
status: Passed
date_created: 2026-04-29
date_started:
date_completed: 2026-05-05
dependencies:
  - E01_S06_T01
  - E01_S06_T02
  - E01_S06_T03
---

# Task: Implement two-phase CLI orchestration in /train skill

Wire the pre-flight → smoke test execution pipeline into the `/train` skill CLI.

## Description

When `/train` runs a job (not scaffold), execute in two phases:

**Phase A — Pre-flight (validate.py)**
1. Invoke `validate.py` as a subprocess in the job directory.
2. If it exits non-zero, surface the error output and halt — do not proceed to Phase B.
3. If it exits zero, print a pass confirmation and continue.

**Phase B — Smoke test (train.py --smoke)**
1. Invoke `train.py --smoke` as a subprocess in the job directory.
2. Surface stdout/stderr to the user.
3. Report success or failure on completion.

The two scripts have no awareness of each other. The `/train` skill CLI owns the gate between phases.

## Acceptance Criteria
- Phase A runs before Phase B — never skipped
- A non-zero exit from `validate.py` halts execution before `train.py` is called
- Both subprocess calls stream output to the terminal
- The CLI clearly labels each phase in its output (e.g. `[pre-flight]`, `[smoke test]`)
- `train.py` and `validate.py` contain no import or call references to each other

## Dependencies
- T01, T02, T03 must be complete so the assets exist to test against
