---
id: E24_S02_T01
story_id: E24_S02
epic_id: E24
title: Scaffold skills/doc/SKILL.md with default README.md target
status: Passed
date_created: 2026-07-23
date_started:
date_completed: 2026-07-24
assigned_to: developer
---

# Task: Scaffold skills/doc/SKILL.md with default README.md target

## Description
Create `skills/doc/SKILL.md` following the conventions of existing skills (see `skills/` for examples). The skill should be invocable as `/doc` in a Claude Code session. When invoked with no arguments, it defaults to targeting `README.md` as the document to generate/update.

Include proper YAML frontmatter with `name`, `description`, `metadata`, `keywords`, and `examples` fields.

## Prerequisites
None.

## Acceptance Criteria
- [ ] `skills/doc/SKILL.md` exists
- [ ] Frontmatter includes: `name: doc`, `description`, `keywords`, `examples`
- [ ] Skill is invocable as `/doc` with no arguments and defaults to `README.md` target
- [ ] Skill structure follows existing skill conventions in the project
