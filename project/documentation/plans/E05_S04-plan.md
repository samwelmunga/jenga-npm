# Plan: E05_S04 — History Parsers & Endpoint

## Tasks
- **T01**: `api/parsers/git-log.js` — run `git log` as child process, parse commits
- **T02**: `api/parsers/rapports.js` — scan `project/rapports/` for `.md` files
- **T03**: `GET /history` — merge + sort by date, support `?limit` and `?type` filters

## Approach
- git-log returns `[]` on non-git repos (no throw)
- rapports returns `[]` if directory missing
- Merge sort by ISO date string descending
