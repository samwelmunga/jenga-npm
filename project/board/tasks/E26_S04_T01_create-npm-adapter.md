---
id: E26_S04_T01
story_id: E26_S04
epic_id: E26
title: Create npm adapter definition
status: Passed
date_created: 2026-07-31
date_started: 2026-07-31
date_completed: 2026-07-31
dates_previously_completed:
reopened_on:
reopened_reason:
assigned_to: developer
docs: []
---

# Task: Create npm adapter definition

## Description
Create `skills/publish/adapters/npm.md` following the same structure as `adapters/mobile-ios.md`. The adapter contract must define:
- **Required environment variables:** `NPM_TOKEN` (or `NODE_AUTH_TOKEN`)
- **Input config fields:** the npm settings block fields from S03 (`package_name`, `access`, `registry`, `dist_tag`)
- **Pipeline entry point:** `scripts/npm_pipeline.sh`
- **Quality gates:** `npm test`, `npm run build` (if script exists in consumer package.json)
- **Output artefacts:** published package on npmjs.com registry, git tag (`v<version>`)
- **Success condition:** exit 0 from `npm publish`, package visible on registry
- **Failure conditions:** missing token (exit 2), publish error (exit 3), gate failure (exit 2)
- **Dry-run behaviour:** `npm publish --dry-run`, no registry write, outputs what would be published

## Prerequisites

## Acceptance Criteria
- [ ] `skills/publish/adapters/npm.md` exists
- [ ] The file defines all six sections: environment variables, input config, pipeline entry point, quality gates, output artefacts, success/failure conditions
- [ ] Dry-run behaviour is explicitly documented
- [ ] Structure mirrors `adapters/mobile-ios.md` for consistency
