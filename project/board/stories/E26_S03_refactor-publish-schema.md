---
id: E26_S03
epic_id: E26
title: Refactor publish schema to support multiple target types
status: Passed
date_created: 2026-07-31
date_started: 2026-07-31
date_completed: 2026-07-31
dates_previously_completed:
reopened_on:
reopened_reason:
docs: []
tasks:
  - E26_S03_T01
  - E26_S03_T02
---

# Story: Refactor publish schema to support multiple target types

As a developer using `/publish`, I want the `publish.json` schema to support both `mobile-ios` and `npm` target types so that a single config file can hold targets of either type without validation errors.

## Acceptance Criteria
- [ ] `publish.schema.json` accepts `type: "npm"` as a valid target type alongside `type: "mobile-ios"`
- [ ] An npm target does **not** require the `ios` settings block — the schema does not flag its absence as an error
- [ ] A `mobile-ios` target still requires the `ios` settings block — existing iOS validation is not regressed
- [ ] An npm target accepts an `npm` settings block with the following fields: `package_name` (string, required), `access` (enum: `"public"` | `"restricted"`, required), `registry` (string, optional, default `"https://registry.npmjs.org"`), `dist_tag` (string, optional, default `"latest"`)
- [ ] The `secretMap` for an npm target requires only `NPM_TOKEN` (or `NODE_AUTH_TOKEN`) — iOS secrets are not required
- [ ] A `publish.example.npm.json` example file is created alongside the existing iOS example
- [ ] Existing iOS example (`publish.example.json`) validates successfully against the updated schema

## Definition of Done
- [ ] `publish.schema.json` uses conditional validation (`if`/`then`/`else` or `oneOf`) keyed on `type`
- [ ] `npm` is added to the `type` enum; `npm-registry` and `github-packages` are added to the `platform` enum
- [ ] Schema passes JSON Schema validation (draft-07 or later)
- [ ] `skills/publish/assets/publish.example.npm.json` exists and is a valid npm target config
- [ ] Existing `publish.example.json` (iOS) still validates against the updated schema without changes
