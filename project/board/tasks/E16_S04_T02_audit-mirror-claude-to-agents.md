---
id: E16_S04_T02
story_id: E16_S04
epic_id: E16
title: Audit and mirror all .claude / CLAUDE.md adjustments to .agents / AGENT.md / WARP.md
status: Passed
date_completed: 2026-07-11
---

# Task: Audit and mirror all `.claude/` / `CLAUDE.md` adjustments

## Description
Review `lib/commands/attach.js` and all other CLI commands / setup scripts to find any writes/modifications targeting `.claude/` or `CLAUDE.md` that make the Jenga CLI service function. For every such operation, apply the equivalent write to `.agents/`, `AGENT.md`, and/or `WARP.md`.

## Scope
Files to audit:
- `lib/commands/attach.js`
- `lib/commands/init.js`
- Any other files under `lib/` or `scripts/` that reference `.claude` or `CLAUDE.md`

For each adjustment found:
- If it writes to `.claude/<file>` → also write to `.agents/<file>`
- If it writes to `CLAUDE.md` → also write to `AGENT.md` and `WARP.md`

## Acceptance Criteria
- [ ] All `.claude/`-targeted writes in CLI commands are mirrored to `.agents/`
- [ ] All `CLAUDE.md`-targeted writes are mirrored to `AGENT.md` and `WARP.md`
- [ ] No regressions in existing `.claude/` behaviour
