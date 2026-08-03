---
id: E05_S03_T01
story_id: E05_S03
epic_id: E05
title: Implement Markdown Board Parser
status: Done
date_created: 2026-05-05
date_started: 2026-05-05
date_completed: 2026-05-05
assigned_to: developer
---

# Task: Implement Markdown Board Parser

## Description
Create a board parser module (`api/parsers/board.js`) that reads the `project/board/` directory and returns a structured in-memory representation of epics, stories, and tasks.

The parser must:
- Scan `project/board/epics/` for epic files, extracting frontmatter fields: `id`, `title`, `status`, `date_created`, `date_started`, `date_completed`
- Scan `project/board/stories/` for story files, extracting: `id`, `epic_id`, `title`, `status`, dates, `tasks` array
- Scan `project/board/tasks/` for task files, extracting: `id`, `story_id`, `epic_id`, `title`, `status`, `assigned_to`, dates
- Nest stories under their parent epic and nest tasks under their parent story
- Use a YAML frontmatter parser (e.g. `gray-matter` or manual regex) — no external HTTP calls

Return shape:
```js
[{ id, title, status, dates, stories: [{ id, title, status, dates, tasks: [...] }] }]
```

## Prerequisites
- `project/board/` directory structure exists with epic, story, and task files

## Acceptance Criteria
- [ ] Parser reads all epic, story, and task files from `project/board/`
- [ ] Frontmatter fields (id, title, status, all dates, assigned_to) are extracted correctly
- [ ] Stories are nested under the correct epic via `epic_id`
- [ ] Tasks are nested under the correct story via `story_id`
- [ ] Parser returns a consistent JS object array (no file I/O leaking outside the module)
- [ ] Missing or malformed files are skipped with a console warning (not a crash)
