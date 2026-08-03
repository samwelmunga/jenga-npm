---
id: E01_S06_T06
story_id: E01_S06
epic_id: E01
title: Implement drift-warning logic in /train skill CLI
status: Passed
date_created: 2026-04-29
date_started:
date_completed: 2026-05-05
dependencies:
  - E01_S06_T05
---

# Task: Implement drift-warning logic in /train skill CLI

When running `/train` on an existing job, warn the user if the job's template version is behind the current manifest version.

## Description

At the start of any `/train` run (not scaffold) on an existing job:
1. Read `template_version` from the job's `config.yaml`.
2. Read the current version from the template manifest.
3. If the job version is behind (semver comparison), print a non-blocking warning:
   ```
   ⚠ Template version mismatch: job uses 1.0.0, current template is 1.1.0. Consider re-scaffolding or manually updating assets.
   ```
4. Continue execution regardless — this is a warning, not a blocker.

## Acceptance Criteria
- Warning is printed when job `template_version` < current manifest version
- No warning is printed when versions match
- Execution is never halted by a version mismatch
- Warning message clearly identifies both versions and suggests an action

## Dependency
- T05 must be complete (version stamping must exist for jobs to have a `template_version` to compare)
