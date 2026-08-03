---
id: E01_S04_T01
story_id: E01_S04
epic_id: E01
title: Implement start.sh template and generation logic
status: Done
date_created: 2026-04-29
date_started: 2026-05-05
date_completed: 2026-05-05
assigned_to: developer
---

# Task: Implement start.sh template and generation logic

## Description
In the `/train` skill, when `workflow.generate_start_sh: true`, generate a `start.sh` file inside the job directory. The script must:
1. `cd` to the job directory
2. Run `python training/main.py`
3. On exit 0, invoke result surfacing (call the result surfacing entry point, passing job dir and type)
4. On non-zero exit, print a clear failure message with exit code

The script must be written with `chmod +x` applied at creation.

## Prerequisites
- E01_S01_T02 (copy logic) must be complete

## Acceptance Criteria
- [ ] `start.sh` is only created when `generate_start_sh: true`
- [ ] Script is executable immediately after creation
- [ ] Script runs from the correct working directory
- [ ] Exit 0 triggers result surfacing; non-zero exits with a clear message
- [ ] Script is valid bash (passes `bash -n` syntax check)
