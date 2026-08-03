---
id: E22_S02_T02
story_id: E22_S02
epic_id: E22
title: /publish setup wizard implementation — prompts, publish.json merge, env var validation
status: Passed
date_created: 2026-07-11
date_started: 2026-07-11
date_completed: 2026-07-11
assigned_to: developer
---

# Task: /publish setup wizard implementation — prompts, publish.json merge, env var validation

## Description
Implement the `/publish setup [<target>]` sub-command as an interactive wizard in `skills/publish/scripts/setup_wizard.sh`.

**Invocation contract**:
- `setup_wizard.sh [<target_name>] [--type <deployment_type>]`
- If `<target_name>` is omitted, prompt the user for one
- If `--type` is omitted, prompt the user to choose (currently only `mobile-ios`)

**Wizard flow**:
1. Display a heading: `📦 /publish setup — <target_name> (<type>)`
2. Surface the secrets guide (print path and first section's warning)
3. Load the wizard template from `skills/publish/wizards/<type>.md`
4. For each `## Question:` section in the template, prompt the user for the value
5. Collect all answers into a target config object
6. **Env var validation**: for each field ending in `_env_var` (secrets references), check if that env var is set in the current shell. If missing, warn: `⚠️  Env var '<NAME>' is not set. Set it before deploying.`
7. Display a preview of the target config as formatted JSON
8. Prompt: `Save this config to publish.json? [y/N]`
9. On `y`: merge into existing `publish.json` (or create new) at the project root
10. On `N`: exit without saving, inform the user they can re-run setup at any time

**publish.json merge logic**:
- If `publish.json` exists, read it and upsert the new target (match by `name` field)
- If not, create it with a `{ "targets": [ <new_target> ] }` structure
- Validate the written file against `skills/publish/schemas/publish.schema.json` (call `validate_config.sh`)
- If validation fails after write, print error and rollback the file

**SKILL.md update**:
- The `setup` sub-command section in `SKILL.md` should reference this script and document the wizard flow

## Prerequisites
T01 (secrets guide and wizard template) should be complete.

## Acceptance Criteria
- [ ] `skills/publish/scripts/setup_wizard.sh` exists and is executable
- [ ] Wizard reads and renders each `## Question:` section from the type's wizard template
- [ ] Wizard prompts for all six `mobile-ios` fields
- [ ] Env var references checked; missing ones warned but don't block save
- [ ] Config preview shown before save prompt
- [ ] publish.json written (or merged) on confirmation
- [ ] Written publish.json validated against schema; rollback on failure
- [ ] SKILL.md `setup` section references the wizard script
