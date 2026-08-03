---
id: E26_S06
epic_id: E26
title: Update existing publish scripts for npm targets
status: Passed
date_created: 2026-07-31
date_started: 2026-08-01
date_completed: 2026-08-01
dates_previously_completed:
reopened_on:
reopened_reason:
docs: []
tasks:
  - E26_S06_T01
  - E26_S06_T02
  - E26_S06_T03
  - E26_S06_T04
---

# Story: Update existing publish scripts for npm targets

As a developer using `/publish`, I want the existing orchestration scripts to route npm targets correctly so that the full `/publish setup` and `/publish deploy` flows work end-to-end for npm without breaking the existing iOS path.

## Acceptance Criteria
- [x] `setup_wizard.sh` handles `--type npm` by invoking `wizards/npm.md` and exits cleanly; the `--type mobile-ios` path is unchanged
- [x] `publish_deploy.sh` dispatches to `npm_pipeline.sh` when the target type is `npm`; it continues to dispatch to `ios_pipeline.sh` for `mobile-ios` targets
- [x] `run_gates.sh` runs `npm test` and `npm run build` (if defined in `package.json`) as quality gates when the target type is `npm`; iOS gates are not run for npm targets
- [x] `validate_config.sh` validates npm target structure (required fields: `package_name`, `access`) and exits 4 if they are missing or malformed; existing iOS validation is not regressed
- [x] All four scripts pass `shellcheck` after modification
- [x] Running `/publish deploy --target npm-registry --yes` in a correctly configured project executes the full npm pipeline without prompting

## Definition of Done
- [x] `setup_wizard.sh` has a `npm` branch that invokes the npm wizard
- [x] `publish_deploy.sh` dispatches on `type` — `npm` routes to `npm_pipeline.sh`
- [x] `run_gates.sh` has a `npm` gate block running `npm test` / `npm run build`
- [x] `validate_config.sh` validates npm targets without requiring iOS fields
- [x] All four scripts pass `shellcheck`
- [x] A manual end-to-end dry-run confirms the npm path completes without errors
