# Plan: E01_S04_T02 — Wire start.sh result surfacing integration

## Goal
After training completes in the MCP runner, read `results.json` from the job directory
(if present) and include it in the MCP result response.

## Status
Already wired in `mcp/training_runner/index.js` via `readResultsJson(jobDir)`.

## What was built
`readResultsJson(jobDir)`:
- Checks for `<jobDir>/results.json`
- If present: parses and returns the object
- If absent or parse fails: returns `null`

The result is included in:
1. The human-readable summary (appended as `--- results.json ---` block)
2. The structured JSON result object (`results` key)

If missing, the response still returns normally with `results: null`.
