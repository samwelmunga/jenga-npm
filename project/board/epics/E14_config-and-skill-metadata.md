---
id: E14
title: Config & Skill Metadata
status: Done
date_created: 2026-05-09
date_started:
date_completed: 2026-05-10
stories:
  - E14_S01
  - E14_S02
---

# Epic: Config & Skill Metadata

## Purpose
Define and enforce the `jenga.cli.json` configuration schema used by the router and CLI, and enrich SKILL.md frontmatter with `keywords` and `examples` fields to improve matching quality. The schema is validated on router startup with clear error messages. Existing skills are updated to include the new frontmatter fields, and the skill template is updated so future skills include them by default.

## Definition of Done
- [ ] `jenga.cli.json` schema documented: `skillsPath`, `matchThreshold`, `sessionTimeout`, `agentTarget`
- [ ] Router validates config on startup and exits with a clear error if required fields are missing or invalid
- [ ] SKILL.md frontmatter spec updated to include optional `keywords: []` and `examples: []` fields
- [ ] All existing skills updated with `keywords` and `examples` where applicable
- [ ] Skill creation template updated to include `keywords` and `examples` stubs
