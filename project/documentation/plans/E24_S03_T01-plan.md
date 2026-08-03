# Execution Plan: Evidence collection and source precedence

**Task ID:** E24_S03_T01, E24_S03_T02, E24_S03_T03  
**Story ID:** E24_S03  
**Epic ID:** E24  
**Date:** 2026-07-23 (UTC)  
**Agent:** developer  
**Session ID:** 37e3defc-b60a-4fa2-b78d-b636a7d25b8a

---

## Task Summary

Extend `skills/doc/SKILL.md` so `/doc` gathers structured evidence from user input, scrum board files, the codebase, and recent git history; resolves conflicts with a strict precedence chain; and normalizes the result into a reusable synthesis context object for downstream document generation.

---

## Implementation Approach

1. Review the current `/doc` contract and keep the existing target-resolution flow intact as the entry point into evidence gathering.
2. Add an explicit evidence-collection phase that defines four source blocks (`user_prompt`, `scrum_board`, `codebase`, `git_history`) and requires an empty structured block instead of failure when a source is unavailable.
3. Specify deterministic collection guidance for each source, including board files to scan, codebase manifests and key files to inspect, and recent git commits to filter for target relevance.
4. Define a source precedence order of `user prompt > scrum board > codebase > git history` and document how conflicts are resolved and recorded.
5. Define the synthesis context object schema with the required normalized fields, list-valued fields defaulting to `[]`, and scalar fields explicitly set to `null` when unresolved.
6. Thread the synthesis context into downstream `/doc` generation instructions so later stories can consume it without re-reading sources.
7. Record an execution summary, session handoff, and milestone commits after the skill update is complete.

---

## Files to Change

| File | Planned Change |
|------|----------------|
| `project/logs/events.json` | Append the incoming sender object for this developer session. |
| `project/documentation/plans/E24_S03_T01-plan.md` | Record the execution plan for the full E24_S03 story scope. |
| `skills/doc/SKILL.md` | Add evidence collection, source precedence, and synthesis context instructions. |
| `project/documentation/summaries/E24_S03_T01-summary.md` | Summarize the implementation and acceptance-criteria coverage. |
| `project/queue/.session_handoff.json` | Write the final developer handoff with worktree and commit references. |

---

## Dependencies & Risks

- The skill is instruction-driven, so the evidence blocks and precedence rules need to be concrete enough to produce deterministic behavior without introducing unsupported tooling assumptions.
- Board `docs` annotations may be sparse in the current repository; the skill must therefore support exact-match annotations first and fall back to textual relevance checks without treating missing annotations as an error.
- Git history relevance should stay bounded to the last 20 commits and the target subject to avoid broad historical drift.

---

## Notes

Only canonical source files inside the worktree will be edited. No generated `.agents/` or `.claude/` artifact copies will be treated as source of truth for this story.
