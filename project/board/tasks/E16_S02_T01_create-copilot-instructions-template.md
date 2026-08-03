---
id: E16_S02_T01
story_id: E16_S02
epic_id: E16
title: Create Copilot instructions template
status: Done
date_started: 2026-05-10
date_completed: 2026-05-10
assigned_to: developer
---

# Task: Create Copilot instructions template

## Description
Create `templates/copilot-instructions.md.tpl` — a Markdown template that `jenga init` renders into `.github/copilot-instructions.md`. The template should inject Jenga context into the Copilot system prompt, mirroring the intent of Claude's `UserPromptSubmit` hook:

- Brief description of the Jenga agent framework
- Instruction to invoke skills using `/skill-name` syntax
- Placeholder for auto-generated skill list (populated at init time from `skills/`)
- Prompt routing guidance: if a message matches a known skill keyword, invoke the skill
- Jenga block markers (`<!-- JENGA:START -->` / `<!-- JENGA:END -->`) for idempotent updates

## Prerequisites
None.

## Acceptance Criteria
- [ ] `templates/copilot-instructions.md.tpl` exists
- [ ] Template includes JENGA block markers
- [ ] Template includes skill routing instructions and a skill list placeholder
- [ ] Rendered output is valid Markdown that Copilot CLI can consume
