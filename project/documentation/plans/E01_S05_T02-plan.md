# Plan: E01_S05_T02 — Terminal print, summary.md, and results.json output

## Goal
After training completes, print a human-readable summary, write summary.md and results.json.

## Files
- Add `skills/train/assets/results-parsers/reporter.py` — surface_results() function

## Design
`surface_results(job_dir, job_type)`:
1. Call the appropriate type-specific parser → get metrics dict
2. Print a box-formatted terminal summary
3. Write `<job_dir>/summary.md` with the metrics as a Markdown table
4. Write/update `<job_dir>/results.json` with the structured metrics

Called by the MCP server after a successful run (when `auto_summarize` is true in config).
