---
id: E01_S01_T04
story_id: E01_S01
epic_id: E01
title: Implement workflow: block branching and next-steps output
status: Done
date_created: 2026-04-29
date_started: 2026-05-05
date_completed: 2026-05-05
assigned_to: developer
---

# Task: Implement workflow: block branching and next-steps output

## Description
After scaffolding and config merge, read the `workflow:` block from the merged `config.yaml` and branch:
- `auto_run: true` → invoke `training_runner` MCP tool
- `generate_start_sh: true` → call `start.sh` generation logic (delegates to E01_S04)
- `confirm_before_run: true` (with `auto_run`) → prompt user before invoking MCP
- Default (no auto_run, no start_sh) → scaffold only

On completion, print a next-steps summary: job directory path, reminder to add data to `input/data/`, reminder to review `config.yaml`, and how to run (MCP, start.sh, or manual).

## Prerequisites
- E01_S01_T02 (copy logic) must be complete
- E01_S01_T03 (config merge) must be complete

## Acceptance Criteria
- [ ] Each `workflow:` flag produces the correct branch behaviour
- [ ] `confirm_before_run` prompt aborts cleanly on user decline without leaving a broken job dir
- [ ] Next-steps message is always printed regardless of execution path
- [ ] When `start.sh` was generated, its path is mentioned in next-steps
