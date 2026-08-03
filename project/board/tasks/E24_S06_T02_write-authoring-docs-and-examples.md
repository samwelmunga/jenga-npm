---
id: E24_S06_T02
story_id: E24_S06
epic_id: E24
title: Write authoring docs and usage examples for /doc
status: Passed
date_created: 2026-07-23
date_started:
date_completed: 2026-07-24
assigned_to: developer
---

# Task: Write authoring docs and usage examples for /doc

## Description
Write comprehensive authoring documentation and usage examples for the `/doc` skill. Cover both the default usage (regenerate `README.md`) and custom target usage (e.g. `docs/API.md`).

Content to cover:
1. Basic invocation: `/doc` (default target: `README.md`)
2. Custom target invocation: `/doc update: docs/API.md`
3. How evidence is collected and which sources take precedence
4. How `last_update` provenance works
5. What triggers the ambiguity gate (unknown targets)
6. Tips for board authors: when to add `docs` annotations to board items

Deliver as `skills/doc/README.md` or as an expanded section within `skills/doc/SKILL.md`.

## Prerequisites
- E24_S05_T03 (provenance authoring notes should exist before this doc is written)

## Acceptance Criteria
- [ ] Default usage (`/doc`) is documented with an example
- [ ] Custom target usage is documented with an example
- [ ] Provenance and `last_update` behavior is explained
- [ ] Ambiguity gate is explained with an example unknown target
- [ ] Docs are located in `skills/doc/`
