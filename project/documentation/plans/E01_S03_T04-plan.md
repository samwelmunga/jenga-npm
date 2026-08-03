# Plan: E01_S03_T04 — confirm_before_run prompt and result handoff

## Goal
If config has `confirm_before_run: true`, request confirmation. Return structured result.

## Design
MCP tools are not interactive (stdin not available), so "confirmation" is implemented as:
- If `confirm_before_run: true` and the tool is called without `confirm: true` parameter,
  return a message asking the caller to re-invoke with `confirm: true`.

Final result object includes:
```json
{ "exit_code": 0, "job_dir": "...", "duration_seconds": 12.3, "output": [...], "results": {...} }
```

`results` is populated from `results.json` if present (E01_S04_T02).
