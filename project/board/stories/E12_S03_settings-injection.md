---
id: E12_S03
epic_id: E12
title: Settings Injection
status: Passed
date_created: 2026-05-09
date_started:
date_completed: 2026-05-10
tasks: [E12_S03_T01, E12_S03_T02]
---

# Story: Settings Injection

As a user running `jenga init`, I want the hook configuration to be automatically written into `settings.json` so that I don't have to manually edit any config files.

## Acceptance Criteria
- [ ] `jenga init` reads the existing `settings.json` (project-level) or `~/.claude/settings.json` (global) depending on user choice
- [ ] Injects the `UserPromptSubmit` hook entry for `hooks/prompt_router.sh` under `hooks.UserPromptSubmit`
- [ ] Operation is idempotent: running `jenga init` again does not duplicate the hook entry
- [ ] If `settings.json` does not exist, it is created with the minimum required structure
- [ ] Existing hook entries are preserved — only the Jenga hook entry is added/updated
- [ ] After injection, prints confirmation: "✓ Hook registered in settings.json"

## Definition of Done
- [ ] Fresh project: `jenga init` creates/updates `settings.json` with hook entry
- [ ] Re-run: no duplicate entries in `settings.json`
- [ ] Existing hooks in `settings.json` remain intact after injection
