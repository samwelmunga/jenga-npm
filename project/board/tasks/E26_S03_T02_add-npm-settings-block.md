---
id: E26_S03_T02
story_id: E26_S03
epic_id: E26
title: Add npm settings block and example config to schema
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

# Task: Add npm settings block and example config to schema

## Description
Add a new `npm` settings block definition to `publish.schema.json` with the following fields:
- `package_name` (string, required) — the npm package name (e.g. `"jenga-agent"`)
- `access` (enum: `"public"` | `"restricted"`, required)
- `registry` (string, optional, default `"https://registry.npmjs.org"`)
- `dist_tag` (string, optional, default `"latest"`)

Also create `skills/publish/assets/publish.example.npm.json` — an annotated example of a valid npm target configuration. The example should demonstrate a typical public registry publish with `dist_tag: "latest"` and a dry-run field if supported.

## Prerequisites

## Acceptance Criteria
- [x] `publish.schema.json` defines the `npm` settings block with all four fields
- [x] `package_name` and `access` are required in the npm block; `registry` and `dist_tag` are optional with documented defaults
- [x] `skills/publish/assets/publish.example.npm.json` exists and is a valid npm target config that passes schema validation
- [x] The example file includes inline comments or a README note explaining each field
