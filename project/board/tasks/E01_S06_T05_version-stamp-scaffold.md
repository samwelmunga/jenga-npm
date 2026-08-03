---
id: E01_S06_T05
story_id: E01_S06
epic_id: E01
title: Implement version-stamp logic in /train skill scaffolding
status: Passed
date_created: 2026-04-29
date_started:
date_completed: 2026-05-05
dependencies:
  - E01_S06_T04
---

# Task: Implement version-stamp logic in /train skill scaffolding

When `/train` scaffolds a new job, stamp the job's `config.yaml` with the current template version.

## Description

During the scaffold step (`/train new <type> <job-name>`), after copying the template directory:
1. Read the current version for the training type from the template manifest (created in T04).
2. Write that version into the scaffolded job's `config.yaml` as the `template_version` field.

This ensures every scaffolded job carries a record of the template version it was created from.

## Acceptance Criteria
- After scaffolding, the job's `config.yaml` contains a `template_version` field matching the current manifest version
- The stamp happens automatically — no manual step required
- If the manifest is missing or unreadable, the skill emits a warning but does not fail the scaffold

## Dependency
- T04 must be complete (manifest file and `template_version` field in templates must exist)
