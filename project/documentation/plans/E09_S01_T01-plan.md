# Plan: E09_S01_T01 — `jenga dashboard start` CLI Command

## Approach
Create `dashboard/scripts/dashboard-start.js` — a standalone Node.js script that starts the API server.

## Steps
1. Parse `--port` flag from `process.argv`, default to 3001
2. Set `JENGA_API_PORT` env var and `require('../api/server.js')` (or spawn as subprocess)
3. Print `Dashboard API running at http://localhost:<port>` on server ready
4. Register SIGINT/SIGTERM handlers for clean shutdown
5. Document in `dashboard/package.json` as `npm run start:api`
