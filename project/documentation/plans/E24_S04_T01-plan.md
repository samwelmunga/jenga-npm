# Execution Plan: document synthesis and regeneration

**Task IDs:** E24_S04_T01, E24_S04_T02, E24_S04_T03, E24_S04_T04  
**Story ID:** E24_S04  
**Epic ID:** E24  
**Date:** 2026-07-23  
**Agent:** developer  
**Session ID:** 37e3defc-b60a-4fa2-b78d-b636a7d25b8a

---

## Task Summary

Extend `/doc` from target resolution into a full regeneration skill that reads any existing target file, folds forward valid maintainer intent into a synthesis context object, and rewrites complete documentation files for README, API, CLI, contributing, and changelog targets.

## Implementation Approach

1. Preserve the existing target-resolution contract from E24_S02 and add a stable synthesis-context contract that matches the in-flight E24_S03 work.
2. Implement full-file ownership rules: read the existing target first, extract `existing_intent`, regenerate the whole file, and replace the file in a single write.
3. Add README generation requirements for Description and Getting Started using only synthesis-context evidence and manifest-derived setup details.
4. Add conditional Examples guidance driven by explicit project-type inference rules; omit the section when evidence is insufficient.
5. Add target-specific generation structures for `docs/API.md`, `docs/CLI.md`, `docs/CONTRIBUTING.md`, and `CHANGELOG.md` using the path-objective rule table as the controlling contract.
6. Record the implementation in a summary file, prepare the required tester handoff payload, and commit the work in milestones.

## Files to Change

| File | Planned Change |
|---|---|
| `project/logs/events.json` | Append the incoming sender object for this developer session in the worktree branch. |
| `project/documentation/plans/E24_S04_T01-plan.md` | Capture the execution plan for the story implementation. |
| `skills/doc/SKILL.md` | Extend `/doc` with synthesis, regeneration, README, examples, and non-README generation rules. |
| `project/documentation/summaries/E24_S04_T01-summary.md` | Summarise completed work and acceptance-criteria coverage. |
| `project/queue/.session_handoff.json` | Write the final developer handoff payload with branch commit SHAs. |

## Dependencies & Risks

- E24_S03 is landing in parallel, so this work must consume a synthesis-context object by field contract rather than by implementation details.
- Examples must be grounded in evidence; the skill must prefer omission over guessing when project type or example material is ambiguous.
- `CHANGELOG.md` generation must derive from git history without inventing releases, tags, or dates.

## Notes

The canonical edits remain in root directories inside this worktree checkout (`skills/`, `project/documentation/`, `project/queue/`). No generated `.agents/` or `.claude/` mirrors are treated as sources of truth.
