---
id: E22_S02_T01
story_id: E22_S02
epic_id: E22
title: Secrets guide asset and mobile-ios wizard template
status: Passed
date_created: 2026-07-11
date_started: 2026-07-11
date_completed: 2026-07-11
assigned_to: developer
---

# Task: Secrets guide asset and mobile-ios wizard template

## Description
Create the two static asset files that drive the `/publish setup` wizard experience.

**Secrets guide** (`skills/publish/assets/secrets-guide.md`):
A clear, production-safe reference for how to store deployment credentials. Sections:
1. **Never do this** — warning against committing secrets (with `.gitignore` snippet)
2. **Local development** — `.env` file with `.gitignore` entry + `direnv` mention
3. **macOS Keychain** — how to store and retrieve secrets using `security` CLI
4. **GitHub Actions / CI secrets** — how to set org/repo secrets, reference them as `${{ secrets.NAME }}`, and map them to env vars at job level
5. **General rule** — secrets are always env var *references* in `publish.json`, never literal values

**mobile-ios wizard template** (`skills/publish/wizards/mobile-ios.md`):
A prompt template (markdown, not a script) that drives the interactive wizard for the `mobile-ios` deployment type. The template defines the questions to ask the user and maps answers to `publish.json` fields:
- Bundle ID → `targets[].bundle_id`
- Apple Team ID → `targets[].team_id`
- Build scheme → `targets[].scheme`
- Export method (`ad-hoc` | `app-store`) → `targets[].export_method`
- App Store Connect API key env var name → `targets[].secrets.api_key_id` (env ref)
- Provisioning profile env var name → `targets[].secrets.provisioning_profile_uuid` (env ref)
- After each secrets field, wizard must reference the secrets guide at `skills/publish/assets/secrets-guide.md`

Format: each question is a markdown section with a `## Question: <field>` heading, a description, and an `## Expected format:` note.

## Prerequisites
E22_S01 must be complete (SKILL.md and schema exist). ✅ (S01 is merged)

## Acceptance Criteria
- [ ] `skills/publish/assets/secrets-guide.md` exists with all five sections
- [ ] Warning section explicitly advises against committing secrets and shows `.gitignore` snippet
- [ ] `skills/publish/wizards/mobile-ios.md` exists with all six fields templated
- [ ] Each secrets field in the wizard template references the secrets guide
- [ ] Template maps fields to correct `publish.json` keys per the S01 schema
