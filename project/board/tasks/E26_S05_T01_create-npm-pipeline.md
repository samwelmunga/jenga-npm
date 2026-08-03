---
id: E26_S05_T01
story_id: E26_S05
epic_id: E26
title: Create npm_pipeline.sh
status: Passed
date_created: 2026-07-31
date_started: 2026-07-31
date_completed: 2026-08-01
dates_previously_completed:
reopened_on:
reopened_reason:
assigned_to: developer
docs: []
---

# Task: Create npm_pipeline.sh

## Description
Create `skills/publish/scripts/npm_pipeline.sh` — the script that executes the npm publish pipeline. It must:
1. Accept a `--dry-run` flag: if set, run `npm publish --dry-run` and report what would be published; do not write to the registry
2. Read `dist_tag` from the target config (passed as an argument or env var) and pass `--tag <dist_tag>` to `npm publish`
3. Run from the JengaAgent repo root (where `package.json` lives)
4. Produce clear output: package name, version, tag, registry, and whether it's a dry-run
5. Exit with code 0 on success, 3 on publish error, 2 on pre-publish failure

Follow the style and exit code conventions of the existing `ios_pipeline.sh`.

## Prerequisites

## Acceptance Criteria
- [ ] `skills/publish/scripts/npm_pipeline.sh` exists and is executable (`chmod +x`)
- [ ] Script accepts `--dry-run` flag and uses `npm publish --dry-run` when set
- [ ] Script reads dist_tag and passes `--tag <dist_tag>` to `npm publish`
- [ ] Exit codes: 0 = success, 2 = pre-publish gate failure, 3 = publish error
- [ ] Script passes `shellcheck` with no errors
- [ ] Dry-run output clearly states "DRY RUN — nothing was published" before listing what would be published
