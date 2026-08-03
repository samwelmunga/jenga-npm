# Execution Plan: Quality Gate System (E22_S03 — T01, T02, T03)

**Task ID:** E22_S03_T01, E22_S03_T02, E22_S03_T03
**Story ID:** E22_S03
**Epic ID:** E22
**Date:** 2026-07-11 (UTC)
**Agent:** developer
**Session ID:** 88d3f412-a3db-4356-aa58-96c6d8860c37

---

## Task Summary

Implement the `/publish` quality gate runner at `skills/publish/scripts/run_gates.sh`. The work covers the executable scaffold and invocation contract, mandatory global pre-deploy gates (`build`, `test`), and configurable per-target gates plus failure UX, history logging, and non-interactive behavior.

---

## Implementation Approach

1. **T01 — Scaffold the gate runner**
   - Create `skills/publish/scripts/run_gates.sh` as an executable bash entrypoint.
   - Implement argument parsing for `<phase> <target> <publish_json_path> [--non-interactive]`.
   - Document the invocation and exit-code contract in the header comment.
   - Build the script structure around gate discovery, per-gate dispatch, result tracking, and final exit status.

2. **T02 — Add mandatory global pre-deploy gates**
   - Prepend `build` and `test` to every `pre` run regardless of config.
   - Resolve commands from `publish.json` first, then conventional defaults discovered from the repo (npm scripts / xcodebuild).
   - Stop immediately on failure, surface full command output, and exit 2.
   - Document the mandatory-gates policy in `skills/publish/assets/ci-contract.md`.

3. **T03 — Add configurable gates, retry/abort UX, and history logging**
   - Read target gates from `targets[].checks.pre` / `targets[].checks.post`, supporting both object-keyed and array-shaped targets.
   - Implement `lint`, `type-check`, `custom-script`, `smoke-test`, and `ping` handlers.
   - Validate `custom-script` paths against `^[./a-zA-Z0-9_-]+$` before execution.
   - On failure, print a formatted failure block, offer retry/abort in interactive mode with a 3-retry cap, and abort immediately in non-interactive mode.
   - Append gate failures to `project/logs/publish-history.json`, creating it as `[]` when absent.

4. **Documentation and handoff**
   - Write an execution summary covering all three tasks.
   - Commit at meaningful milestones.
   - Prepare the tester handoff with commit SHAs and the worktree path.

---

## Files to Change

| File | Planned Change |
|------|----------------|
| `project/documentation/plans/E22_S03_T01-plan.md` | Record the combined implementation plan for T01–T03 |
| `skills/publish/scripts/run_gates.sh` | New executable gate runner with contract, gate dispatch, retries, and logging |
| `skills/publish/assets/ci-contract.md` | Document mandatory global gate policy and failure behavior |
| `project/documentation/summaries/E22_S03_T01-summary.md` | Record implemented work, changed files, and tester notes |
| `project/queue/.session_handoff.json` | Prepare required developer handoff for tester routing |

---

## Dependencies & Risks

- The runner depends on `jq` for JSON parsing and `curl` for the `ping` gate.
- The repository does not yet contain an existing `/publish` skill scaffold on this branch, so this story creates the gate-runner area from scratch.
- `publish.json` shape is only partially defined in the design docs; the runner should tolerate both object-keyed and array-shaped `targets` to reduce coupling.
- Conventional command detection may not find a runnable default for every project layout; when missing, the runner must warn and skip rather than fail.
- Interactive retry prompts must not block automation; non-interactive mode should be forced when stdin is not a TTY.

---

## Notes

- This story is intentionally limited to gate execution. It does not add deploy orchestration, adapter execution, or real deployment flows.
- The root `package.json` does not expose build/test scripts, so default command detection should search nested package manifests as part of the implementation.
