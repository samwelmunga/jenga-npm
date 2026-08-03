# Plan: E05_S05 — Architecture Parser & Endpoint

## Tasks
- **T01**: `api/parsers/architecture.js` — read `package.json` + `project.config.json`
- **T02**: `GET /architecture` — return tech stack and dependencies

## Approach
- Merge both config files; gracefully handle missing files
- Classify deps as `runtime` vs `devDependency`
