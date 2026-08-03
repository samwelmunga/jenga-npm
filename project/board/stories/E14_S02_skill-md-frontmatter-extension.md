---
id: E14_S02
epic_id: E14
title: SKILL.md Frontmatter Extension
status: Passed
date_created: 2026-05-09
date_started:
date_completed: 2026-05-10
tasks: [E14_S02_T01, E14_S02_T02, E14_S02_T03]
---

# Story: SKILL.md Frontmatter Extension

As the matching engine, I want skills to declare `keywords` and `examples` in their frontmatter so that matching quality is significantly improved over description-only matching.

## Acceptance Criteria
- [ ] SKILL.md frontmatter spec is updated to include two new optional fields:
  - `keywords: []` — array of strings; single words or short phrases the router should associate with this skill
  - `examples: []` — array of natural-language prompt examples that should trigger this skill
- [ ] All existing skills in `skills/` are updated to include appropriate `keywords` and `examples`
- [ ] The skill creation template (`templates/` or equivalent) is updated to include stub `keywords` and `examples` fields with comments
- [ ] Router's skill indexer (E11_S02) already handles these fields — confirm no indexer changes are needed (or note them as a dependency)

## Definition of Done
- [ ] Every existing skill has at least 3 `keywords` and 2 `examples` in its frontmatter
- [ ] Skill template generates frontmatter with `keywords: []` and `examples: []` stubs
- [ ] Router correctly indexes the new fields (verified via `list_skills` tool output)
