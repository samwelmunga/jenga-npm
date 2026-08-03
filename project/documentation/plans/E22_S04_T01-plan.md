# Execution Plan: iOS App Store Adapter v1 (E22_S04 — T01, T02, T03)

**Task ID:** E22_S04_T01, E22_S04_T02, E22_S04_T03
**Story ID:** E22_S04
**Epic ID:** E22
**Date:** 2026-07-11 (UTC)
**Agent:** developer
**Session ID:** 88d3f412-a3db-4356-aa58-96c6d8860c37

---

## Task Summary

Implement the first `/publish` deployment adapter for iOS App Store delivery. The work covers the adapter prompt template, env-var validation, the `xcodebuild` archive/export pipeline, upload handling through `xcrun`, publish history state-machine logging, dry-run support, and the required Apple credential setup instructions for the user.

---

## Implementation Approach

1. **T01 — Adapter scaffold and credential guidance**
   - Create `project/board/tasks/E22_S04_T01_INSTRUCTIONS.md` documenting the Apple Developer and App Store Connect setup the user must complete.
   - Add `skills/publish/adapters/mobile-ios.md` to document the adapter contract, phase ordering, state machine, required env vars, and dry-run behavior.
   - Implement `skills/publish/scripts/validate_ios_env.sh` so it reads required env-var references from `publish.json`, verifies the environment, and exits `4` with a clear missing-var message when validation fails.

2. **T02 — Build, sign, and export pipeline**
   - Add `skills/publish/assets/ExportOptions.plist.template` for runtime export-plist generation.
   - Implement `skills/publish/scripts/ios_pipeline.sh` with direct command-array execution only for allowlisted `xcodebuild` / `xcrun` calls.
   - Read build/export inputs from `publish.json`, generate the export plist inside a repo-local scratch directory, and clean it up after use.
   - Update state transitions and step history around build, sign, and export, with exit code `3` on command failures.

3. **T03 — Upload, history ledger, and manual follow-up**
   - Extend the pipeline with upload support that prefers `xcrun notarytool` and falls back to `xcrun altool` with a warning.
   - Initialize `project/logs/publish-history.json` to `[]` when missing using board-style lock handling.
   - Persist adapter state-machine entries and step logs with lock-protected writes so partial failures are recorded safely.
   - Print the required post-upload manual steps block in both interactive and non-interactive runs.

4. **Config and documentation alignment**
   - Update the publish example config, schema, and validation script so the iOS adapter contract is represented accurately.
   - Refresh `/publish` docs where needed so the adapter and dry-run flow are discoverable.

5. **Handoff**
   - Commit at milestones after scaffolding/config alignment and after the pipeline/history implementation.
   - Write `project/documentation/summaries/E22_S04_T01-summary.md` with commit SHAs, AC coverage, and tester notes.
   - Prepare the tester sender object and required session handoff.

---

## Files to Change

| File | Planned Change |
|------|----------------|
| `project/board/tasks/E22_S04_T01_INSTRUCTIONS.md` | User setup instructions for Apple credentials and signing prerequisites |
| `project/documentation/plans/E22_S04_T01-plan.md` | Combined plan for T01–T03 |
| `skills/publish/SKILL.md` | Mention adapter execution surface and iOS deploy script |
| `skills/publish/assets/ci-contract.md` | Align dry-run and env-validation contract with iOS adapter |
| `skills/publish/assets/publish.example.json` | Add representative mobile-ios target config for archive/export/upload |
| `skills/publish/assets/ExportOptions.plist.template` | Template for runtime export options generation |
| `skills/publish/schemas/publish.schema.json` | Model iOS adapter config and pre/post gate shape |
| `skills/publish/scripts/validate_config.sh` | Validate the updated publish config shape |
| `skills/publish/adapters/mobile-ios.md` | New adapter prompt template/contract |
| `skills/publish/scripts/validate_ios_env.sh` | New env-var validation script |
| `skills/publish/scripts/ios_pipeline.sh` | New iOS build/sign/export/upload pipeline |
| `project/logs/publish-history.json` | Initialize canonical publish ledger to `[]` if absent |
| `project/documentation/summaries/E22_S04_T01-summary.md` | Combined implementation summary for T01–T03 |
| `project/queue/.session_handoff.json` | Developer handoff for tester routing |

---

## Dependencies & Risks

- The adapter depends on `jq` for config parsing and assumes a local Apple toolchain provides `xcodebuild` and `xcrun`.
- Live Apple uploads must not be attempted during verification; dry-run mode is the safe path for testing structure.
- Export-plist generation cannot use `/tmp`; scratch files must stay inside the repository and be cleaned up reliably.
- The existing publish config/schema were scaffold-level only and need careful evolution so previously added `/publish` work remains coherent.
- `notarytool` is preferred by the task even though App Store uploads commonly use `altool`; the implementation should clearly surface which tool was selected.

---

## Notes

- This story is iOS-only; Android remains out of scope.
- The adapter trust boundary is explicit: no arbitrary command execution, no shell-eval of config, and only direct `xcodebuild` / `xcrun` invocations for external publish actions.
- History logging should make dry-runs appear structurally successful so the full state machine can be reviewed before real credentials are used.
