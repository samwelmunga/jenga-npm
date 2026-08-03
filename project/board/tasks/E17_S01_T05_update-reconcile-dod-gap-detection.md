---
id: E17_S01_T05
story_id: E17_S01
epic_id: E17
title: Update skills/reconcile/SKILL.md — add DoD gap detection
status: Passed
date_created: 2026-06-06
date_started:
date_completed: 2026-06-06
assigned_to: developer
---

# Task: Update skills/reconcile/SKILL.md — add DoD gap detection

## Description
Update `skills/reconcile/SKILL.md` to add a DoD gap detection sub-step within Phase 4 (Roll up story and epic statuses).

After rolling up story statuses, for each story whose status is a completed status (`Passed`, `Passed with remarks`, `Done`):
1. Read the story file and look for a `## Definition of Done` section.
2. Scan for any unchecked `- [ ]` checkbox lines.
3. If unchecked boxes are found: record the story ID, story title, and the unchecked items.

At the end of Phase 4, if any DoD gaps were found, include a **"DoD Gaps"** section in the reconcile report (see `assets/report_format.md`) listing each affected story and its unchecked items. Do not automatically demote or change the status of affected stories — report only.

Also update `assets/report_format.md` to include the "DoD Gaps" section in the report template.

## Prerequisites

## Acceptance Criteria
- [ ] `skills/reconcile/SKILL.md` Phase 4 includes the DoD gap detection sub-step as described
- [ ] The instruction is clear that gap detection is report-only — no automatic status changes
- [ ] `assets/report_format.md` includes a "DoD Gaps" section in the reconcile report template
- [ ] The sub-step correctly handles stories where the DoD section is absent (skip gracefully, do not error)
- [ ] The sub-step correctly handles stories where all DoD boxes are already ticked (no gap reported)
