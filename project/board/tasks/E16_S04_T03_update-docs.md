---
id: E16_S04_T03
story_id: E16_S04
epic_id: E16
title: Update jenga-mcp-and-cli.md documentation for multi-platform attach
status: Passed
date_completed: 2026-07-11
---

# Task: Update `project/documentation/examples/jenga-mcp-and-cli.md`

## Description
Update the documentation at `project/documentation/examples/jenga-mcp-and-cli.md` to reflect that `jenga attach` now writes to both `.claude/settings.json` and `.agents/settings.json`.

## Changes Required
1. **Section 1 / intro** — Update the description of `bin/jenga.js` to say it registers the router in both `.claude/settings.json` and `.agents/settings.json`
2. **Diagram / flow** — Update any references that say only `.claude/settings.json`
3. **Example D** — Rename/extend "Example D — `.claude/settings.json` after `jenga attach`":
   - Keep the existing `.claude/settings.json` example
   - Add a parallel "Example E — `.agents/settings.json` after `jenga attach`" block showing the same structure
4. **Idempotency note** — Update the note about running `jenga attach` twice to mention both files
5. **Any other `.claude/`-only mentions** — Update to mention `.agents/` as well where relevant

## Acceptance Criteria
- [ ] Documentation accurately describes multi-platform attach behaviour
- [ ] An example block for `.agents/settings.json` exists alongside the `.claude/settings.json` example
- [ ] No stale `.claude/`-only references remain for things that now apply to both platforms
