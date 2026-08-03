---
id: E26_S05
epic_id: E26
title: npm pipeline scripts
status: Passed
date_created: 2026-07-31
date_started: 2026-07-31
date_completed: 2026-08-01
dates_previously_completed:
reopened_on:
reopened_reason:
docs: []
tasks:
  - E26_S05_T01
  - E26_S05_T02
---

# Story: npm pipeline scripts

As a framework maintainer running `/publish deploy --target npm-registry`, I want dedicated pipeline scripts that validate the environment and execute `npm publish` so that the publish process is automated, repeatable, and safe.

## Acceptance Criteria
- [ ] `skills/publish/scripts/npm_pipeline.sh` exists, is executable, and runs `npm publish` from the JengaAgent repo root
- [ ] `npm_pipeline.sh` reads `dist_tag` from the target config and passes `--tag <dist_tag>` to `npm publish`
- [ ] `npm_pipeline.sh` supports a `--dry-run` flag: when set, it runs `npm publish --dry-run` and reports what would be published without actually publishing
- [ ] `npm_pipeline.sh` exits with code 0 on success, 3 on publish failure, and 2 on pre-publish gate failure
- [ ] `skills/publish/scripts/validate_npm_env.sh` exists, is executable, and checks that `NPM_TOKEN` (or `NODE_AUTH_TOKEN`) is set in the environment
- [ ] `validate_npm_env.sh` exits with a non-zero code and a clear error message if the token is missing
- [ ] Both scripts are consistent in style and exit code conventions with the existing iOS scripts

## Definition of Done
- [ ] `skills/publish/scripts/npm_pipeline.sh` is executable and passes `shellcheck`
- [ ] `skills/publish/scripts/validate_npm_env.sh` is executable and passes `shellcheck`
- [ ] Dry-run mode produces output confirming what would be published without writing to the registry
- [ ] Exit codes match the conventions documented in the publish skill non-interactive contract
