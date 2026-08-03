---
id: E01_S03_T02
story_id: E01_S03
epic_id: E01
title: Implement job directory and config validation
status: Done
date_created: 2026-04-29
date_started: 2026-05-05
date_completed: 2026-05-05
assigned_to: developer
---

# Task: Implement job directory and config validation

## Description
Before executing training, the `training_runner` MCP tool must validate the job directory. Implement a validation step that checks:
1. `job_dir` exists and is a directory
2. `training/main.py` exists
3. `input/config.yaml` exists and is valid YAML
4. `input/data/` directory exists (warn if empty, do not abort)

Return a structured error object `{ valid: false, error: "<reason>" }` if any hard check fails. Proceed only if all hard checks pass.

## Prerequisites
- E01_S03_T01 (MCP scaffold) must be complete

## Acceptance Criteria
- [ ] Missing `job_dir` returns a clear structured error
- [ ] Missing `training/main.py` returns a clear structured error
- [ ] Malformed `config.yaml` returns a clear structured error
- [ ] Empty `input/data/` produces a warning but does not abort
- [ ] Valid job directory passes validation without error
