---
id: E26
title: NPM-Compatible Distribution
status: Passed
date_created: 2026-07-31
date_started: 2026-07-31
date_completed: 2026-08-01
dates_previously_completed:
reopened_on:
reopened_reason:
docs: ["README.md", "docs/distribution.md"]
stories:
  - E26_S01
  - E26_S02
  - E26_S03
  - E26_S04
  - E26_S05
  - E26_S06
  - E26_S07
---

# Epic: NPM-Compatible Distribution

## Purpose
Replace the device-local `/distribute` + `.jenga_paths` mechanism with a proper npm publishing workflow. JengaAgent is published as a public npm package (`jenga-agent`) to npmjs.com. Consumer projects install the framework via `npm install jenga-agent`, with a postinstall hook that copies `skills/`, `agents/`, `hooks/`, `scripts/`, and `templates/` into the project root.

Publishing is handled entirely through the existing `/publish` skill, which gains a new `npm` target type alongside the existing `mobile-ios` type. The `/distribute` skill is retired.

## Architecture
- **Publisher:** JengaAgent repo root — `npm publish` is run from here
- **Consumer install:** `npm install jenga-agent` → postinstall copies framework files into consumer project
- **Registry:** public npmjs.com (`publishConfig.access: public`)
- **Version source:** `package.json` version — supersedes `workflow_version` in `jenga.config.json`
- **Dist-tag support:** `latest` (stable) and `beta` (pre-release), configured per target in `publish.json`
- **Dry-run:** Supported via `--dry-run` flag on the npm pipeline

## Definition of Done
- [x] `/distribute` skill and `.jenga_paths` are removed; no dead references remain
- [x] `package.json` has `files`, `publishConfig`, and a working postinstall hook
- [x] `npm pack --dry-run` confirms only the correct files are bundled
- [x] `publish.schema.json` validates npm targets without requiring any iOS fields
- [x] `adapters/npm.md` and `wizards/npm.md` exist and follow the established pattern
- [x] `npm_pipeline.sh` executes `npm publish` with correct dist-tag and dry-run support
- [x] `validate_npm_env.sh` detects missing `NPM_TOKEN` and exits non-zero
- [x] All existing publish scripts (`setup_wizard.sh`, `publish_deploy.sh`, `run_gates.sh`, `validate_config.sh`) handle `type: npm` without breaking the existing `mobile-ios` path
- [x] `skills/publish/SKILL.md` includes npm examples and updated metadata
- [x] A consumer project can run `npm install jenga-agent` and receive all framework files in the expected locations
