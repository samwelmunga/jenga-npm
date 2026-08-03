---
id: E02_S01
epic_id: E02
title: Subject Divergence Detection
status: Passed
date_created: 2026-04-29
date_started: 2026-04-29
date_completed: 2026-04-29
tasks: []
---

# Story: Subject Divergence Detection

As a user working through a focused session, I want the agent to notice when I'm drifting into a new subject and offer me a structured way to capture either thread as a `/todo` — so that no context is lost and I can consciously choose which topic to continue.

## Acceptance Criteria
- [ ] `AGENT.md` contains a "Subject Divergence Detection" section that:
  - Defines what counts as a diverging subject (new feature, unrelated suggestion, scope-expanding idea)
  - Describes the two-choice prompt the agent must present the user
  - Specifies that `/brainstorm` should be offered to fill in missing Prerequisites before the `/todo` is created
- [ ] `agents/scrum-master.md` contains a matching section with scrum-master-specific tone and trigger guidance
- [ ] Option A: User creates a `/todo` for the **diverging** topic (with Prerequisites if needed) and the agent returns to the primary topic
- [ ] Option B: User creates a `/todo` for the **primary** topic (with Prerequisites if needed) and the agent continues with the diverging topic
- [ ] Both options surface relevant context gathered so far in the `/todo` description

## Definition of Done
- [ ] Both files updated with the new section
- [ ] The two-option flow is clearly described and consistent across both files
- [ ] Edge cases documented: user declines both options, user wants to do both in parallel

## Recommended Invocation

When a diverging subject is detected and the user chooses to capture it, invoke `/spinoff`. The `/spinoff` skill handles context collection, optional `/brainstorm`, todo creation, and resuming the primary thread.
