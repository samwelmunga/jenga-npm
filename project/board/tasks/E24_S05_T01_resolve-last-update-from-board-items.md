---
id: E24_S05_T01
story_id: E24_S05
epic_id: E24
title: Resolve last_update from done board items with docs annotations
status: Passed
date_created: 2026-07-23
date_started:
date_completed: 2026-07-24
assigned_to: developer
---

# Task: Resolve last_update from done board items with docs annotations

## Description
Implement provenance resolution logic in the `/doc` skill. When generating or updating a documentation file, scan all Done board items (epics, stories, tasks) for `docs` annotations that include the target file path. Use the most recent `date_completed` from matching items as the `last_update` frontmatter value.

Steps:
1. Read all board files from `project/board/epics/`, `project/board/stories/`, and `project/board/tasks/`
2. Filter to items with `status: Done` (or `Passed`) and a `docs` annotation array that includes the target file path
3. Select the latest `date_completed` from matching items
4. Inject that value as `last_update` in the generated file's YAML frontmatter

## Prerequisites
- E24_S01 (board doc provenance schema) — `docs` annotations must be supported in board schema
- E24_S04 (document synthesis) — synthesis context object must be available

## Acceptance Criteria
- [ ] All Done board files are scanned for `docs` annotations matching the target file path
- [ ] The most recent `date_completed` is selected and used as `last_update`
- [ ] `last_update` appears correctly in the generated file's YAML frontmatter
