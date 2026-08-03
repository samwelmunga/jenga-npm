---
id: E05_S01_T01
story_id: E05_S01
epic_id: E05
title: Write API Contract Document
status: Done
date_created: 2026-05-05
date_started: 2026-05-05
date_completed: 2026-05-05
assigned_to: developer
---

# Task: Write API Contract Document

## Description
Create `docs/api-contract.md` that defines the canonical API contract for the jenga API server. This document becomes the source of truth for all subsequent API stories. It must cover:

- **Resource naming conventions**: URL structure, pluralisation, kebab-case slugs
- **Standard response envelope**: `{ data, meta, error }` shape with field-level descriptions
- **Error format**: machine-readable `code` (string enum), human-readable `message`, optional `details` array
- **Versioning strategy**: URL-prefix versioning (`/v1/`), deprecation policy, and backward-compatibility guarantees

## Prerequisites
None

## Acceptance Criteria
- [ ] `docs/api-contract.md` exists in the repository
- [ ] Document defines resource naming rules (URL structure, casing, pluralisation)
- [ ] Document specifies the full response envelope schema with field types and descriptions
- [ ] Document specifies the error response schema with `code`, `message`, and optional `details`
- [ ] Document describes the versioning strategy and how breaking changes are handled
- [ ] Subsequent story files reference this document as the source of truth
