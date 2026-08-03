---
id: E04_S02
epic_id: E04
title: Wire /convert into /train Interactive Wizard
status: Passed
date_created: 2026-04-30
date_started: 2026-04-30
date_completed: 2026-04-30
depends_on:
  - E04_S01
  - E01_S08
tasks:
  - After data file path is captured in wizard, check if file extension is non-CSV
  - If non-CSV, automatically invoke /convert on the file before proceeding
  - Surface conversion output path to the user and update job config accordingly
  - Handle conversion failure gracefully (abort wizard with clear error message)
---

# Story: Wire /convert into /train Interactive Wizard

As a user running the interactive train wizard, I want non-CSV data files to be automatically converted to CSV — so that I don't have to manually run `/convert` before setting up my job.

## Dependencies
- **E04_S01** — Core `/convert` skill must exist before this wiring can be implemented
- **E01_S08** — Interactive train wizard must exist to wire into

## Acceptance Criteria
- [ ] After the user enters a data file path in the wizard, the tool checks the file extension
- [ ] If the file is non-CSV, `/convert` is automatically invoked and the user is informed
- [ ] The converted CSV path is used in place of the original path in the job config
- [ ] If `/convert` fails, the wizard aborts with a clear, actionable error message
- [ ] If the file is already `.csv`, no conversion is attempted (pass-through)

## Definition of Done
- [ ] `/train` interactive wizard checks file extension post-path-capture
- [ ] Auto-invokes `/convert` for non-CSV files
- [ ] Job `config.yaml` is written with the converted CSV path
- [ ] Failure path tested and gracefully handled
