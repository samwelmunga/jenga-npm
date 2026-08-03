---
id: E01_S03_T03
story_id: E01_S03
epic_id: E01
title: Implement subprocess execution with stdout streaming
status: Done
date_created: 2026-04-29
date_started: 2026-05-05
date_completed: 2026-05-05
assigned_to: developer
---

# Task: Implement subprocess execution with stdout streaming

## Description
Implement the core execution logic in the `training_runner` MCP tool. Spawn `python training/main.py` as a child process with `cwd` set to `job_dir`. Stream stdout and stderr line-by-line back through the MCP tool response as they arrive. On process exit, return a structured result:

```json
{
  "exit_code": 0,
  "stdout_tail": "<last N lines of output>",
  "job_dir": "<absolute path>",
  "duration_s": 42.3
}
```

Non-zero exit codes must be surfaced as a clear error — not a silent success.

## Prerequisites
- E01_S03_T02 (validation) must be complete

## Acceptance Criteria
- [ ] Subprocess is spawned with correct `cwd`
- [ ] stdout/stderr are streamed in real time (not buffered until exit)
- [ ] Structured result is returned on clean exit
- [ ] Non-zero exit code sets `exit_code` and includes tail of stderr in result
- [ ] Process timeout or crash is caught and returned as a structured error
