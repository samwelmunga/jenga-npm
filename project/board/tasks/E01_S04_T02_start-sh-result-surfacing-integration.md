---
id: E01_S04_T02
story_id: E01_S04
epic_id: E01
title: Wire start.sh result surfacing integration
status: Done
date_created: 2026-04-29
date_started: 2026-05-05
date_completed: 2026-05-05
assigned_to: developer
---

# Task: Wire start.sh result surfacing integration

## Description
Ensure that the result surfacing entry point (from E01_S05) is callable as a standalone CLI command or script from `start.sh`. This may mean exposing a `surface_results.py` (or similar) in the job directory, or referencing a shared utility. The key requirement: `start.sh` must be able to trigger result surfacing outside of an agent session, with no dependency on Claude being active.

When `auto_summarize: false`, `start.sh` must skip this step entirely and exit cleanly.

## Prerequisites
- E01_S04_T01 must be complete
- E01_S05_T02 (result outputs) must be complete or near-complete

## Acceptance Criteria
- [ ] `start.sh` can invoke result surfacing without an active agent session
- [ ] `auto_summarize: false` causes result surfacing step to be skipped with no error
- [ ] The integration path (script name, arguments) is documented in the job README or next-steps output
