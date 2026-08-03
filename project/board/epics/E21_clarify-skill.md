---
id: E21
title: Clarify Skill (/clearify + /wtf)
status: Pending
date_created: 2026-07-10
date_started:
date_completed:
stories:
  - E21_S01
---

# Epic: Clarify Skill (/clearify + /wtf)

## Purpose
Introduce a `/clearify` skill (alias `/wtf`) that lets users signal they don't fully understand something. The skill analyses any attached prompt together with the current conversation, identifies ambiguous formulations, and returns clarifications, simplifications, additional context, and concrete examples.

## Definition of Done
- [ ] `skills/clearify/SKILL.md` exists with correct frontmatter (name, description, keywords, examples, alias)
- [ ] Skill inspects attached prompt (if any) and current conversation context for ambiguity
- [ ] Output covers: plain-language clarification, simplified restatement, additional context, and worked examples where helpful
- [ ] `/wtf` alias is registered and routes to the same skill
- [ ] Skill is listed in `/help` output
