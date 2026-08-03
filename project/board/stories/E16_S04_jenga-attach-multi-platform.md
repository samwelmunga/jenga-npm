---
id: E16_S04
epic: E16
title: jenga attach — Multi-Platform Settings Parity
status: Done
date_created: 2026-05-10
date_completed: 2026-05-10
tasks:
  - E16_S04_T01
  - E16_S04_T02
  - E16_S04_T03
---

# Story: jenga attach — Multi-Platform Settings Parity

## Goal
`jenga attach` currently writes only to `.claude/settings.json`. This story extends the command to also write the MCP server entry into `.agents/settings.json` so that GitHub Copilot CLI sessions auto-spawn the Jenga router the same way Claude Code sessions do. Any other adjustments that `jenga attach` or related setup scripts make to `.claude/` or `CLAUDE.md` must be mirrored to `.agents/`, `AGENT.md`, and `WARP.md` as well.

## Tasks

### E16_S04_T01 — Extend `jenga attach` to write `.agents/settings.json`
Update `lib/commands/attach.js` to read/merge/write the `mcpServers.jenga` entry into `.agents/settings.json` (at `process.cwd()/.agents/settings.json`) in addition to `.claude/settings.json`. Operation must be idempotent. If `.agents/settings.json` does not exist, create it. Emit a clear success message that mentions both config files were updated.

### E16_S04_T02 — Audit and mirror all other `.claude/` / `CLAUDE.md` adjustments
Review `lib/commands/attach.js` and any related setup scripts for any other writes to `.claude/` or `CLAUDE.md` that make the Jenga CLI service function. Apply equivalent writes to `.agents/`, `AGENT.md`, and `WARP.md`.

### E16_S04_T03 — Update documentation
Update `project/documentation/examples/jenga-mcp-and-cli.md` to reflect:
- `jenga attach` now writes to both `.claude/settings.json` and `.agents/settings.json`
- Add an example block showing `.agents/settings.json` after `jenga attach` (parallel to the existing Example D for `.claude/settings.json`)
- Update all references that only mention `.claude/` to also mention `.agents/`

## Acceptance Criteria
- [ ] `jenga attach` writes the `mcpServers.jenga` entry into `.agents/settings.json`
- [ ] The command is idempotent for both config files
- [ ] Any other `.claude/`-targeted side-effects of `jenga attach` are mirrored to `.agents/`
- [ ] `AGENT.md` and `WARP.md` receive the same treatment as `CLAUDE.md` where applicable
- [ ] `project/documentation/examples/jenga-mcp-and-cli.md` is updated with multi-platform examples
