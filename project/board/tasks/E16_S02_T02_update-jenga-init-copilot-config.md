---
id: E16_S02_T02
story_id: E16_S02
epic_id: E16
title: Update jenga init to scaffold Copilot config
status: Done
date_started: 2026-05-10
date_completed: 2026-05-10
assigned_to: developer
---

# Task: Update jenga init to scaffold Copilot config

## Description
Extend `lib/commands/init.js` to idempotently generate `.github/copilot-instructions.md` from `templates/copilot-instructions.md.tpl` during `jenga init`. The logic must:

1. Ensure `.github/` directory exists
2. If `.github/copilot-instructions.md` does not exist — render the template and write the file
3. If it already exists — locate the `<!-- JENGA:START -->` / `<!-- JENGA:END -->` block and replace only that block; preserve all content outside the markers
4. Populate the skill list placeholder by reading directory names from `skills/` (or `.agents/skills/` per project config)

## Prerequisites
- E16_S02_T01 (template must exist)

## Acceptance Criteria
- [ ] `jenga init` creates `.github/copilot-instructions.md` in a fresh project
- [ ] Running `jenga init` again does not duplicate or wipe existing content
- [ ] Skill list in the generated file reflects actual skills found in `skills/`
- [ ] `.github/` directory is created if it doesn't exist
