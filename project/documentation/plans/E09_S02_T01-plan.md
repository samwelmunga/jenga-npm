# Plan: E09_S02_T01 — `jenga dashboard open` CLI Command

## Approach
Create `dashboard/scripts/dashboard-open.js` that health-checks the server and opens the browser.

## Steps
1. Parse `--port` flag, default 3001
2. Perform health check: `GET http://localhost:<port>/health` with 2s timeout using `http.get`
3. On success: launch browser via `open` (macOS), `xdg-open` (Linux), `start` (Windows)
4. On browser launch failure: print URL to stdout
5. On health check failure: print warning, then print URL
6. Exit code 0 in all cases
