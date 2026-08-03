# Plan: E05_S03 — Board Parser & Routes

## Tasks
- **T01**: `api/parsers/board.js` — scan epics/stories/tasks markdown, parse frontmatter, nest hierarchy
- **T02**: `GET /board` — return full nested board
- **T03**: `GET /board/:epicId` — return single epic (404 if not found)

## Approach
- Use `gray-matter` for frontmatter parsing
- Skip malformed files with console.warn
- Case-insensitive epic ID matching
