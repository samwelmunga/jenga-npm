---
id: E05_S02
epic_id: E05
title: Server Bootstrap & Routing
status: Done
date_created: 2026-05-05
date_started: 2026-05-05
date_completed: 2026-05-05
tasks: [E05_S02_T01, E05_S02_T02, E05_S02_T03]
---

# Story: Server Bootstrap & Routing

As a developer, I want the jenga API server to start cleanly with a structured router and a health endpoint so that consumers can verify connectivity before making data requests.

## Acceptance Criteria
- [ ] Running the server starts an HTTP listener on a configurable port (default: `3001`)
- [ ] `GET /health` returns `200 OK` with server status and version info
- [ ] The router is structured so new endpoint groups can be registered cleanly
- [ ] Graceful shutdown handles in-flight requests before closing
- [ ] Server logs startup port and any configuration on launch

## Definition of Done
- [ ] Server starts, responds to `GET /health`, and shuts down cleanly
- [ ] Port is configurable via environment variable or config file
