# Summary: E05_S04 — History Parsers & Endpoint

## Completed
- **T01**: `api/parsers/git-log.js` — runs `git log` via `execFile`, format `%H|||%an|||%aI|||%s|||%b`, returns `[]` on non-repo / error
- **T02**: `api/parsers/rapports.js` — recursively lists `.md` files in `project/rapports/`, extracts `filename`, `date` (frontmatter or filename pattern), `content_summary` (first 300 chars)
- **T03**: `GET /v1/history` — merges both sources, sorts by date desc; supports `?limit=N` and `?type=git_commit|rapport` query params with validation

## Notes
- History smoke test returned 3 items with no errors
