# Execution Plan: Setup wizard & secrets guide implementation

**Task ID:** E22_S02_T01
**Story ID:** E22_S02
**Epic ID:** E22
**Date:** 2026-07-11 (UTC)
**Agent:** developer
**Session ID:** 88d3f412-a3db-4356-aa58-96c6d8860c37

---

## Task Summary
Implement story E22_S02 end-to-end: add the static secrets guide and iOS wizard template assets, build the interactive `setup_wizard.sh` flow that collects target configuration and writes or merges `publish.json`, then add missing-config detection and deploy auto-trigger documentation/logic for the `/publish` skill.

---

## Implementation Approach

1. Align the publish config contract with the E22_S02 story requirements so the schema, example config, and validator accept the required `mobile-ios` target shape.
2. Create the static assets for T01: the secrets guide and the markdown wizard template for `mobile-ios`.
3. Implement `skills/publish/scripts/setup_wizard.sh` to prompt from the template, warn on missing env vars, preview the generated config, merge or create `publish.json`, validate it, and roll back invalid writes.
4. Implement `skills/publish/scripts/check_target_config.sh` to detect missing/incomplete target config and produce descriptive exit-code-4 failures.
5. Update `skills/publish/SKILL.md` so the `setup` and `deploy` sections document the wizard flow and deploy auto-trigger behavior, including `--yes` behavior.
6. Run targeted non-test verification for script syntax and representative config validation paths, then capture the work in commits, summary, tester handoff, and tester invocation.

---

## Files to Change

| File | Planned Change |
|------|----------------|
| `project/board/tasks/E22_S02_T02_INSTRUCTIONS.md` | Document user-managed runtime prerequisites for secrets and Apple identifiers |
| `skills/publish/assets/secrets-guide.md` | Add production-safe secret storage guidance |
| `skills/publish/wizards/mobile-ios.md` | Add markdown wizard template for iOS target questions |
| `skills/publish/scripts/setup_wizard.sh` | Implement interactive setup wizard and config merge flow |
| `skills/publish/scripts/check_target_config.sh` | Implement target completeness checks used by deploy |
| `skills/publish/SKILL.md` | Document setup wizard and deploy auto-trigger behavior |
| `skills/publish/schemas/publish.schema.json` | Align schema with required `mobile-ios` target structure |
| `skills/publish/scripts/validate_config.sh` | Align validation logic with updated target structure |
| `skills/publish/assets/publish.example.json` | Refresh example config to match the updated schema |
| `project/documentation/summaries/E22_S02_T01-summary.md` | Summarize implementation for tester handoff |
| `project/queue/.session_handoff.json` | Write required developer handoff payload |

---

## Dependencies & Risks

- Depends on the S01 scaffold already merged to `main`, but the current schema and example may need alignment to match the story’s required target shape.
- `jq` is required for config merge and validation logic.
- Wizard behavior is interactive by design, so verification must use controlled piped input and syntax checks rather than a full automated test suite.
- Need to avoid storing any literal secret values; only env-var references may be written.

---

## Notes

The story is implemented across T01, T02, and T03 in a single worktree and summary, with commit milestones preserved so the tester can review the progression.
