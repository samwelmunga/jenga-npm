# Plan: E01_S01_T02 — Template copy and auto-suffix collision logic

## Goal
When `new <type> <job-name>` is invoked and a job directory already exists,
auto-suffix with `-1`, `-2`, etc. Templates live in `.training/template/<type>/`.

## Files to touch
- `skills/train/train_cli.py` — `_scaffold_job()` already handles this; verify and document

## Design
`_scaffold_job()` already:
1. Copies from `.training/template/<type>/` to `jobs/<job-name>/`
2. Auto-suffixes: iterates `-1`, `-2`, … until a free name is found
3. Informs the user of the final directory name via the success message

The function is already correct. This task is satisfied by the existing implementation.

## Verification
- Running `new classifiers my-job` twice produces `jobs/my-job/` and `jobs/my-job-1/`
- User sees the final directory name in the ✅ output line
