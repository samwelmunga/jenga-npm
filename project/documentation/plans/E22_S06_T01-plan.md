# Execution Plan: Full deploy orchestration & ownership matrix

**Task ID:** E22_S06_T01, E22_S06_T02, E22_S06_T03
**Story ID:** E22_S06
**Epic ID:** E22
**Date:** 2026-07-11 (UTC)
**Agent:** developer
**Session ID:** 88d3f412-a3db-4356-aa58-96c6d8860c37

---

## Task Summary

Implement the complete `/publish deploy` orchestration flow for iOS v1 by wiring the existing validation, gate, release-note, semver, adapter, and ledger helpers into a single executable `publish_deploy.sh`. Finish the story by adding dry-run and non-interactive behavior, surfacing adapter manual steps, documenting agent ownership boundaries, and updating the skill entrypoint to reflect the final 11-step deploy flow.

---

## Implementation Approach

1. Add `skills/publish/scripts/publish_deploy.sh` as the top-level deploy orchestrator.
2. Reuse existing helper scripts for config validation, target completeness checks, env validation, gates, release notes, semver suggestion, adapter execution, and ledger writes.
3. Implement interactive and non-interactive target resolution, config auto-healing via setup wizard, release-note review, semver confirmation, and final deploy confirmation.
4. Extend post-deploy handling to support partial-success ledger writes when post gates fail and dry-run ledger writes without real git tags.
5. Parse and print adapter manual steps from the adapter template, and update the adapter doc if needed so the section is explicit and machine-readable.
6. Add the agent ownership matrix document and update `SKILL.md` plus mirrored copies to reflect the final flow, implementation scripts, roles, and scope metadata.
7. Commit in milestones after deploy orchestration and documentation wiring, then write the execution summary and hand off to the tester.

---

## Files to Change

| File | Planned Change |
|------|----------------|
| `project/documentation/plans/E22_S06_T01-plan.md` | Add combined execution plan for T01–T03 |
| `skills/publish/scripts/publish_deploy.sh` | Add the 11-step deploy orchestrator |
| `skills/publish/scripts/write_ledger_entry.sh` | Add dry-run-safe ledger/tag behavior needed by deploy orchestration |
| `skills/publish/adapters/mobile-ios.md` | Add explicit post-deploy manual-steps section for script parsing |
| `skills/publish/SKILL.md` | Document the full deploy flow, implementation scripts, and agent roles |
| `.agents/skills/publish/SKILL.md` | Mirror the final skill documentation |
| `.claude/skills/publish/SKILL.md` | Mirror the final skill documentation |
| `skills/publish/assets/ownership-matrix.md` | Add agent ownership matrix and trust-boundary note |
| `project/documentation/summaries/E22_S06_T01-summary.md` | Add combined implementation summary for tester handoff |
| `project/queue/.session_handoff.json` | Write required developer handoff payload at session end |

---

## Dependencies & Risks

- The deploy script must tolerate both interactive and non-interactive contexts without hanging on prompts.
- Existing publish helpers mix references to `publish.json` and `project/configs/publish.json`; orchestration must resolve a sensible default while preserving explicit `--config` overrides.
- Dry-run mode must remain traceable in the ledger while never creating a real git tag or running live adapter commands.
- Board-summary and manual-steps parsing must be best-effort so missing board data or future adapter-doc changes do not break deploys.

---

## Notes

This story intentionally covers all three E22_S06 tasks in one pass, but the execution summary and tester handoff will still reference T01–T03 coverage individually.
