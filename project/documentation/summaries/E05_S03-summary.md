# Summary: E05_S03 — Board Parser & Routes

## Completed
- **T01**: `api/parsers/board.js` — scans `project/board/{epics,stories,tasks}/`, parses frontmatter via `gray-matter`, nests tasks under stories (by `story_id`) and stories under epics (by `epic_id`), skips malformed files with `console.warn`
- **T02**: `GET /v1/board` — returns full nested board in envelope
- **T03**: `GET /v1/board/:epicId` — case-insensitive match; 404 with `EPIC_NOT_FOUND` when not found

## Notes
- Verified: 9 epics parsed, E05 lookup works
