---
id: E01_S03
epic_id: E01
title: training_runner MCP Tool
status: Done
date_created: 2026-04-29
date_started: 2026-05-05
date_completed: 2026-05-05
tasks:
  - E01_S03_T01
  - E01_S03_T02
  - E01_S03_T03
  - E01_S03_T04
---

# Story: training_runner MCP Tool

As a developer, I want an MCP tool that runs a training job as a managed subprocess so that the agent can execute, monitor, and stream training output within the session without leaving the workflow context.

## Acceptance Criteria
- [ ] MCP server is scaffolded at `mcp/training-runner/` and registered as the `training_runner` tool
- [ ] Tool validates the job directory structure (required files present) and `config.yaml` schema before execution; returns a structured error object if invalid
- [ ] When `confirm_before_run: true` in config, the tool prompts the user for confirmation and aborts cleanly on decline
- [ ] `python training/main.py` is run as a subprocess with stdout streamed into the agent session in real time
- [ ] Tool returns a structured result object: `{ exit_code, stdout_tail, job_dir, duration_s }`
- [ ] Non-zero exit code is surfaced as a clear error, not a silent failure

## Definition of Done
- [ ] MCP server is functional and registered
- [ ] All acceptance criteria pass under both `auto_run: true` and manual invocation paths
- [ ] Validation rejects a job dir with missing `input/data/` or malformed `config.yaml`
