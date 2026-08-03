---
id: E16_S03_T02
story_id: E16_S03
epic_id: E16
title: Implement Copilot-side session-end equivalent
status: Done
date_created: 2026-05-10
date_started: 2026-05-10
date_completed: 2026-05-10
assigned_to: developer
---

# Task: Implement Copilot-side session-end equivalent

## Description
Claude Code fires `SessionEnd` which triggers `hooks/on_session_end.sh`. Copilot CLI has no equivalent native hook, but the Jenga skill lifecycle can approximate it: add a post-execution step to the skill runner (or a dedicated `hooks/copilot_session_end.sh` wrapper) that fires the same cleanup logic.

Implementation approach:
1. Create `hooks/copilot_session_end.sh` that sources `lib/resolve-project-dir.sh` and delegates to `hooks/on_session_end.sh`
2. Add a note in `templates/copilot-instructions.md.tpl` instructing Copilot to call this script at session end (or after completing a skill)
3. Update `docs/hook-parity.md` (from T01) with the concrete implementation path

## Prerequisites
- E16_S03_T01 (parity doc should exist first)

## Acceptance Criteria
- [ ] `hooks/copilot_session_end.sh` exists, is executable, and sources the resolver
- [ ] Script delegates to `hooks/on_session_end.sh` for shared cleanup logic
- [ ] `copilot-instructions.md.tpl` references the script for session-end guidance
- [ ] No Claude-only env var used without a `JENGA_*` fallback
