---
id: E16_S02
epic: E16
title: Copilot Config Scaffold
status: Done
date_created: 2026-05-10
date_completed: 2026-05-10
tasks:
  - E16_S02_T01
  - E16_S02_T02
---

# Story: Copilot Config Scaffold

## Goal
`jenga init` currently only generates Claude's `settings.json`. This story adds generation of the GitHub Copilot equivalent config: `.github/copilot-instructions.md` (system prompt / instructions file) and any Copilot CLI config hooks that parallel Claude Code hooks (e.g. session-end signal, prompt routing).

## Tasks

### E16_S02_T01 — Create Copilot instructions template
Create `templates/copilot-instructions.md.tpl` that injects Jenga context (project summary, skill list, router instructions) into the Copilot system prompt. Mirror the intent of the Claude `settings.json` hook that rewrites prompts via `UserPromptSubmit`.

### E16_S02_T02 — Update `jenga init` to scaffold Copilot config
Extend the `jenga init` script to idempotently write `.github/copilot-instructions.md` from the template. Ensure it doesn't overwrite existing user customisations (append Jenga block between markers if file exists).

## Acceptance Criteria
- `jenga init` produces `.github/copilot-instructions.md` in new projects
- Existing customisations in `copilot-instructions.md` are preserved (marker-based idempotent update)
- Copilot CLI picks up skill routing instructions from the generated file
