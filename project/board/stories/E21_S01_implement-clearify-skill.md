---
id: E21_S01
epic: E21
title: Implement /clearify skill with /wtf alias
status: Pending
date_created: 2026-07-10
date_started:
date_completed:
tasks: []
---

# Story: Implement /clearify skill with /wtf alias

## Goal
Create the `/clearify` skill so users can flag confusion at any point in a conversation. The skill analyses the attached prompt (if present) and the current conversation, surfaces every ambiguous or dense formulation, and delivers: a plain-language clarification, a simplified restatement, extra context/background, and concrete examples.

## Acceptance Criteria
- [ ] `skills/clearify/SKILL.md` created with YAML frontmatter: `name`, `description`, `keywords`, `examples`
- [ ] Frontmatter includes an `alias: wtf` field (or equivalent alias registration)
- [ ] Skill instructions tell the agent to: inspect attached prompt + conversation context, identify ambiguities, then output structured clarifications (plain language, simplified version, context, examples)
- [ ] `/wtf` invocation routes to the same skill (alias entry in `workflow.json` or equivalent)
- [ ] `/help` lists both `/clearify` and `/wtf`

## Notes
- Skill should work with zero attached prompts (falling back to the last user message / recent conversation)
- Output format should be scannable — use headers or bullets per ambiguous item
