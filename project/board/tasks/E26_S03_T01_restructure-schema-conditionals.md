---
id: E26_S03_T01
story_id: E26_S03
epic_id: E26
title: Restructure publish.schema.json for conditional type validation
status: Passed
date_created: 2026-07-31
date_started: 2026-07-31
date_completed: 2026-07-31
dates_previously_completed:
reopened_on:
reopened_reason:
assigned_to: developer
docs: []
---

# Task: Restructure publish.schema.json for conditional type validation

## Description
Refactor `skills/publish/schemas/publish.schema.json` to use JSON Schema conditional validation (`if`/`then`/`else` or `oneOf`) keyed on the `type` field of each target entry. The `ios` settings block must remain required when `type: "mobile-ios"` but must not be required (and should not even be validated) when `type: "npm"`. Add `"npm"` to the `type` enum, and `"npm-registry"` and `"github-packages"` to the `platform` enum. The `secretMap` must also be conditionally required: iOS secrets for iOS targets, `NPM_TOKEN` for npm targets.

After refactoring, validate the schema itself using a JSON Schema validator to confirm it is draft-07 compliant.

## Prerequisites

## Acceptance Criteria
- [x] `type` enum includes `"npm"` alongside `"mobile-ios"`
- [x] `platform` enum includes `"npm-registry"` and `"github-packages"`
- [x] A target with `type: "npm"` passes schema validation without an `ios` block
- [x] A target with `type: "mobile-ios"` still fails schema validation if the `ios` block is absent
- [x] The schema itself passes JSON Schema draft-07 validation
- [x] Existing `publish.example.json` (iOS) still validates without modification
