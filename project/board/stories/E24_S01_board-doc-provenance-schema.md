---
id: E24_S01
epic_id: E24
title: Board doc provenance schema
status: Passed
date_created: 2026-07-23
date_started:
date_completed: 2026-07-23
tasks:
  - E24_S01_T01
  - E24_S01_T02
  - E24_S01_T03
---

# Story: Board doc provenance schema

Add optional `docs: [...]` annotation support to the scrum board schema so board items can declare which documentation files they affect. `/doc` uses this to resolve `last_update` frontmatter.

## Acceptance Criteria
- [x] Epic, story, and task board file templates support an optional `docs: [...]` field in their YAML front-matter
- [x] Existing board validation/scripts accept and preserve `docs` annotations without errors
- [x] Scrum Master agent guidance documents when to annotate board items with doc targets
- [x] Existing board files without `docs` annotations continue to work unchanged

## Definition of Done
- [x] `docs` field added to board schema templates (epic, story, task)
- [x] Validation scripts updated to allow `docs` field
- [x] Scrum Master agent `.md` updated with annotation guidance
- [x] All acceptance criteria pass
