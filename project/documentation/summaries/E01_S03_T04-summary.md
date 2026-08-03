# Summary: E01_S03_T04 — confirm_before_run prompt and result handoff

## What was done
In `mcp/training_runner/index.js`:

**confirm_before_run gate:**
- Tool accepts an optional `confirm: boolean` parameter (default `false`)
- If `config.workflow.confirm_before_run === true` and `confirm` is `false`:
  - Returns a warning message instructing the caller to re-invoke with `confirm: true`
  - Does NOT execute training

**Structured result:**
After a successful run, returns two content blocks:
1. Human-readable summary (status, job_dir, duration, exit_code, output lines)
2. JSON object: `{ exit_code, job_dir, duration_seconds, output[], results }`

`results` is populated from `results.json` if present (E01_S04_T02).

## Acceptance criteria
- [x] If `confirm_before_run: true` in config, prompts for confirmation before running
- [x] Final result includes: `exit_code`, `job_dir`, `duration_seconds`
