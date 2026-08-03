---
id: E05_S05_T01
story_id: E05_S05
epic_id: E05
title: Implement Config File Parser
status: Done
date_created: 2026-05-05
date_started: 2026-05-05
date_completed: 2026-05-05
assigned_to: developer
---

# Task: Implement Config File Parser

## Description
Create a config parser module (`api/parsers/architecture.js`) that reads local config files and returns a structured list of dependency entries and tech stack metadata. No live registry lookups allowed.

Files to parse (read whichever exist, skip missing):
- `package.json` — `dependencies` (type: `runtime`), `devDependencies` (type: `dev`), `peerDependencies` (type: `peer`)
- `project.config.json` — any `dependencies`, `stack`, or `techStack` fields at root

Return shape:
```js
{
  tech_stack: [{ name: string, description?: string }],
  dependencies: [{ name: string, version: string, type: "runtime"|"dev"|"peer" }]
}
```

Tech stack entries may be derived from `project.config.json`'s `stack` array or inferred from top-level `package.json` fields (e.g. `engines`).

## Prerequisites
- None

## Acceptance Criteria
- [ ] Module reads `package.json` and extracts all three dependency types with correct `type` labels
- [ ] Module reads `project.config.json` when present
- [ ] Each dependency entry includes `name`, `version`, and `type`
- [ ] `tech_stack` array is populated from config data (not hardcoded)
- [ ] Missing config files are skipped without throwing
- [ ] No external network requests are made
