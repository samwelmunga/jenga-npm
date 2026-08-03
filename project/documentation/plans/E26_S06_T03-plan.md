# Execution Plan: Add npm quality gates to run_gates.sh

**Task ID:** E26_S06_T03
**Story ID:** E26_S06
**Epic ID:** E26
**Date:** 2026-08-01 (UTC)
**Agent:** developer
**Session ID:** dev-E26_S06_T03-2026-08-01T09:22:26Z-retry

---

## Task Summary
Extend `skills/publish/scripts/run_gates.sh` so that when the active publish target has `type: npm`, the pre-deploy quality gates are `npm test`, `npm run build`, and `npm run lint`. Each gate must be skipped with a clear message if its script is not defined in the consumer's `package.json`, and iOS-specific tooling (`xcodebuild`, node_modules-tree lookups) must not run for npm targets. Gate failures continue to exit `2`. The script must pass `shellcheck`.

---

## Implementation Approach

The existing `run_gates.sh` (a) computes a fixed mandatory pre-deploy gate list of `build test`, (b) resolves each gate name to a command via `resolve_default_command`, and (c) uses `find_npm_script_command` + `find_xcodebuild_command` fallbacks. To add the npm path without regressing the iOS path:

1. Introduce a `TARGET_TYPE` global initialized by a new `resolve_target_type` helper that reads `.type` from the resolved target object in `publish.json`. Default to `mobile-ios` when unset to preserve legacy behaviour for existing targets that predate the `type` field.
2. Add `find_npm_script_in_root` — a strict resolver that only looks at `$REPO_ROOT/package.json` (mirroring `npm_pipeline.sh`, which publishes the top-level `package.json`). Returns the canonical `npm test` form for the `test` script and `npm run <name>` for everything else.
3. In `resolve_default_command`, add an early `TARGET_TYPE == "npm"` branch. For `build|test|lint`, use `find_npm_script_in_root`; on miss, print an informational skip note to stderr and return with an empty resolved command (which triggers the existing skip path in `attempt_gate`). For other gate names, return an empty command (no legacy fall-through).
4. In `build_gate_list`, compute the mandatory pre-deploy gate list dynamically: `(test build lint)` for npm targets, `(build test)` for everything else. Loop over the mandatory list to emit gate JSON entries. Generalize the "ignore configurable gate that duplicates a mandatory one" branch to check membership in the mandatory list rather than the hard-coded pair.
5. Call `resolve_target_type` from `main` before `build_gate_list` runs (which reads `TARGET_TYPE`).
6. Run `shellcheck skills/publish/scripts/run_gates.sh` and address any warnings introduced by the diff.
7. Commit in the isolated worktree with `feat(E26_S06_T03): add npm quality gates to run_gates.sh`.
8. Write an execution summary and hand off to the tester.

Skip semantics: when `find_npm_script_in_root` misses, `resolve_default_command` returns `""` via `RESOLVED_GATE_COMMAND`. `attempt_gate` already interprets an empty resolved command as skip (`log_warn "No command resolved..."; return 1`), and `run_gate` maps that to `<gate>:skipped` in the results summary. That satisfies "skipped gracefully with an informational note" — the note is the explicit stderr message from `resolve_default_command`, and the skip is recorded in the results.

Non-goals: no changes to iOS pipeline gates, no changes to `attempt_gate`/`run_gate` control flow, no changes to `find_npm_script_command` (still used for legacy targets), no changes to the retry loop, no changes to `checks[phase]` handling.

---

## Files to Change

| File | Planned Change |
|------|----------------|
| skills/publish/scripts/run_gates.sh | Add `TARGET_TYPE` + `resolve_target_type`, add `find_npm_script_in_root`, branch `resolve_default_command` on `TARGET_TYPE == npm`, generalize the mandatory pre-gate list in `build_gate_list`, invoke `resolve_target_type` in `main`. |

---

## Dependencies & Risks

- Depends on the `type` field being present on npm targets in `publish.json`. The schema work (E26_S03) is complete; a default of `mobile-ios` covers targets missing the field.
- No new external tooling — `jq` and `npm` are already required elsewhere in the publish pipeline.
- Risk: the informational skip note is printed to stderr by `resolve_default_command`, and the follow-up `log_warn "No command resolved..."` from `attempt_gate` is redundant but not incorrect. Acceptable for now; both messages surface the same skip outcome and only the results summary is machine-consumed.
- Risk: consumers may configure a `build` gate via `checks.pre` intending an override with `build_command`. The generalized mandatory-gate loop preserves the existing "warn and ignore duplicate configurable gate" behaviour, so overrides via top-level `build_command`/`test_command`/`lint_command` still apply through `resolve_gate_command`.

---

## Notes

- Prior partial work on this file existed in the main worktree (unstaged); this session reimplements it cleanly in the isolated worktree.
- `find_npm_script_command` is intentionally not reused for npm targets: it walks the entire repo tree for any `package.json`, which is appropriate for legacy fallbacks but not for npm targets that must publish exactly one package.
