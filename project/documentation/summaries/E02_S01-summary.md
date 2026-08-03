# E02_S01 — Subject Divergence Detection: Execution Summary

## What Was Changed and Why

### Problem
The agents had no formal protocol for handling mid-session topic drift. When a user introduced a new idea, unrelated suggestion, or scope-expanding thought while a story was in progress, context from either thread could be silently lost with no structured way to recover it.

### Solution
Added a **Subject Divergence Detection** section to both `AGENT.md` and `agents/scrum-master.md`. The section defines what constitutes a diverging subject, specifies the four-option structured prompt the agent must present, and ensures context gathered so far is always captured in the resulting `/todo` description.

## Files Modified

| File | Change |
|---|---|
| `AGENT.md` | Added `## Subject Divergence Detection` section after the Hooks section |
| `agents/scrum-master.md` | Added `## Subject Divergence Detection` section after Brainstorm Mode |

## Acceptance Criteria — Verification

- [x] `AGENT.md` contains a "Subject Divergence Detection" section that defines diverging subjects, describes the two-choice prompt, and specifies the `/brainstorm` offer for Prerequisites
- [x] `agents/scrum-master.md` contains a matching section with scrum-master-specific tone and trigger guidance
- [x] Option A: Capture diverging topic as `/todo` → agent returns to primary topic (documented in both files)
- [x] Option B: Capture primary topic as `/todo` → agent continues with diverging topic (documented in both files)
- [x] Both options surface relevant context in the `/todo` description (Context Surfacing subsection in both files)
- [x] Edge cases documented: user declines both options; user wants to pursue both in parallel
- [x] Two-option flow is clearly described and consistent across both files
