# Plan: E09_S01_T02 — `jenga dashboard start --serve-app` Flag

## Approach
Extend `dashboard-start.js` to optionally serve the built dashboard dist files.

## Steps
1. Parse `--serve-app` flag from `process.argv`
2. If set, add `express.static` middleware in the server pointing to `dashboard/dist/`
3. Print both API URL and app URL when `--serve-app` is active
4. Keep backward compatible when flag is absent
