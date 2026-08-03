---
id: E22_S01_T01
story_id: E22_S01
epic_id: E22
title: Create skills/publish/SKILL.md with frontmatter and sub-command scaffolding
status: Passed
date_created: 2026-07-11
date_started:
date_completed: 2026-07-11
assigned_to: developer
---

# Task: Create skills/publish/SKILL.md with frontmatter and sub-command scaffolding

## Description
Create the `/publish` skill entry point. This includes:
- `skills/publish/SKILL.md` with full YAML frontmatter (`name`, `description`, `keywords`, `examples`, `metadata`)
- Four sub-command definitions: `setup`, `deploy`, `history`, `release-notes`
- A clear usage section showing CLI signatures and option flags
- Register the skill in the `/help` listing (i.e. ensure the SKILL.md is detectable by the `mcp/help` server and matches the pattern of other skills)

## Prerequisites
None.

## Acceptance Criteria
- [ ] `skills/publish/SKILL.md` exists
- [ ] YAML frontmatter includes `name: publish`, `description`, `keywords`, and `examples`
- [ ] Skill defines four sub-commands (`setup`, `deploy`, `history`, `release-notes`) with usage signatures
- [ ] Running `/help` (via `mcp/help`) lists the new skill
