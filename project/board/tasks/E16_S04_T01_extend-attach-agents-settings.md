---
id: E16_S04_T01
story_id: E16_S04
epic_id: E16
title: Extend jenga attach to write .agents/settings.json
status: Passed
date_completed: 2026-07-11
---

# Task: Extend `jenga attach` to write `.agents/settings.json`

## Description
Update `lib/commands/attach.js` to read/merge/write the `mcpServers.jenga` entry into `.agents/settings.json` (at `process.cwd()/.agents/settings.json`) in addition to the existing `.claude/settings.json` write.

## Implementation Notes
- Follow the exact same pattern already used for `.claude/settings.json` (read → merge → write)
- If `.agents/settings.json` does not exist, create it with `{ "mcpServers": { "jenga": { ... } } }`
- If it does exist, parse it and merge the `mcpServers.jenga` key (overwrite if already present — idempotent)
- `mkdirSync` on `.agents/` with `{ recursive: true }` before writing
- Update the success console.log to mention both files, e.g.:
  `"Attached. Open a new session in this project to start routing through Jenga."`
  (or add a second line confirming `.agents/settings.json` was also updated)

## Acceptance Criteria
- [ ] `jenga attach` creates/updates `.agents/settings.json` with the correct `mcpServers.jenga` entry
- [ ] Operation is idempotent — running twice does not duplicate the entry
- [ ] If `.agents/settings.json` does not exist it is created
- [ ] `.claude/settings.json` behaviour is unchanged
