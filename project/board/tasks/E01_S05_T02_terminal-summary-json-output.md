---
id: E01_S05_T02
story_id: E01_S05
epic_id: E01
title: Implement terminal print, summary.md, and results.json output
status: Done
date_created: 2026-04-29
date_started: 2026-05-05
date_completed: 2026-05-05
assigned_to: developer
---

# Task: Implement terminal print, summary.md, and results.json output

## Description
Using the parsed results from E01_S05_T01, produce three of the four result outputs:

1. **Terminal print** — pretty-print key metrics to stdout. Format: labelled table or summary block. Include job name, type, and timestamp.
2. **`summary.md`** — written to `<job_dir>/summary.md`. Human-readable markdown with job metadata, metrics table, and any warnings from the parser.
3. **`results.json`** — written to `<job_dir>/results.json`. The normalised dict from the parser, plus job metadata: `{ job_name, type, date_completed, metrics, raw }`.

All three outputs must be skipped silently when `auto_summarize: false`.

## Prerequisites
- E01_S05_T01 (parser) must be complete

## Acceptance Criteria
- [ ] Terminal print produces readable output for each training type
- [ ] `summary.md` is written correctly for each type
- [ ] `results.json` is valid JSON and includes all required fields
- [ ] `auto_summarize: false` suppresses all three outputs without error
- [ ] Outputs are produced identically regardless of trigger path (MCP or `start.sh`)
