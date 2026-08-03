---
id: E17_S01_T04
story_id: E17_S01
epic_id: E17
title: Update agents/tester.md — add AC reading and DoD checkbox step
status: Passed
date_created: 2026-06-06
date_started:
date_completed: 2026-06-06
assigned_to: developer
---

# Task: Update agents/tester.md — add AC reading and DoD checkbox step

## Description
Update `agents/tester.md` to add an explicit AC/DoD verification step to the test execution flow ("Invoked for test implementation and/or execution"), inserted between the current Step 5 (execute tests) and Step 6 (evaluate results and set status).

The new step must instruct the Tester to:

1. Run `scripts/validate-story-format.sh` on the story file — if it fails, halt, write a problem rapport explaining the format issue, and set status to `Blocked` (do not proceed to mark Passed).
2. Read the story's `## Acceptance Criteria` section. For each item, confirm it is covered by the test run. If any item has no corresponding test evidence, note it explicitly in the test output.
3. Read the story's `## Definition of Done` section. For each `- [ ]` checkbox: tick it to `- [x]` in the story file, confirming that criterion has been met by the test run.
4. Only after all DoD boxes are ticked may the Tester write a `Passed` or `Passed with remarks` status.

If any DoD item cannot be verified, the Tester must leave that box unchecked, write a `Failed` status, and include the unverified items in a problem rapport.

## Prerequisites

## Acceptance Criteria
- [ ] `agents/tester.md` contains the new AC/DoD verification step inserted at the correct position in the test execution flow
- [ ] The step instructs the Tester to run `validate-story-format.sh` before proceeding and halt on failure
- [ ] The step instructs the Tester to read AC and document coverage for each item
- [ ] The step instructs the Tester to tick `- [ ]` → `- [x]` in the story file for each verified DoD item
- [ ] The instruction is unambiguous about what happens when a DoD item cannot be verified (`Failed` status + unchecked box + problem rapport)
- [ ] The instruction references `scripts/validate-story-format.sh` by path
