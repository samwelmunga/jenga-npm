---
id: E02
title: Agent Conversation Guardrails
status: Done
date_created: 2026-04-29
date_started:
date_completed: 2026-05-10
stories:
  - E02_S01
  - E02_S02
---

# Epic: Agent Conversation Guardrails

## Purpose
Equip the Jenga agent system with conversation-awareness guardrails that detect when a user is diverging from the primary topic of a session. When divergence is detected, the agent surfaces a structured choice: capture the diverging topic as a `/todo` (and continue the primary discussion) or capture the primary topic as a `/todo` (and pivot to the diverging subject). Both paths preserve context and continuity without losing either thread.

## Definition of Done
- [ ] `AGENT.md` includes a "Subject Divergence Detection" section describing the detection heuristic and the two-option response protocol
- [ ] `agents/scrum-master.md` includes a matching section with scrum-master-specific guidance on when to trigger the guardrail and how to phrase the choice to the user
- [ ] The guardrail uses `/brainstorm` to clarify Prerequisites before a `/todo` is finalised for either path
- [ ] Behaviour is documented with examples in both files
- [ ] A `/spinoff` skill exists that formalises the divergence-capture flow: collects context, optionally runs `/brainstorm` for Prerequisites, saves a `/todo`, and returns focus to the primary topic
