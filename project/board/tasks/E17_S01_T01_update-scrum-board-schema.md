---
id: E17_S01_T01
story_id: E17_S01
epic_id: E17
title: Update SCRUM_BOARD_SCHEMA.md with AC and DoD format standards
status: Passed
date_created: 2026-06-06
date_started:
date_completed: 2026-06-06
assigned_to: developer
---

# Task: Update SCRUM_BOARD_SCHEMA.md with AC and DoD format standards

## Description
Add a dedicated section to `templates/SCRUM_BOARD_SCHEMA.md` documenting the required format for the `## Acceptance Criteria` and `## Definition of Done` sections in story files.

- **AC**: Format-agnostic — may be prose, numbered list, or checkboxes depending on the story. No structural requirement beyond the section existing.
- **DoD**: Must always use `- [ ]` checkboxes. Plain bullet points (`-`) are not valid. The Tester is responsible for ticking these before writing a `Passed` status.

Also update the Story file format template in the schema to reflect checkboxes in the DoD section (currently it shows plain bullets).

## Prerequisites

## Acceptance Criteria
- [ ] A "Story Format Standards" (or equivalent) section exists in `SCRUM_BOARD_SCHEMA.md` documenting the AC and DoD format rules described above
- [ ] The Story file format example in the schema shows `- [ ]` checkboxes in the DoD section, not plain bullets
- [ ] The section clearly states who owns each section (Scrum Master writes, Tester ticks DoD)
