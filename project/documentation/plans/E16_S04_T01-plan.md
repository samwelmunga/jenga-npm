# E16_S04_T01 — Execution Plan

## Task
Extend `lib/commands/attach.js` to write `mcpServers.jenga` into `.agents/settings.json` in addition to `.claude/settings.json`.

## Approach
1. After the existing `.claude/settings.json` write block, add a parallel block for `.agents/settings.json`
2. Same read → merge → write pattern; `mkdirSync` with `{ recursive: true }` before write
3. Update success message to confirm both configs were updated

## Files Changed
- `lib/commands/attach.js`
