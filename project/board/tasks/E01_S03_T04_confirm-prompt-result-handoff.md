---
id: E01_S03_T04
story_id: E01_S03
epic_id: E01
title: Implement confirm_before_run prompt and result handoff
status: Done
date_created: 2026-04-29
date_started: 2026-05-05
date_completed: 2026-05-05
assigned_to: developer
---

# Task: Implement confirm_before_run prompt and result handoff

## Description
Before spawning the training subprocess, check `config.yaml` for `workflow.confirm_before_run`. If `true`, prompt the user for explicit confirmation (y/n). Abort cleanly on decline — return `{ confirmed: false }` without spawning the process or leaving side effects.

On successful completion, if `workflow.auto_summarize: true`, invoke the result surfacing logic (E01_S05) passing `job_dir` and training type. This wires the MCP into the post-training result pipeline.

## Prerequisites
- E01_S03_T03 (subprocess execution) must be complete
- E01_S05 result surfacing must be available (or stub-able)

## Acceptance Criteria
- [ ] `confirm_before_run: true` prompts user before execution
- [ ] Declining returns `{ confirmed: false }` cleanly with no subprocess spawned
- [ ] `confirm_before_run: false` proceeds without prompting
- [ ] On clean exit + `auto_summarize: true`, result surfacing is invoked with correct `job_dir` and type
