---
id: E22_S04_T01
story_id: E22_S04
epic_id: E22
title: iOS adapter scaffold — prompt template, env var validation, dry-run mode
status: Passed
date_created: 2026-07-11
date_started:
date_completed: 2026-07-11
assigned_to: developer
---

# Task: iOS adapter scaffold — prompt template, env var validation, dry-run mode

## Description
Create the iOS adapter entry point as a prompt-driven template at `skills/publish/adapters/mobile-ios.md`. This template drives the agent's execution of the iOS App Store pipeline.

**Adapter template structure** (`mobile-ios.md`):
- Documents the adapter's invocation contract: inputs from `publish.json` and env vars
- Defines the execution phases in order: validate → build → sign → export → upload
- Documents the state machine transitions: `idle → building → signing → exporting → uploading → uploaded | failed`
- Documents required env vars (as references, never values):
  - `APP_STORE_CONNECT_API_KEY_ID`
  - `APP_STORE_CONNECT_ISSUER_ID`
  - `APP_STORE_CONNECT_PRIVATE_KEY_PATH`
  - `CODE_SIGN_IDENTITY`
  - `PROVISIONING_PROFILE_UUID`

**Env var validation script** (`skills/publish/scripts/validate_ios_env.sh`):
- Accepts a `publish.json` path as $1
- Reads required env var names from adapter config
- Checks each is set and non-empty in the environment
- On missing vars: exit 4 with a clear message listing which are absent

**Dry-run mode** (`--dry-run` flag support, documented in the adapter template):
- All xcodebuild / xcrun commands are printed with `[DRY RUN]` prefix but not executed
- State machine writes proceed normally so the output can be reviewed
- Exit 0 on dry-run completion

## Prerequisites
None.

## Acceptance Criteria
- [ ] `skills/publish/adapters/mobile-ios.md` exists with adapter contract, phase sequence, state machine, and required env vars documented
- [ ] `skills/publish/scripts/validate_ios_env.sh` exists and is executable
- [ ] Validation script exits 4 with a clear message listing missing vars
- [ ] Validation script exits 0 when all env vars are present and non-empty
- [ ] Dry-run mode documented and stubbed in the adapter template
