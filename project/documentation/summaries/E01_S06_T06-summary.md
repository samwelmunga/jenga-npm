# Summary: E01_S06_T06 — Implement drift-warning logic in /train skill CLI

## What was implemented
Added `_check_template_version_drift(job_dir)` to `skills/train/train_cli.py`, called at the start of `cmd_run()`.

## How it works
1. Reads `template_version` from job's `input/config.yaml`
2. Reads current version from `.training/template/manifest.json`
3. Semver comparison — if job version < manifest version: prints warning
4. Any exception is swallowed — never blocks execution

## Warning format
```
⚠  Template version mismatch: job uses 0.9.0, current template is 1.0.0. Consider re-scaffolding or manually updating assets.
```

## Acceptance criteria
- [x] Warning printed when job template_version < current manifest version
- [x] No warning when versions match
- [x] Execution never halted by version mismatch
- [x] Warning clearly identifies both versions and suggests an action
