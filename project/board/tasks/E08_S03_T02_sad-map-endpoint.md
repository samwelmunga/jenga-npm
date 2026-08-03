---
id: E08_S03_T02
story_id: E08_S03
epic_id: E08
title: Include SAD Map in GET /architecture Response
status: Done
date_created: 2026-05-05
date_started:
date_completed:
assigned_to: developer
---

# Task: Include SAD Map in GET /architecture Response

## Description
The parser already powers `GET /architecture`. Once `E08_S03_T01` adds `sad_map` to the parser output, verify that the existing endpoint at `project/app/api/routes/architecture.js` passes `sad_map` through without changes.

If the route filters or restructures the parser output (it currently passes it through directly), ensure `sad_map` is included in the response `data` object.

Expected updated response shape:
```json
{
  "tech_stack": [...],
  "dependencies": [...],
  "sad_map": {
    "nodes": [{ "id": "E08", "label": "Agent Dashboard — Architecture Tab", "type": "epic" }],
    "edges": [{ "from": "E08", "to": "E08_S01" }]
  }
}
```

## Prerequisites
- E08_S03_T01 — sad_map must exist in parser output

## Acceptance Criteria
- [ ] `GET /architecture` response includes a `sad_map` key in `data`
- [ ] `data.sad_map.nodes` is an array
- [ ] `data.sad_map.edges` is an array
- [ ] Endpoint still returns HTTP 200 with correct envelope shape
- [ ] Verifiable via `curl http://localhost:3001/architecture | grep sad_map`
