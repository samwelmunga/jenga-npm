# Plan: E01_S06_T05 — Implement version-stamp logic in /train skill scaffolding

## What
After scaffolding a job, stamp the `template_version` field in the job's `config.yaml` with the current version from the template manifest.

## Files to modify
- `skills/train/train_cli.py` — add `_stamp_template_version()` helper, call it from `_scaffold_job()`

## Design
- `_stamp_template_version(dest, job_type)` reads `.training/template/manifest.json`
- Extracts version for the given type, writes it into the scaffolded `config.yaml`
- On any error (missing manifest, missing config): emits a warning but does not fail
- Called automatically at end of `_scaffold_job()` — no manual step required
