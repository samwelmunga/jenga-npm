---
id: E02_S02
epic_id: E02
title: /spinoff Skill
status: Passed
date_created: 2026-04-29
date_started: 2026-04-29
date_completed: 2026-04-29
tasks: []
---

# Story: /spinoff Skill

As a user mid-conversation, I want to invoke `/spinoff` to formally declare a diverging topic — so that the agent captures it as a structured `/todo` with context gathered so far, and we can consciously continue one thread without losing the other.

## Acceptance Criteria
- [ ] A skill file exists at `skills/spinoff/SKILL.md` and is invocable as `/spinoff`
- [ ] When invoked, `/spinoff` asks the user to confirm or describe the diverging topic
- [ ] The skill collects relevant context already discussed and pre-fills the `/todo` description
- [ ] If Prerequisites are incomplete, the skill offers to invoke `/brainstorm` before finalising the todo
- [ ] After the `/todo` is saved, the agent returns focus to the primary topic
- [ ] `/spinoff` is referenced in `E02_S01` (Subject Divergence Detection) as the recommended invocation path when the agent detects a divergence

## Definition of Done
- [ ] Skill file exists and is invokable as `/spinoff`
- [ ] Flow: detect divergence → `/spinoff` → (optional `/brainstorm`) → save `/todo` → resume primary topic
- [ ] All acceptance criteria pass
- [ ] `E02_S01` updated to reference `/spinoff` in its guardrail flow
