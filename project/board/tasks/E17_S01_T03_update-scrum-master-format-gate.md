---
id: E17_S01_T03
story_id: E17_S01
epic_id: E17
title: Update agents/scrum-master.md — add DoD format gate
status: Passed
date_created: 2026-06-06
date_started:
date_completed: 2026-06-06
assigned_to: developer
---

# Task: Update agents/scrum-master.md — add DoD format gate

## Description
Update `agents/scrum-master.md` to instruct the Scrum Master to validate DoD format before writing any new story file to the board.

Add a "Story Format Validation" step to the "Finalizing Items" section (or equivalent) with the following behaviour:

1. Before writing a story file, run `scripts/validate-story-format.sh` against the intended content (write to a temp file if needed, or validate inline before persisting).
2. If validation fails (DoD missing or not checkboxes): fix the format — do not write a malformed story file. Log what was corrected.
3. If validation passes: proceed with writing the file normally.

This gate applies to all story creation and amendment operations.

## Prerequisites

## Acceptance Criteria
- [ ] `agents/scrum-master.md` includes a format validation step in its story-writing flow
- [ ] The instruction is unambiguous: a Scrum Master agent reading it knows exactly when to run the script, what to do if it fails, and that it must not write a story file that fails validation
- [ ] The instruction references `scripts/validate-story-format.sh` by path
