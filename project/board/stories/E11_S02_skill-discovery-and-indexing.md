---
id: E11_S02
epic_id: E11
title: Skill Discovery & Indexing
status: Passed
date_created: 2026-05-09
date_started:
date_completed: 2026-05-10
tasks: [E11_S02_T01, E11_S02_T02]
---

# Story: Skill Discovery & Indexing

As the router, I want to scan the `skills/` directory at startup and build an in-memory index of all available skills so that I can match incoming prompts against them efficiently.

## Acceptance Criteria
- [ ] On startup, recursively scans `skillsPath` (from `jenga.cli.json`) for `SKILL.md` files
- [ ] Parses YAML frontmatter from each file: `name`, `description`, `keywords`, `examples`
- [ ] Builds an in-memory array of skill records: `{ name, description, keywords, examples, path }`
- [ ] Skills missing optional `keywords`/`examples` fields are indexed with empty arrays (not an error)
- [ ] Index is rebuilt if the router receives a `reload_skills` tool call
- [ ] Skill count is accessible via the `ping` tool response: `{ ok: true, uptime, skill_count }`

## Definition of Done
- [ ] Index is populated within 500ms of startup for up to 50 skills
- [ ] Missing or malformed frontmatter logs a warning but does not crash the router
- [ ] `reload_skills` correctly reflects any added/removed skills without restarting the process
