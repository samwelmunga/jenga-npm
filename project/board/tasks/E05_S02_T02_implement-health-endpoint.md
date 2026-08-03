---
id: E05_S02_T02
story_id: E05_S02
epic_id: E05
title: Implement GET /health Endpoint
status: Done
date_created: 2026-05-05
date_started: 2026-05-05
date_completed: 2026-05-05
assigned_to: developer
---

# Task: Implement GET /health Endpoint

## Description
Add a `GET /health` endpoint to the API server that returns HTTP 200 with a JSON body confirming the server is running. The response must follow the standard API envelope.

Response body example:
```json
{
  "data": { "status": "ok", "version": "1.0.0", "uptime": 42.3 },
  "meta": { "timestamp": "2026-05-05T00:00:00.000Z", "version": "1.0.0" },
  "error": null
}
```

`version` should be read from `package.json` (or `project.config.json` if no package.json exists). `uptime` is `process.uptime()` in seconds.

## Prerequisites
- E05_S02_T01 (server entry point scaffolded)
- E05_S01_T02 (envelope types)

## Acceptance Criteria
- [ ] `GET /health` returns HTTP 200
- [ ] Response body includes `status: "ok"`, `version`, and `uptime`
- [ ] Response follows the `ApiEnvelope` shape
- [ ] Endpoint is reachable after running the server (`curl http://localhost:3001/health`)
