---
id: E22_S01_T02
story_id: E22_S01
epic_id: E22
title: Define and document publish.json config schema
status: Passed
date_created: 2026-07-11
date_started:
date_completed: 2026-07-11
assigned_to: developer
---

# Task: Define and document publish.json config schema

## Description
Define the structure of `publish.json` — the canonical config file for the `/publish` skill. This is a design + documentation task; no wizard or deploy logic is implemented here.

The schema must cover:
- `targets` array — each target has a `name`, `type` (e.g. `mobile-ios`), `platform`, and `checks` array
- `secrets` represented as env var references (no literal values ever stored)
- Per-target overrides for quality gate configuration
- A JSON Schema file (`skills/publish/schemas/publish.schema.json`) that can be used by tools or scripts to validate user-provided `publish.json`
- Example `publish.json` written as a comment-annotated sample at `skills/publish/assets/publish.example.json`

## Prerequisites
None.

## Acceptance Criteria
- [ ] `skills/publish/schemas/publish.schema.json` exists and is a valid JSON Schema (draft-07 or later)
- [ ] Schema covers: `targets[]`, each with `name`, `type`, `platform`, `checks[]`, and `secrets` as env var ref strings
- [ ] `skills/publish/assets/publish.example.json` exists as a documented example config
- [ ] Schema is referenced from `skills/publish/SKILL.md`
