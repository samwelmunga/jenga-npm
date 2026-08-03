---
id: E15_S02_T01
story: E15_S02
title: Strip daemon mode from router and CLI
status: Done
date_created: 2026-05-10
---

# Task: Strip daemon mode from router and CLI

## What to do
Remove all daemon-related code:

1. **`mcp/router/index.js`:** Remove the `--daemon` / `isDaemon` branch and the `setInterval(() => {}, 1 << 30)` keep-alive. The router should only run as a direct stdio MCP server.

2. **`lib/commands/start.js`:** Remove the `child_process.spawn(..., { detached: true })` fork. Replace the command body with a message directing users to run `jenga attach` and open a new session, or simply remove the command and update the CLI help text.

3. **`lib/commands/stop.js`:** If stop was solely for killing the daemon PID, remove it or replace it with a no-op that explains the new model.

4. Update `bin/jenga.js` (or the CLI entrypoint) to remove `start` and `stop` from the registered command list if they are no longer meaningful, or repurpose `start` to call `jenga attach`.
