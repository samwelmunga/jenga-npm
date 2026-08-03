---
id: E22_S01
epic_id: E22
title: Skill scaffold, config schema & non-interactive contract
status: Passed
date_created: 2026-07-11
date_started:
date_completed: 2026-07-11
tasks:
  - E22_S01_T01
  - E22_S01_T02
  - E22_S01_T03
---

# Story: Skill scaffold, config schema & non-interactive contract

## Goal
Create the `/publish` SKILL.md with its sub-command structure and define the full
`publish.json` config schema. Critically, define the non-interactive execution
contract (flags, env vars, exit codes, defaults) before any wizard UX is built —
so the skill is usable from CI and agent contexts from day one.

## Acceptance Criteria
- [ ] `skills/publish/SKILL.md` created with YAML frontmatter (`name`, `description`, `keywords`, `examples`)
- [ ] Skill defines four sub-commands: `setup`, `deploy`, `history`, `release-notes`
- [ ] `publish.json` schema documented (targets, type, platforms, checks, secrets as env var refs)
- [ ] Non-interactive contract spec written: which flags/env vars drive `deploy` without prompts (e.g. `--target`, `--yes`, `PUBLISH_TARGET`)
- [ ] Exit codes defined: 0 = success, 1 = user abort, 2 = gate failure, 3 = deploy failure, 4 = config missing
- [ ] Skill validates `publish.json` on every invocation and exits with code 4 if missing/invalid
- [ ] Skill registered in `/help` output

## Notes
- The non-interactive contract must be designed so CI can invoke `/publish deploy --target staging --yes` without any prompts
- Wizard (interactive mode) is built on top of this contract in S02 — not the other way around
- Do not implement actual deployment logic in this story; orchestration structure only

## Definition of Done
- [x] `skills/publish/SKILL.md` exists with correct YAML frontmatter
- [x] Four sub-commands defined in SKILL.md: `setup`, `deploy`, `history`, `release-notes`
- [x] `skills/publish/schemas/publish.schema.json` exists and is valid JSON Schema
- [x] `skills/publish/assets/publish.example.json` exists as annotated example
- [x] Non-interactive contract documented with all flags, env vars, and exit codes
- [x] `skills/publish/scripts/validate_config.sh` exists, is executable, and exits 4 on missing/invalid config
- [x] Skill appears in `/help` output
