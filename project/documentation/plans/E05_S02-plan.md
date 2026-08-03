# Plan: E05_S02 — Server Scaffold, Health & Graceful Shutdown

## Tasks
- **T01**: `api/server.js` — Express app, modular route registration, env-based port, exports
- **T02**: `GET /health` — status, version, uptime
- **T03**: SIGTERM/SIGINT graceful shutdown with 5s timeout

## Approach
- Separate `app` export from `listen` so tests can import without binding ports
- Read version from `project.config.json` (no package.json at root initially)
- Shutdown drains in-flight requests then exits cleanly
