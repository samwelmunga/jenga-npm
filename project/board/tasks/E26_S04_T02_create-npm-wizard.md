---
id: E26_S04_T02
story_id: E26_S04
epic_id: E26
title: Create npm setup wizard
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

# Task: Create npm setup wizard

## Description
Create `skills/publish/wizards/npm.md` following the same structure as `wizards/mobile-ios.md`. The wizard must prompt the user for:
1. Package name (pre-filled with `name` from the project's `package.json` if available)
2. Access level: `public` (default) or `restricted`
3. Dist-tag: `latest` (default) or a custom tag (e.g. `beta`)
4. Registry URL (default: `https://registry.npmjs.org`, customisable for GitHub Packages)
5. Dry-run preference: ask if the first deploy should be a dry-run

After collecting answers, the wizard writes a valid npm target block to `publish.json`.

The wizard must also surface the `NPM_TOKEN` prerequisite explicitly — it tells the user what the variable is, how to obtain it (npmjs.com → Account → Access Tokens → Automation token), and where to set it. It writes `project/instructions/E26_S04_T02_INSTRUCTIONS.md` with these steps.

## Prerequisites
- The user must create an account on npmjs.com and generate an Automation token. The wizard generates an `_INSTRUCTIONS.md` file with step-by-step guidance.

## Acceptance Criteria
- [ ] `skills/publish/wizards/npm.md` exists and prompts for all five fields listed above
- [ ] Wizard output writes a valid npm target block to `publish.json` that passes schema validation
- [ ] Wizard generates `project/instructions/E26_S04_T02_INSTRUCTIONS.md` with NPM_TOKEN setup steps
- [ ] If `publish.json` already has an npm target, the wizard asks whether to overwrite or update
- [ ] Structure mirrors `wizards/mobile-ios.md` for consistency
