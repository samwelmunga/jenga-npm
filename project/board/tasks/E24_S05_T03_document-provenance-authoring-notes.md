---
id: E24_S05_T03
story_id: E24_S05
epic_id: E24
title: Document provenance assumptions and failure modes in authoring notes
status: Passed
date_created: 2026-07-23
date_started:
date_completed: 2026-07-24
assigned_to: developer
---

# Task: Document provenance assumptions and failure modes in authoring notes

## Description
Write authoring notes for the `/doc` skill in `skills/doc/` covering the provenance resolution mechanism. The notes should explain the assumptions made, how `last_update` is derived, and what happens when provenance is unavailable.

Content to cover:
1. What `last_update` represents and where it comes from
2. The requirement for board items to carry `docs: [...]` annotations pointing to the target file
3. The fallback behavior and when it triggers
4. Known failure modes: board items completed without `docs` annotations, target path mismatches (relative vs absolute), items in non-Done status

Deliver as a section in `skills/doc/SKILL.md` or a separate `skills/doc/authoring-notes.md`.

## Prerequisites
- E24_S05_T01 and E24_S05_T02 (provenance logic must be implemented before it can be documented)

## Acceptance Criteria
- [ ] Authoring notes explain how `last_update` is resolved
- [ ] Failure modes are listed with clear descriptions
- [ ] Fallback behavior is documented
- [ ] Notes are located in `skills/doc/` (either inline in SKILL.md or as `authoring-notes.md`)
