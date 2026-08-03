# Execution Plan: Add npm dispatch to publish_deploy.sh

**Task ID:** E26_S06_T02
**Story ID:** E26_S06
**Epic ID:** E26
**Date:** 2026-08-01 (UTC)
**Agent:** developer
**Session ID:** dev-E26_S06_T02

---

## Task Summary
Extend `skills/publish/scripts/publish_deploy.sh` so that when the active target's `type` is `npm`, the adapter dispatch step runs `skills/publish/scripts/npm_pipeline.sh` instead of failing with "unsupported target type". The existing `mobile-ios` dispatch to `ios_pipeline.sh` must be preserved. The `--dry-run` flag (and `--non-interactive` for `--yes` mode) must be forwarded to `npm_pipeline.sh`.

---

## Implementation Approach

1. Add an `NPM_PIPELINE_SCRIPT="$SCRIPT_DIR/npm_pipeline.sh"` constant next to the existing `IOS_PIPELINE_SCRIPT` constant, plus a matching `VALIDATE_NPM_ENV_SCRIPT="$SCRIPT_DIR/validate_npm_env.sh"` so the env-validation step can route npm the same way iOS does.
2. Update `validate_target_env()` to add an `npm)` branch that invokes `validate_npm_env.sh <config> <target>`, mirroring the shape of the existing `mobile-ios)` branch. Without this, `publish_deploy.sh` bails on unsupported target type before ever reaching `run_adapter_pipeline`, so the dispatch acceptance criterion is not actually reachable.
3. Update `run_adapter_pipeline()` to add an `npm)` branch that builds `cmd=(bash "$NPM_PIPELINE_SCRIPT" "$TARGET_NAME" "$CONFIG_PATH")`. The existing post-case block already appends `--dry-run` and `--non-interactive` when the corresponding flags are set on `publish_deploy.sh`, and `npm_pipeline.sh` already accepts both flags — so no new flag-plumbing code is needed.
4. Leave the wildcard `*)` "Unsupported target type" fallback intact for both functions.
5. Run `shellcheck` on the modified script and fix any warnings introduced by the change (existing warnings that are not caused by this diff are out of scope but should be noted).
6. Commit inside the assigned worktree with `feat(E26_S06_T02): dispatch npm targets to npm_pipeline.sh`.

Do NOT modify: `npm_pipeline.sh`, `run_gates.sh`, `validate_config.sh`, `setup_wizard.sh`, or `validate_npm_env.sh`.

---

## Files to Change

| File | Planned Change |
|------|----------------|
| `skills/publish/scripts/publish_deploy.sh` | Add `NPM_PIPELINE_SCRIPT` and `VALIDATE_NPM_ENV_SCRIPT` constants; add `npm)` branch in `validate_target_env`; add `npm)` branch in `run_adapter_pipeline`. |
| `project/documentation/summaries/E26_S06_T02-summary.md` | Write execution summary (post-implementation, pre-tester). |

---

## Dependencies & Risks

- Depends on `skills/publish/scripts/npm_pipeline.sh` (created in E26_S05_T01) — verified present and already accepts `<target> <publish_json_path>` positionals plus `--dry-run` and `--non-interactive` flags.
- Depends on `skills/publish/scripts/validate_npm_env.sh` — verified present.
- Risk: existing `shellcheck` warnings unrelated to this diff may surface. Only warnings caused by this diff will be treated as blockers.
- Risk: `run_target_completeness_check` calls `setup_wizard.sh --type "$TARGET_TYPE"`; the npm branch of `setup_wizard.sh` is covered by task T01 and is outside this task's scope.

---

## Notes

- The dispatch surface is intentionally minimal: three small hunks in one file. The bulk of npm-specific behavior lives inside `npm_pipeline.sh` and `validate_npm_env.sh`, both of which already exist.
- Exit-code semantics are preserved: `EXIT_CONFIG_INVALID (4)` still surfaces from adapter env validation and adapter execution; other non-zero adapter exits map to `EXIT_ADAPTER_FAILURE (3)`. `npm_pipeline.sh` uses `2` for pre-publish gate failures and `3` for publish errors, both of which fall through to `EXIT_ADAPTER_FAILURE` via the existing default branch — acceptable for this task.
