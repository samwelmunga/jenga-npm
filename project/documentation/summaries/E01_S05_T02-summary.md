# Summary: E01_S05_T02 — Terminal print, summary.md, and results.json output

## What was done
Created `skills/train/assets/results-parsers/reporter.py` with `surface_results(job_dir, job_type)`:

1. **Terminal summary** — Prints a box-formatted table with key metrics
2. **summary.md** — Writes a Markdown file with metric table to `<job_dir>/summary.md`
3. **results.json** — Writes/updates `<job_dir>/results.json` with structured data including `job_name`, `job_type`, `generated_at`, and `metrics` dict

Also executable as CLI: `python reporter.py <job_dir> <job_type>`

## Acceptance criteria
- [x] Terminal summary is printed with key metrics
- [x] `summary.md` is written to job dir
- [x] `results.json` is written to job dir with structured data
