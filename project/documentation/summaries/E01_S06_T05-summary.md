# Summary: E01_S06_T05 — Implement version-stamp logic in /train skill scaffolding

## What was implemented
Added `_stamp_template_version(dest, job_type)` helper to `skills/train/train_cli.py` and wired it into `_scaffold_job()`.

## How it works
1. After `shutil.copytree` copies the template, `_stamp_template_version` is called
2. Reads `.training/template/manifest.json` to get the current version for the job type
3. Writes `template_version: <version>` into the scaffolded job's `input/config.yaml`
4. Any failure (missing manifest, unreadable config) emits a `⚠️` warning but never fails the scaffold

## Test
`train new classifiers test-stamp-job` → `jobs/test-stamp-job/input/config.yaml` → `template_version: 1.0.0` ✅

## Acceptance criteria
- [x] After scaffolding, job's config.yaml contains `template_version` matching manifest version
- [x] Stamp happens automatically
- [x] Missing manifest → warning only, scaffold continues
