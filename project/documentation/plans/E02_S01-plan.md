# E02_S01 — Subject Divergence Detection: Execution Plan

## Problem Statement
Agents currently have no formal behaviour for when a user introduces a new or unrelated topic mid-session. Without guardrails, context from either thread is silently lost and the conversation drifts. This story adds a Subject Divergence Detection protocol so the agent notices the shift, surfaces both threads as structured `/todo` items, and lets the user decide which to continue.

## Files to Change

| File | Change |
|---|---|
| `AGENT.md` | Add `## Subject Divergence Detection` section after the Hooks section |
| `agents/scrum-master.md` | Add `## Subject Divergence Detection` section after Brainstorm Mode |

## Approach

### AGENT.md
Insert a new top-level section that:
1. Defines what constitutes a diverging subject.
2. Specifies the two-choice prompt (Option A / Option B) and its exact structure, following the existing "Interaction Pattern" format.
3. Requires both options to embed context gathered so far in the `/todo` description.
4. Offers `/brainstorm` to fill Prerequisites before creating a `/todo`.
5. Documents edge cases: user declines both, user wants parallel pursuit.

### agents/scrum-master.md
Insert a matching section with scrum-master-specific tone that:
1. Names the divergence trigger (topic clearly shifts away from current story/epic).
2. Guides the scrum-master on phrasing the two-choice prompt.
3. Reinforces context capture in the `/todo` description.
4. Repeats the `/brainstorm` offer and edge case handling consistently with AGENT.md.
