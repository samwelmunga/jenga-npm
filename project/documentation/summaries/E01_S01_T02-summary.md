# Summary: E01_S01_T02 — Template copy and auto-suffix collision logic

## What was done
The `_scaffold_job()` function in `skills/train/train_cli.py` already correctly implements:
- Copying the template from `.training/template/<type>/` to `jobs/<job-name>/`
- Auto-suffixing: if `jobs/<job-name>/` exists, tries `jobs/<job-name>-1/`, `-2/`, etc.
- Informing the user of the final directory name in the ✅ success output

No code changes were required — the implementation was already complete and correct.

## Acceptance criteria
- [x] Template is copied from `.training/template/<type>/` to `jobs/<job-name>/`
- [x] If `jobs/<job-name>/` already exists, auto-suffix: `jobs/<job-name>-1/`, `jobs/<job-name>-2/`
- [x] User is informed of the final directory used
