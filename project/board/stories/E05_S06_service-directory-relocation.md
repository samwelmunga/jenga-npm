---
id: E05_S06
epic_id: E05
title: Service Directory Relocation
status: Done
date_created: 2026-05-05
date_started: 2026-05-05
date_completed: 2026-05-05
tasks: [E05_S06_T01]
---

# Story: Service Directory Relocation

As a developer working across E05–E09, I want the API and dashboard services relocated to a canonical path inside `project/app/` so that all future stories build on a consistent, well-structured directory layout.

## Acceptance Criteria
- [ ] `api/` is moved to `project/app/api/`
- [ ] `dashboard/` is moved to `project/app/ui/`
- [ ] All internal file paths and imports inside each service are updated to reflect the new locations
- [ ] All config files (`vite.config.js`, `.env.example`, `package.json` scripts, etc.) reference correct relative paths
- [ ] Any hardcoded URLs or base paths in the dashboard that point to the API remain correct after the move
- [ ] The API server still starts correctly from its new location
- [ ] The dashboard still builds and serves correctly from its new location
- [ ] Any references in stories E05–E09 that mention `api/` or `dashboard/` are noted as resolved by this story

## Definition of Done
- [ ] Both services run correctly from their new paths (`project/app/api/` and `project/app/ui/`)
- [ ] No broken imports, missing assets, or incorrect URLs after relocation
