---
id: E24_S05
epic_id: E24
title: Frontmatter provenance resolution
status: Passed
date_created: 2026-07-23
date_started: 2026-07-23
date_completed: 2026-07-24
tasks:
  - E24_S05_T01
  - E24_S05_T02
  - E24_S05_T03
---

# Story: Frontmatter provenance resolution

Resolve `last_update` from completed board items with matching `docs` annotations. Define fallback behavior when provenance is missing.

## Acceptance Criteria
- [x] `last_update` frontmatter is resolved from Done board items whose `docs` annotations include the target file path
- [x] When no matching provenance is found, `last_update` is either omitted or marked `unknown` (fallback clearly defined)
- [x] Provenance assumptions and failure modes are documented in `skills/doc/` authoring notes

## Definition of Done
- [x] Provenance resolution logic implemented and integrated with `/doc`
- [x] Fallback behavior implemented and documented
- [x] Authoring notes written in `skills/doc/`
- [x] All acceptance criteria pass
