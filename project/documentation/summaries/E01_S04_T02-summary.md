# Summary: E01_S04_T02 — Wire start.sh result surfacing integration

## What was done
`readResultsJson(jobDir)` was added to `mcp/training_runner/index.js`.

After `runStartSh()` completes, the function:
1. Checks for `<jobDir>/results.json`
2. If present: reads and JSON-parses it, includes in the MCP response
3. If absent or invalid JSON: returns `null` — run still completes without error

The `results` value is surfaced in:
- The human-readable text response: `--- results.json ---` section
- The structured JSON response: `results` key in the result object

## Acceptance criteria
- [x] If `results.json` exists in job dir after run, contents are included in MCP result
- [x] If missing, result still returns without error
