---
id: E24_S04
epic_id: E24
title: Document synthesis and regeneration
status: Passed
date_created: 2026-07-23
date_started:
date_completed: 2026-07-23
tasks:
  - E24_S04_T01
  - E24_S04_T02
  - E24_S04_T03
  - E24_S04_T04
---

# Story: Document synthesis and regeneration

Implement the full-file generation flow. `/doc` owns the entire file — it reads the existing file for context before regenerating. Sections are conditional on scope.

## Acceptance Criteria
- [x] `/doc` reads the existing target file (if present) for intent before regenerating
- [x] The generated file is fully owned by `/doc` — the entire file is regenerated, not patched
- [x] Project-overview docs include a Description (<1000 words) and a Getting Started section
- [x] An Examples section is included only when the project produces user-facing output (API, CLI, library, SDK)
- [x] Non-README targets (API doc, CLI doc, etc.) are supported via the path→objective rule table

## Definition of Done
- [x] Full-file generation flow implemented
- [x] Conditional Examples section logic implemented and tested
- [x] Non-README target generation validated against at least one additional target
- [x] All acceptance criteria pass
