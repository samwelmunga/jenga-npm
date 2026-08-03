# Plan: E01_S06_T06 — Implement drift-warning logic in /train skill CLI

## What
At the start of any `train run` on an existing job, compare the job's `template_version` against the current manifest version and print a non-blocking warning if behind.

## Files to modify
- `skills/train/train_cli.py` — add `_check_template_version_drift()`, call at top of `cmd_run()`

## Design
- Read `template_version` from job's `input/config.yaml`
- Read current version from `.training/template/manifest.json`
- Semver comparison: if job < current → print `⚠  Template version mismatch: ...`
- All errors caught silently — drift check never blocks execution
