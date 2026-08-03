---
id: E22_S02
epic_id: E22
title: Setup wizard & secrets guide
status: Passed
date_created: 2026-07-11
date_started: 2026-07-11
date_completed: 2026-07-11
tasks:
  - E22_S02_T01
  - E22_S02_T02
  - E22_S02_T03
---

# Story: Setup wizard & secrets guide

## Goal
Build the interactive `/publish setup` wizard that walks users through configuring
a new deployment target in `publish.json`. The wizard is template-driven per
deployment type. Include a standardized, production-safe secrets guide that tells
users exactly how to store credentials (OS keychain locally, CI secrets in pipelines).
Auto-trigger the wizard when `/publish deploy` selects a target with missing config.

## Acceptance Criteria
- [ ] `/publish setup [<target>]` sub-command implemented
- [ ] Wizard reads wizard template from `skills/publish/wizards/<type>.md` based on selected deployment type
- [ ] `mobile-ios` wizard template created at `skills/publish/wizards/mobile-ios.md`, covering: bundle ID, Apple Team ID, provisioning profile, App Store Connect API key env var name, build scheme, export method
- [ ] Secrets guide asset created at `skills/publish/assets/secrets-guide.md` with instructions for: `.env` gitignored local storage, macOS Keychain setup, GitHub Actions / CI secrets, and a warning against committing secrets
- [ ] Wizard writes valid `publish.json` (merging with existing file if present)
- [ ] Wizard validates all collected env var references exist in the current environment before saving — warns if missing
- [ ] Auto-trigger: when `deploy` selects a target with missing or incomplete config, wizard runs automatically before proceeding
- [ ] After wizard completes, user is prompted to confirm the generated config before it is saved

## Notes
- Wizard template is a prompt template (`wizards/<type>.md`), not a script — it drives the agent interaction
- A `mobile-android` wizard template can be added in a future story; this story covers iOS only
- The secrets guide should be surfaced prominently during setup, not buried

## Definition of Done
- [ ] `skills/publish/assets/secrets-guide.md` exists with all five sections including commit-secrets warning
- [ ] `skills/publish/wizards/mobile-ios.md` exists with all six fields templated
- [ ] `skills/publish/scripts/setup_wizard.sh` exists, is executable, and prompts for all fields
- [ ] Env var references validated with warnings on missing vars
- [ ] `publish.json` written or merged on confirmation and re-validated against schema
- [ ] `skills/publish/scripts/check_target_config.sh` exists and exits 4 on incomplete config
- [ ] Auto-trigger documented in SKILL.md `deploy` section
- [ ] Non-interactive mode skips wizard and exits 4 with descriptive listing
