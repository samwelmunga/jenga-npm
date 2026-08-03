---
id: E01_S01_T02
story_id: E01_S01
epic_id: E01
title: Implement template copy and auto-suffix collision logic
status: Done
date_created: 2026-04-29
date_started: 2026-05-05
date_completed: 2026-05-05
assigned_to: developer
---

# Task: Implement template copy and auto-suffix collision logic

## Description
Inside the `/train` skill, implement the job scaffolding logic:
1. Validate that `<type>` is one of `classifiers`, `transformers`, `nlp` — error clearly if not
2. Copy `.training/template/<type>/` recursively to `.training/jobs/<job-name>/`
3. If `.training/jobs/<job-name>/` already exists, auto-suffix: try `<job-name>-2`, `<job-name>-3`, … until a free name is found. Notify the user of the rename.
4. Print the created job path on success.

## Prerequisites
None.

## Acceptance Criteria
- [ ] Copy produces an exact replica of the template directory including `.gitkeep` files
- [ ] Unsupported `<type>` exits with a descriptive error listing valid types
- [ ] Collision is handled with auto-suffix; user sees a message like: `Job 'sentiment-job' exists — created as 'sentiment-job-2'`
- [ ] No partial directories are left on failure
