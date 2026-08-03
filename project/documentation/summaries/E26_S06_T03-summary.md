# Execution Summary: Add npm quality gates to run_gates.sh

**Task ID:** E26_S06_T03
**Story ID:** E26_S06
**Epic ID:** E26
**Date Completed:** 2026-08-01 (UTC)
**Agent:** developer
**Session ID:** dev-E26_S06_T03-2026-08-01T09:22:26Z-retry

---

## What Was Implemented

Extended `skills/publish/scripts/run_gates.sh` so it emits the correct pre-deploy quality gates for publish targets whose `type` is `npm`, without changing the behaviour of `mobile-ios` targets:

- Reads `.type` off the resolved target in `publish.json` via a new `resolve_target_type` helper (defaulting to `mobile-ios` for legacy targets).
- For `type: npm`, the mandatory pre-deploy gate list is `test`, `build`, `lint`. Each is resolved strictly against `$REPO_ROOT/package.json` via a new `find_npm_script_in_root` helper (returns `npm test` for `test` and `npm run <name>` for the others).
- When a script is absent from `package.json`, an explicit informational note is printed to stderr (`→ npm gate <name> skipped: no <name> script defined in package.json`) and the gate is reported as `<gate>:skipped` in the results summary. No iOS fallbacks are consulted.
- Failing gates continue to exit `2` and are appended to `project/logs/publish-history.json` — the failure/retry path is untouched.
- Legacy `mobile-ios` behaviour is preserved (mandatory gates `build` + `test`, `find_npm_script_command` and `find_xcodebuild_command` fallbacks).

---

## Files Changed

| File | Summary of Changes |
|------|--------------------|
| skills/publish/scripts/run_gates.sh | Added `TARGET_TYPE` global + `resolve_target_type`; added `find_npm_script_in_root`; added an `npm` early branch in `resolve_default_command` (build/test/lint only, no iOS fall-through); generalised `build_gate_list` to compute the mandatory pre-gate list dynamically (`test build lint` for npm, `build test` otherwise); invoke `resolve_target_type` from `main`. Net +74 / -5 lines. |
| project/documentation/plans/E26_S06_T03-plan.md | New execution plan (required by workflow). |
| project/documentation/summaries/E26_S06_T03-summary.md | This file. |

---

## Commits

| SHA | Message |
|-----|---------|
| ef70997 | feat(E26_S06_T03): add npm quality gates to run_gates.sh |

---

## Acceptance Criteria Coverage

| Criterion | Status | Notes |
|-----------|--------|-------|
| Runs `npm test`, `npm run build`, `npm run lint` for `type: npm` targets, conditionally on presence | Met | Smoke-tested end-to-end with a temp git repo + `package.json` — all three gates executed against the top-level `package.json`. |
| Each npm gate skipped with a clear message when the script is not defined in `package.json` | Met | `resolve_default_command` prints `→ npm gate <name> skipped: no <name> script defined in package.json` to stderr; the results summary shows `<gate>:skipped`. Overall run still succeeds (exit 0) when only the missing gate is skipped. |
| iOS gates (`xcodebuild` etc.) do not run for npm targets | Met | Verified with a fake `.xcodeproj` present in the test dir — the npm branch of `resolve_default_command` returns before `find_xcodebuild_command` can be reached. Command executed was `npm run build`, not `xcodebuild build`. |
| Script passes `shellcheck` | Met | `shellcheck skills/publish/scripts/run_gates.sh` exits 0. `bash -n` also clean. |
| Gate failures exit with code 2 | Met | Smoke-tested with a `build` script that exits 3 — `run_gates.sh` exited with code 2 as expected. |

---

## Edge Cases & Known Concerns

- **cwd sensitivity of `bash -lc "npm test"`:** `run_command_capture` runs each gate command via `bash -lc "$command"` with no `cd`. That means gates execute in the caller's process cwd, not necessarily `$REPO_ROOT`. This is a pre-existing behaviour of the script (unchanged by this task) — it just needs to be flagged for the tester: the caller (`publish_deploy.sh`) is expected to invoke `run_gates.sh` with cwd already set to the project root.
- **Redundant skip message:** when `find_npm_script_in_root` misses, both a specific stderr note (from `resolve_default_command`) and the generic `⚠ No command resolved for gate '<name>'; skipping.` warning (from `attempt_gate`) are printed. Both fire the same code path and result in `<gate>:skipped` in the summary; the double message was accepted to avoid touching `attempt_gate`'s control flow.
- **Legacy targets missing `type`:** `resolve_target_type` defaults to `mobile-ios`, so any existing `publish.json` written before the E26 schema changes continues to behave exactly as before.
- **Configurable duplicate gates:** if a user lists `build`, `test`, or `lint` in `checks.pre` for an npm target, the "ignore configurable duplicate" warning still fires (list membership check was generalised to iterate the mandatory array). Overrides via top-level `build_command`/`test_command`/`lint_command` are unaffected — they still apply through `resolve_gate_command`.

---

## Notes for Tester

To verify locally without a real npm project, create a temp dir with a `package.json` (scripts as desired) and a minimal `publish.json`:
```json
{"targets":{"npm-registry":{"type":"npm","package_name":"foo","access":"public"}}}
```
Then run `./run_gates.sh pre npm-registry ./publish.json --non-interactive` from that dir. Suggested checks:
1. All three scripts defined → all gates pass, exit 0.
2. Only `test` defined → `build` and `lint` print the skip note and appear as `:skipped`, exit 0.
3. `test` exits non-zero → gate failure block printed, exit 2, `project/logs/publish-history.json` gains a `gate_failure` entry (or the caller's equivalent).
4. Same setup but with `"type":"mobile-ios"` (and no npm scripts, no xcodeproj) → mandatory gates become `build test`, `lint` is not added, `build`/`test` skip via `log_warn "No command resolved..."`. Legacy behaviour intact.
5. `shellcheck skills/publish/scripts/run_gates.sh` → exit 0.

Do not run `npm publish` or exercise `publish_deploy.sh` end-to-end — that's outside the scope of this task (covered by later stories).
