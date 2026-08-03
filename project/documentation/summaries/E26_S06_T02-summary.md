# Execution Summary: Add npm dispatch to publish_deploy.sh

**Task ID:** E26_S06_T02
**Story ID:** E26_S06
**Epic ID:** E26
**Date Completed:** 2026-08-01 (UTC)
**Agent:** developer
**Session ID:** dev-E26_S06_T02

---

## What Was Implemented

`skills/publish/scripts/publish_deploy.sh` now dispatches to the npm publish pipeline when the active target's `type` is `npm`. The existing `mobile-ios` dispatch path is unchanged. Two hunks were added:

1. In `validate_target_env`: an `npm)` branch that invokes `skills/publish/scripts/validate_npm_env.sh <config> <target>`. Without this, npm targets bailed out with "Unsupported target type" before the adapter step could ever run.
2. In `run_adapter_pipeline`: an `npm)` branch that invokes `skills/publish/scripts/npm_pipeline.sh <target> <config>`. The `--dry-run` and `--non-interactive` flags are already appended by the shared post-case block, and `npm_pipeline.sh` (created in E26_S05_T01) already accepts both.

Two new file-path constants (`VALIDATE_NPM_ENV_SCRIPT`, `NPM_PIPELINE_SCRIPT`) were added next to their `_IOS_` counterparts. No other files were touched.

---

## Files Changed

| File | Summary of Changes |
|------|--------------------|
| `skills/publish/scripts/publish_deploy.sh` | Added `VALIDATE_NPM_ENV_SCRIPT` and `NPM_PIPELINE_SCRIPT` constants; added `npm)` case in `validate_target_env`; added `npm)` case in `run_adapter_pipeline`. |

---

## Commits

| SHA | Message |
|-----|---------|
| `62696f4` | `feat(E26_S06_T02): dispatch npm targets to npm_pipeline.sh` |

---

## Acceptance Criteria Coverage

| Criterion | Status | Notes |
|-----------|--------|-------|
| `publish_deploy.sh` dispatches to `npm_pipeline.sh` when `target.type == "npm"` | Met | New `npm)` branch in `run_adapter_pipeline`. |
| Continues to dispatch to `ios_pipeline.sh` for `mobile-ios` (no regression) | Met | Existing `mobile-ios)` branch untouched. |
| `--dry-run` flag is forwarded to `npm_pipeline.sh` when present | Met | Existing `(( DRY_RUN )) && cmd+=(--dry-run)` line runs after the case block for both branches. `npm_pipeline.sh` accepts `--dry-run`. |
| Script passes `shellcheck` after modification | Met (no new warnings) | `shellcheck` reports two pre-existing warnings (SC1091 for the `source` line and SC2034 for `VALIDATE_CONFIG_SCRIPT`); both are present on the pre-change file too. The new constants I added are actually used, so no new SC2034 warnings were introduced. |

---

## Edge Cases & Known Concerns

- `resolve_target_type` still defaults to `mobile-ios` when a target has no `type` field. That is pre-existing behavior and outside this task's scope, but it means bare, untyped targets keep going through the iOS path — no regression, but worth noting for T04 (validate_config).
- `npm_pipeline.sh` exits with code `2` for pre-publish failures and `3` for publish errors. The dispatch logic here only maps `EXIT_CONFIG_INVALID (4)` specifically; everything else (including `2` and `3` from npm) falls into `EXIT_ADAPTER_FAILURE (3)`. This matches how iOS pipeline failures are surfaced today.
- I intentionally did NOT touch `npm_pipeline.sh`, `run_gates.sh`, `validate_config.sh`, or `setup_wizard.sh` — those are T01, T03, T04 concerns per the story.

---

## Notes for Tester

Suggested verification approach:

1. **Dispatch smoke test (unit-ish):** grep for the two new `npm)` branches to confirm they exist and reference the right scripts.
2. **iOS regression:** confirm the `mobile-ios)` branches in both `validate_target_env` and `run_adapter_pipeline` are byte-identical to `main`.
3. **Dry-run forwarding:** simulate by running `bash -x skills/publish/scripts/publish_deploy.sh --target <npm-target> --config <fixture> --yes --dry-run` against a minimal publish.json fixture that has an npm target. You should see `npm_pipeline.sh ... --dry-run --non-interactive` in the trace. Full end-to-end publish is out of scope here (belongs with the story-level acceptance test after T03/T04 land).
4. **shellcheck:** `shellcheck skills/publish/scripts/publish_deploy.sh` — the two pre-existing warnings (SC1091 line 5, SC2034 line 7) are acceptable; anything else is a regression.

Full plan: `project/documentation/plans/E26_S06_T02-plan.md`.
