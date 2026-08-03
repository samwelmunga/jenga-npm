# Execution Plan: /doc skill contract and target resolution

**Task ID:** E24_S02_T01, E24_S02_T02, E24_S02_T03, E24_S02_T04  
**Story ID:** E24_S02  
**Epic ID:** E24  
**Date:** 2026-07-23 (UTC)  
**Agent:** developer  
**Session ID:** 37e3defc-b60a-4fa2-b78d-b636a7d25b8a

---

## Task Summary

Scaffold the new `/doc` skill so it can be invoked with an optional target path, default to `README.md` when no path is supplied, resolve known documentation targets through a deterministic path-to-objective table, and stop on unknown targets until the user clarifies the documentation objective.

---

## Implementation Approach

1. Review existing skill frontmatter and instruction conventions in `skills/` and align the new `/doc` skill structure to those patterns.
2. Create `skills/doc/SKILL.md` with the required frontmatter, a clear `/doc [target-path]` contract, and explicit default-target behavior for no-argument invocations.
3. Add an extensible `skills/doc/assets/path-objectives.yaml` asset that maps known file paths to documentation objectives and related section expectations.
4. Wire the skill instructions to load the rule table, surface the resolved target path before later steps, and apply the mapped objective for known targets.
5. Add an ambiguity gate that asks the user `What should <path> document? Please describe the objective.` for unknown targets and prevents guessing.
6. Write the required execution summary and session handoff after implementation, then commit the work in meaningful milestones.

---

## Files to Change

| File | Planned Change |
|------|----------------|
| `project/logs/events.json` | Append the incoming sender object for this developer session. |
| `project/documentation/plans/E24_S02_T01-plan.md` | Record the execution plan for all four story tasks. |
| `skills/doc/SKILL.md` | Create the `/doc` skill scaffold, argument parsing contract, known-target resolution flow, and ambiguity gate. |
| `skills/doc/assets/path-objectives.yaml` | Define the extensible path-to-objective rule table used by the skill. |
| `project/documentation/summaries/E24_S02_T01-summary.md` | Summarise implementation and acceptance-criteria coverage for tester handoff. |
| `project/queue/.session_handoff.json` | Write the final developer handoff payload with commit references. |

---

## Dependencies & Risks

- The current story only covers target resolution and contract scaffolding, so the skill must avoid pretending that unknown objectives can be inferred automatically.
- Path matching should stay deterministic and easy to extend without embedding brittle logic directly in the skill body.
- The skill should follow existing frontmatter conventions while still keeping the argument-parsing behavior explicit for future `/doc` stories.

---

## Notes

The canonical source files will be edited only in root directories inside this worktree (`skills/`, `project/documentation/`, `project/queue/`). No generated `.agents/` or `.claude/` mirrors will be treated as source of truth in this story.
