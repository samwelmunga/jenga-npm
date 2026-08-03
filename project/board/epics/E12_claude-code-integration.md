---
id: E12
title: Claude Code Integration
status: Done
date_created: 2026-05-09
date_started:
date_completed: 2026-05-10
stories:
  - E12_S01
  - E12_S02
  - E12_S03
---

# Epic: Claude Code Integration

## Purpose
Wire the Jenga Router into Claude Code's native hook system so that prompt routing is completely transparent to the user. A `UserPromptSubmit` hook intercepts every incoming prompt, calls the router, and either passes it through unmodified or rewrites it as a skill invocation (e.g. `/do <original prompt>`). A completion signal protocol defines how skills signal session end, and `jenga init` injects the hook configuration into `settings.json` idempotently.

## Definition of Done
- [ ] `hooks/prompt_router.sh` intercepts every user prompt and calls the Jenga Router
- [ ] Hook correctly rewrites matched prompts and passes through unmatched/session-active/slash-prefixed prompts
- [ ] Completion signal `[JENGA:SESSION_END:skill_name]` is documented and the router clears session state on receipt
- [ ] Skill template updated to emit completion signal at session end
- [ ] `jenga init` injects hook config into `settings.json` without duplicating existing entries
