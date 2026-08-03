---
id: E11_S02_T01
story_id: E11_S02
epic_id: E11
title: Implement recursive skill directory scanner
status: Passed
date_created: 2026-05-09
date_started: 2026-05-09
date_completed: 2026-05-09
assigned_to: developer
---

# Task: Implement recursive skill directory scanner

## Description
On router startup, recursively scan the `skillsPath` directory (from `jenga.cli.json`) for `SKILL.md` files. For each file found, parse the YAML frontmatter (`name`, `description`, `keywords`, `examples`). Build an in-memory array of skill records: `{ name, description, keywords, examples, path }`. Missing optional fields default to empty arrays.

## Prerequisites
- E11_S01_T01

## Acceptance Criteria
- [x] All SKILL.md files in `skillsPath` are discovered on startup
- [x] Frontmatter is parsed correctly; missing `keywords`/`examples` default to `[]`
- [x] Malformed frontmatter logs a warning but does not crash
- [x] Index is populated within 500ms for up to 50 skills
