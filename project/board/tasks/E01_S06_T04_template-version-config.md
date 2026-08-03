---
id: E01_S06_T04
story_id: E01_S06
epic_id: E01
title: Add template_version field to all config.yaml templates
status: Passed
date_created: 2026-04-29
date_started:
date_completed: 2026-05-05
dependencies:
  - E01_S02
---

# Task: Add template_version field to all config.yaml templates

Add a `template_version` semver field to the `config.yaml` of each template type.

## Description

Each of the three template directories (`classifiers/`, `transformers/`, `nlp/`) has a `config.yaml`. Add a `template_version` field (e.g. `template_version: "1.0.0"`) to each, placed alongside the `workflow:` block.

Also create (or update) a top-level template manifest file (e.g. `templates/manifest.json` or equivalent) that tracks the current canonical version for each template type. This manifest is read by the `/train` skill at scaffold and run time.

## ⚠ Dependency
**Blocked until E01_S02 is at least In Progress** — the `config.yaml` schema and `workflow:` block structure is owned by that story. Do not add `template_version` until the schema is locked to avoid duplicate edits.

## Acceptance Criteria
- All three `config.yaml` files contain a `template_version` field in semver format
- A manifest file exists that the `/train` skill can read to determine the current version per type
- Field placement is consistent with the `workflow:` block defined in E01_S02
