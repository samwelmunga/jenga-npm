---
id: E15_S03_T01
story: E15_S03
title: Implement jenga attach command
status: Done
date_created: 2026-05-10
---

# Task: Implement jenga attach command

## What to do
Create `lib/commands/attach.js` and wire it into the CLI entrypoint.

### Logic
1. Resolve `jenga.cli.json` from `process.cwd()`. If missing, exit with: "No jenga.cli.json found. Run `jenga init` first."
2. Determine the absolute path to the jenga router: `require.resolve` or `join` from the jenga package root to `mcp/router/index.js`.
3. Read `.claude/settings.json` from `process.cwd()/.claude/settings.json` (create if absent, default to `{}`).
4. Merge an `mcpServers` entry using the key `"jenga"`:
   ```json
   {
     "mcpServers": {
       "jenga": {
         "type": "stdio",
         "command": "node",
         "args": ["/absolute/path/to/mcp/router/index.js"]
       }
     }
   }
   ```
5. Write the updated JSON back (pretty-printed, 2-space indent).
6. Print: "Attached. Open a new session in this project to start routing through Jenga."

### Idempotency
If a `"jenga"` key already exists in `mcpServers`, overwrite it with the current resolved path (handles jenga upgrades / path changes).
